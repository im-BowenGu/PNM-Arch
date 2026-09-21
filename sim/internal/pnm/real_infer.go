package pnm

import (
	"encoding/binary"
	"fmt"
	"math"
	"os"
	"sort"
	"strings"
)


// gemmaModel bundles the loaded model config + weight accessor.
type gemmaModel struct {
	m      *realModel
	cfg    *ModelConfig
	vocab  *BPEVocab
	hidden int
}


// evalDot computes Σ_c row[c]*x[c] for a flat BF16 row.
func evalDot(row []byte, cols int, in []float32) float32 {
	var acc float32
	for c := 0; c < cols; c++ {
		acc += bf16ToF32(binary.LittleEndian.Uint16(row[c*2:])) * in[c]
	}
	return acc
}

// gemmaRouterInput applies the Gemma4 router pre-transform:
// norm_NO_scale(x) * router.scale * hidden_size^-0.5, returning a new vector.
func gemmaRouterInput(x, scale []float32, hidden int) []float32 {
	out := make([]float32, hidden)
	var ss float32
	for _, v := range x {
		ss += v * v
	}
	inv := 1 / float32(math.Sqrt(float64(ss)/float64(hidden)+1e-6))
	root := 1 / float32(math.Sqrt(float64(hidden)))
	for i := 0; i < hidden; i++ {
		s := float32(1)
		if i < len(scale) {
			s = scale[i]
		}
		out[i] = x[i] * inv * s * root
	}
	return out
}


// vNorm applies the Gemma4 value RMSNorm (with_scale=False): plain division
// by the per-vector RMS without any learned weight.
func vNorm(x []float32, eps float32) []float32 {
	n := len(x)
	var ss float32
	for _, v := range x {
		ss += v * v
	}
	inv := 1 / float32(math.Sqrt(float64(ss)/float64(n)+float64(eps)))
	out := make([]float32, n)
	for i := 0; i < n; i++ {
		out[i] = x[i] * inv
	}
	return out
}

// rmsNorm applies RMS normalization with the given per-dim weights.
func rmsNorm(x []float32, w []float32, eps float32) []float32 {
	n := len(x)
	var ss float32
	for _, v := range x {
		ss += v * v
	}
	ss = ss/float32(n) + eps
	inv := 1 / float32(math.Sqrt(float64(ss)))
	out := make([]float32, n)
	for i := 0; i < n; i++ {
		out[i] = x[i] * inv * w[i]
	}
	return out
}

// geluTanh is the "gelu_pytorch_tanh" activation used by the dense MLP.
func geluTanh(x float32) float32 {
	const c = 0.7978845608028654 // sqrt(2/pi)
	v := float64(x)
	inner := c * (v + 0.044715*v*v*v)
	return float32(0.5 * v * (1 + math.Tanh(inner)))
}

// silu is the swish activation used by MoE gate projections.
// matVec computes out[r] = Σ_c M[r][c] * x[c].
func matVec(M [][]float32, x []float32, out []float32) {
	for r := range M {
		var acc float32
		row := M[r]
		for c := range row {
			acc += row[c] * x[c]
		}
		out[r] = acc
	}
}

// scalVec multiplies x by s in place.
func scalVec(x []float32, s float32) {
	for i := range x {
		x[i] *= s
	}
}

// arrAdd adds the second slice (elementwise) to the first.
func arrAdd(a, b []float32) {
	for i := range a {
		a[i] += b[i]
	}
}

// sampleToken draws a token from the logits by temperature softmax
// (deterministic hash-seeded, so runs stay reproducible per seed).
func sampleToken(logits []float32, temp float32) int {
	if temp <= 0 || len(logits) == 0 {
		best, bv := 0, logits[0]
		for i, v := range logits {
			if v > bv {
				bv, best = v, i
			}
		}
		return best
	}
	// softmax with temperature
	mx := logits[0]
	for _, v := range logits {
		if v > mx {
			mx = v
		}
	}
	probs := make([]float64, len(logits))
	var sum float64
	for i, v := range logits {
		probs[i] = math.Exp(float64(v-mx) / float64(temp))
		sum += probs[i]
	}
	if sum <= 0 {
		best := 0
		for i, v := range logits {
			if v > logits[best] {
				best = i
			}
		}
		return best
	}
	// deterministic pseudo-random in [0,1): splitmix64 over a seed built
	// from the logits (so identical inputs sample identically, differing
	// tokens diverge).  This replaces the degenerate constant target.
	var seed uint64 = 0x9E3779B97F4A7C15
	for _, v := range logits[:8] {
		seed ^= uint64(math.Float32bits(v)) * 0x2545F4914F6CDD1D
		seed = (seed ^ (seed >> 30)) * 0xBF58476D1CE4E5B9
		seed = (seed ^ (seed >> 27)) * 0x94D049BB133111EB
		seed ^= seed >> 31
	}
	// splitmix64 finalizer again for a well-mixed low bit
	seed = (seed ^ (seed >> 30)) * 0xBF58476D1CE4E5B9
	seed = (seed ^ (seed >> 27)) * 0x94D049BB133111EB
	seed ^= seed >> 31
	target := float64(seed>>11) / float64(uint64(1)<<53)
	acc := float64(0)
	for i, pr := range probs {
		acc += pr / sum
		if acc >= target {
			return i
		}
	}
	best := 0
	for i, v := range logits {
		if v > logits[best] {
			best = i
		}
	}
	return best
}

// hiddenRMS returns the root-mean-square magnitude of a vector.
func hiddenRMS(x []float32) float64 {
	var ss float64
	for _, v := range x {
		ss += float64(v) * float64(v)
	}
	return math.Sqrt(ss / float64(len(x)))
}

// softcap applies logit soft-capping: tanh(x/c)*c.
func softcap(x []float32, c float32) {
	for i := range x {
		v := float64(x[i]) / float64(c)
		x[i] = float32(float64(c) * math.Tanh(v))
	}
}

// rotary applies RoPE to a (numHeads, headDim) [][headDim] slice in place,
// using the given theta and partial-rotation fraction (rotate the first
// `partial*headDim` dims, per the config's "partial_rotary_factor").
func rotary(q [][]float32, theta float64, partial float64, position int) {
	if len(q) == 0 {
		return
	}
	hd := len(q[0])
	half := hd / 2
	// Number of rotated angle pairs: for "default" rope all half pairs
	// rotate; for "proportional" only int(partial*head_dim//2) do (the
	// rest are zero-freq and pass through with cos=1, sin=0).
	ropePairs := int(partial * float64(hd) / 2)
	if ropePairs <= 0 {
		ropePairs = half
	}
	pos := float64(position)
	for h := 0; h < len(q); h++ {
		for i := 0; i < ropePairs; i++ {
			// half-split pairing: pair (x[i], x[i+half]) with angle
			// pos / theta^(2i/head_dim)
			freq := pos / math.Pow(theta, float64(2*i)/float64(hd))
			c := float32(math.Cos(freq))
			s := float32(math.Sin(freq))
			x0 := q[h][i]
			x1 := q[h][i+half]
			q[h][i] = x0*c - x1*s
			q[h][i+half] = x0*s + x1*c
		}
	}
}

// splitHeads splits a flat [numHeads*headDim] vector into heads.
func splitHeads(flat []float32, heads, hd int) [][]float32 {
	out := make([][]float32, heads)
	for h := 0; h < heads; h++ {
		out[h] = flat[h*hd : (h+1)*hd]
	}
	return out
}

// forwardStep runs one full language-model layer on hidden state x (length 2816).
// Attention type: 0 = sliding window, 1 = full (global).  Returns the new
// hidden state (in-place reuse of the provided buffer).
func (g *gemmaModel) forwardStep(layer int, x []float32) error {
	h := g.hidden
	L := fmt.Sprintf("model.language_model.layers.%d.", layer)

	var full bool
	if g.cfg.TextConfig.LayerTypes != nil && layer >= 0 && layer < len(g.cfg.TextConfig.LayerTypes) {
		full = g.cfg.TextConfig.LayerTypes[layer] == "full_attention"
	} else {
		full = layer%6 == 5
	}

	// ---- attention block -------------------------------------------------
	residual := make([]float32, h)
	copy(residual, x)

	xn := rmsNorm(x, g.m.vec(L+"input_layernorm.weight"), 1e-6)

	// projections
	headDim := g.cfg.TextConfig.HeadDim
	kvHeads := g.cfg.TextConfig.NumKeyValueHeads
	if full {
		headDim = g.cfg.TextConfig.GlobalHeadDim
		kvHeads = g.cfg.TextConfig.NumGlobalKVHeads
	}
	qHeads := g.cfg.TextConfig.NumAttentionHeads
	qRows := qHeads * headDim
	kRows := kvHeads * headDim

	Wq := g.m.mat(L+"self_attn.q_proj.weight", qRows, h)
	Wk := g.m.mat(L+"self_attn.k_proj.weight", kRows, h)
	Wv := g.m.mat(L+"self_attn.v_proj.weight", kRows, h)
	Wo := g.m.mat(L+"self_attn.o_proj.weight", h, qRows)

	qFlat := make([]float32, qRows)
	kFlat := make([]float32, kRows)
	vFlat := make([]float32, kRows)
	matVec(Wq, xn, qFlat)
	matVec(Wk, xn, kFlat)
	matVec(Wv, xn, vFlat)

	// per-dtype head norms (q_norm / k_norm)
	qNormW := g.m.vec(L + "self_attn.q_norm.weight")
	kNormW := g.m.vec(L + "self_attn.k_norm.weight")
	qHeadsX := splitHeads(qFlat, qHeads, headDim)
	kHeadsX := splitHeads(kFlat, kvHeads, headDim)
	vHeadsX := splitHeads(vFlat, kvHeads, headDim)
	for hIdx := 0; hIdx < qHeads; hIdx++ {
		qHeadsX[hIdx] = rmsNorm(qHeadsX[hIdx], qNormW, 1e-6)
	}
	for hIdx := 0; hIdx < kvHeads; hIdx++ {
		kHeadsX[hIdx] = rmsNorm(kHeadsX[hIdx], kNormW, 1e-6)
	}

	// RoPE: full layers use theta 1e6 + partial 0.25; sliding use theta 1e4.
	if full {
		rotary(qHeadsX, 1e6, 0.25, 0)
		rotary(kHeadsX, 1e6, 0.25, 0)
	} else {
		rotary(qHeadsX, 1e4, 1.0, 0)
		rotary(kHeadsX, 1e4, 1.0, 0)
	}

	// attention with KV-group broadcast + optional sliding window
	attnOut := make([]float32, qRows)
	scale := float32(1.0) // Gemma4: scaling = 1.0
	groups := qHeads / kvHeads
	for qh := 0; qh < qHeads; qh++ {
		kh := qh / groups
		q := qHeadsX[qh]
		k := kHeadsX[kh]
		v := vHeadsX[kh]
		// single-token decode: attend to the current position weight 1/sqrt
		// (causal; for multi-token prefill we loop over positions below).
		var s float32
		for i := range q {
			s += q[i] * k[i]
		}
		s /= scale
		// no softmax needed for a single token (softmax of 1 element = 1)
		_ = s
		for i := range attnOut[qh*headDim : qh*headDim+headDim] {
			attnOut[qh*headDim+i] = v[i]
		}
	}

	// out projection
	oFlat := make([]float32, h)
	matVec(Wo, attnOut, oFlat)
	// attention residual (gemma-style: post-norm the attention output)
	oNorm := rmsNorm(oFlat, g.m.vec(L+"post_attention_layernorm.weight"), 1e-6)
	for i := range x {
		x[i] = residual[i] + oNorm[i]
	}
	_ = x

	// ---- feedforward block (dense MLP + MoE experts) ----------------------
	ffResidual := make([]float32, h)
	copy(ffResidual, x)

	x = rmsNorm(x, g.m.vec(L+"pre_feedforward_layernorm.weight"), 1e-6)

	// dense MLP: gate/up intermediate = 2112
	inter := g.cfg.TextConfig.IntermediateSize
	Wgate := g.m.mat(L+"mlp.gate_proj.weight", inter, h)
	Wup := g.m.mat(L+"mlp.up_proj.weight", inter, h)
	Wdown := g.m.mat(L+"mlp.down_proj.weight", h, inter)
	gate := make([]float32, inter)
	up := make([]float32, inter)
	mid := make([]float32, inter)
	matVec(Wgate, x, gate)
	matVec(Wup, x, up)
	for i := 0; i < inter; i++ {
		mid[i] = geluTanh(gate[i]) * up[i]
	}
	denseOut := make([]float32, h)
	matVec(Wdown, mid, denseOut)

	// MoE routed experts: router.proj [128,2816] -> top-k softmax ->
	// gate_up_proj [128,1408,2816] + down_proj [128,2816,704]
	moeOut := make([]float32, h)
	if g.cfg.TextConfig.NumExperts > 0 && g.cfg.TextConfig.TopKExperts > 0 {
		numExp := g.cfg.TextConfig.NumExperts
		topK := g.cfg.TextConfig.TopKExperts
		moeInter := g.cfg.TextConfig.MoEIntermediateSize

		routerW := g.m.mat(L+"router.proj.weight", numExp, h)
		logits := make([]float32, numExp)
		matVec(routerW, x, logits)

		// softmax over all experts, then take top-k indices
		var lmax float32 = -1e30
		for i := range logits {
			if logits[i] > lmax {
				lmax = logits[i]
			}
		}
		probs := make([]float32, numExp)
		var z float32
		for i := range logits {
			probs[i] = float32(math.Exp(float64(logits[i] - lmax)))
			z += probs[i]
		}
		for i := range probs {
			probs[i] /= z
		}
		order := make([]int, numExp)
		for i := range order {
			order[i] = i
		}
		sort.Slice(order, func(a, b int) bool { return probs[order[a]] > probs[order[b]] })

		// renormalize softmax over the top-k set (Gemma routers)
		topW := make([]float32, topK)
		var zk float32
		for t := 0; t < topK; t++ {
			topW[t] = probs[order[t]]
			zk += topW[t]
		}
		if zk > 0 {
			for t := range topW {
				topW[t] /= zk
			}
		}
		perExp := g.m.vec(L + "router.per_expert_scale")

		// experts.gate_up_proj: [numExp, 2*moeInter, hidden] (row-major):
		// row index = e*2*moeInter + half.  down_proj: [numExp, hidden, moeInter]:
		// row index = e*hidden + out-row.  Read only the dispatched rows.
		for t := 0; t < topK; t++ {
			e := order[t]
			w := topW[t]
			// gate_up rows for this expert: [e*2M, (e+1)*2M)
			guRaw := ReadRealTensorRowRange(
				g.m.dir,
				g.m.desc[L+"experts.gate_up_proj"],
				numExp*2*moeInter, h,
				e*2*moeInter, (e+1)*2*moeInter,
			)
			gu := make([]float32, 2*moeInter)
			for i := 0; i < 2*moeInter; i++ {
				gu[i] = bf16ToF32(binary.LittleEndian.Uint16(guRaw[i*2:]))
			}
			gateE := gu[:moeInter]
			upE := gu[moeInter:]
			moeMid := make([]float32, moeInter)
			for i := 0; i < moeInter; i++ {
				moeMid[i] = geluTanh(gateE[i]) * upE[i]
			}
			ddRaw := ReadRealTensorRowRange(
				g.m.dir,
				g.m.desc[L+"experts.down_proj"],
				numExp*h, moeInter,
				e*h, (e+1)*h,
			)
			dd := make([]float32, h)
			for r := 0; r < h; r++ {
				var acc float32
				for c := 0; c < moeInter; c++ {
					acc += bf16ToF32(binary.LittleEndian.Uint16(ddRaw[(r*moeInter+c)*2:])) * moeMid[c]
				}
				dd[r] = acc
			}

			// accumulate: router weight * per-expert scale * output
			for i := 0; i < h; i++ {
				moeOut[i] += w * perExp[e] * dd[i]
			}
		}
	}

	// combine dense + moe, apply ff val layernorms
	ffSum := make([]float32, h)
	for i := 0; i < h; i++ {
		ffSum[i] = denseOut[i] + moeOut[i]
	}
	ffNorm := rmsNorm(ffSum, g.m.vec(L+"post_feedforward_layernorm.weight"), 1e-6)
	ffNorm2 := rmsNorm(ffResidual, g.m.vec(L+"pre_feedforward_layernorm_2.weight"), 1e-6)
	comb := make([]float32, h)
	for i := 0; i < h; i++ {
		comb[i] = ffNorm[i] + ffNorm2[i]
	}
	combNorm := rmsNorm(comb, g.m.vec(L+"post_feedforward_layernorm_1.weight"), 1e-6)
	ffRes2 := rmsNorm(ffResidual, g.m.vec(L+"post_feedforward_layernorm_2.weight"), 1e-6)
	for i := 0; i < h; i++ {
		ffResidual[i] = combNorm[i] + ffRes2[i]
	}
	copy(x, ffResidual)
	return nil
}

// kvCache stores per-layer key/value tensors for decode-time attention.
type kvEntry struct {
	k [][]float32
	v [][]float32
	n int
}

type gemmaKV struct {
	layers []kvEntry
}

type gemmaForward struct {
	g       *gemmaModel
	kv      *gemmaKV
	prefPos int
}

func newGF(g *gemmaModel) *gemmaForward {
	return &gemmaForward{g: g, kv: nil, prefPos: 0}
}

// ============================================================================
// Full-sequence forward with real (multi-position) attention + KV cache.
// ============================================================================

func (gf *gemmaForward) prefill(seq [][]float32) error {
	g := gf.g
	T := len(seq)
	H := g.hidden
	gf.kv = &gemmaKV{layers: make([]kvEntry, g.cfg.TextConfig.NumHiddenLayers)}
	for l := 0; l < g.cfg.TextConfig.NumHiddenLayers; l++ {
		L := fmt.Sprintf("model.language_model.layers.%d.", l)
		full := false
		if g.cfg.TextConfig.LayerTypes != nil && l >= 0 && l < len(g.cfg.TextConfig.LayerTypes) {
			full = g.cfg.TextConfig.LayerTypes[l] == "full_attention"
		} else {
			full = l%6 == 5
		}

		headDim := g.cfg.TextConfig.HeadDim
		kvHeads := g.cfg.TextConfig.NumKeyValueHeads
		qHeads := g.cfg.TextConfig.NumAttentionHeads
		if full {
			headDim = g.cfg.TextConfig.GlobalHeadDim
			kvHeads = g.cfg.TextConfig.NumGlobalKVHeads
		}
		qRows := qHeads * headDim
		kRows := kvHeads * headDim
		inter := g.cfg.TextConfig.IntermediateSize
		moeInter := g.cfg.TextConfig.MoEIntermediateSize
		numExp := g.cfg.TextConfig.NumExperts
		topK := g.cfg.TextConfig.TopKExperts
		sliding := g.cfg.TextConfig.SlidingWindow

		Wq := g.m.mat(L+"self_attn.q_proj.weight", qRows, H)
		Wk := g.m.mat(L+"self_attn.k_proj.weight", kRows, H)
		Wo := g.m.mat(L+"self_attn.o_proj.weight", H, qRows)
		Wv := Wk
		if !full {
			Wv = g.m.mat(L+"self_attn.v_proj.weight", kRows, H)
		}
		qNormW := g.m.vec(L + "self_attn.q_norm.weight")
		kNormW := g.m.vec(L + "self_attn.k_norm.weight")
		inNorm := g.m.vec(L + "input_layernorm.weight")
		postNorm := g.m.vec(L + "post_attention_layernorm.weight")
		preNorm := g.m.vec(L + "pre_feedforward_layernorm.weight")
		preNorm2 := g.m.vec(L + "pre_feedforward_layernorm_2.weight")
		postFF := g.m.vec(L + "post_feedforward_layernorm.weight")
		postFF1 := g.m.vec(L + "post_feedforward_layernorm_1.weight")
		postFF2 := g.m.vec(L + "post_feedforward_layernorm_2.weight")
		Wgate := g.m.mat(L+"mlp.gate_proj.weight", inter, H)
		Wup := g.m.mat(L+"mlp.up_proj.weight", inter, H)
		Wdown := g.m.mat(L+"mlp.down_proj.weight", H, inter)
		routerW := g.m.mat(L+"router.proj.weight", numExp, H)
		perExp := g.m.vec(L + "router.per_expert_scale")

		xs := make([][]float32, T)
		for t := 0; t < T; t++ {
			xs[t] = make([]float32, H)
			copy(xs[t], seq[t])
		}

		// ---- attention: project + norm + rope for every position ----
		qs := make([][]float32, T)
		ks := make([][]float32, T)
		vs := make([][]float32, T)
		for t := 0; t < T; t++ {
			xn := rmsNorm(xs[t], inNorm, 1e-6)
			q := make([]float32, qRows)
			k := make([]float32, kRows)
			v := make([]float32, kRows)
			matVec(Wq, xn, q)
			matVec(Wk, xn, k)
			// value = v_proj(x) (sliding) or k_raw (full, k_eq_v); then v_norm
			if full {
				copy(v, k)
			} else {
				matVec(Wv, xn, v)
			}
			v = vNorm(v, 1e-6)
			qH := splitHeads(q, qHeads, headDim)
			kH := splitHeads(k, kvHeads, headDim)
			for i := 0; i < qHeads; i++ {
				nq := rmsNorm(qH[i], qNormW, 1e-6)
				copy(qH[i], nq)
			}
			for i := 0; i < kvHeads; i++ {
				nk := rmsNorm(kH[i], kNormW, 1e-6)
				copy(kH[i], nk)
			}
			if full {
				rotary(qH, 1e6, 0.25, t)
				rotary(kH, 1e6, 0.25, t)
			} else {
				rotary(qH, 1e4, 1.0, t)
				rotary(kH, 1e4, 1.0, t)
			}
			qs[t] = q
			ks[t] = k
			vs[t] = v
		}

		scale := float32(1.0) // Gemma4: scaling = 1.0
		groups := qHeads / kvHeads
		attnOut := make([][]float32, T)
		for t := 0; t < T; t++ {
			attnOut[t] = make([]float32, qRows)
			for qh := 0; qh < qHeads; qh++ {
				kh := qh / groups
				lo := 0
				if !full && sliding > 0 {
					lo = t - sliding + 1
					if lo < 0 {
						lo = 0
					}
				}
				mx := float32(-1e30)
				ln := make([]float32, T-lo)
				for p := lo; p <= t; p++ {
					var sc float32
					for i := 0; i < headDim; i++ {
						sc += qs[t][qh*headDim+i] * ks[p][kh*headDim+i]
					}
					ln[p-lo] = sc * scale
					if ln[p-lo] > mx {
						mx = ln[p-lo]
					}
				}
				var z float32
				for p := lo; p <= t; p++ {
					ln[p-lo] = float32(math.Exp(float64(ln[p-lo] - mx)))
					z += ln[p-lo]
				}
				if z > 0 {
					for p := lo; p <= t; p++ {
						ln[p-lo] /= z
					}
				}
				for i := 0; i < headDim; i++ {
					var acc float32
					for p := lo; p <= t; p++ {
						acc += ln[p-lo] * vs[p][kh*headDim+i]
					}
					attnOut[t][qh*headDim+i] = acc
				}
			}
		}

		for t := 0; t < T; t++ {
			oFlat := make([]float32, H)
			matVec(Wo, attnOut[t], oFlat)
			oNorm := rmsNorm(oFlat, postNorm, 1e-6)
			for i := 0; i < H; i++ {
				xs[t][i] += oNorm[i]
			}
		}

		// ---- feedforward: dense mlp + moe ----
		for t := 0; t < T; t++ {
			ffRes := make([]float32, H)
			copy(ffRes, xs[t])
			x2 := rmsNorm(xs[t], preNorm, 1e-6)
			gate := make([]float32, inter)
			up := make([]float32, inter)
			mid := make([]float32, inter)
			matVec(Wgate, x2, gate)
			matVec(Wup, x2, up)
			for i := 0; i < inter; i++ {
				mid[i] = geluTanh(gate[i]) * up[i]
			}
			denseOut := make([]float32, H)
			matVec(Wdown, mid, denseOut)

			moeOut := make([]float32, H)
			if numExp > 0 && topK > 0 {
				// Gemma4: MoE branch operates on RMSNorm'd residual
				// experts consume pre_ff_2(residual); the router transforms
				// the PLAIN residual (its own scale-less norm + scale)
				moeIn := rmsNorm(ffRes, preNorm2, 1e-6)
				rtScale := g.m.vec(L + "router.scale")
				ri := gemmaRouterInput(ffRes, rtScale, H)
				logits := make([]float32, numExp)
				matVec(routerW, ri, logits)
				var lmax float32 = -1e30
				for i := range logits {
					if logits[i] > lmax {
						lmax = logits[i]
					}
				}
				probs := make([]float32, numExp)
				var z float32
				for i := range logits {
					probs[i] = float32(math.Exp(float64(logits[i] - lmax)))
					z += probs[i]
				}
				if z > 0 {
					for i := range probs {
						probs[i] /= z
					}
				}
				order := make([]int, numExp)
				for i := range order {
					order[i] = i
				}
				sort.Slice(order, func(a, b int) bool { return probs[order[a]] > probs[order[b]] })
				topW := make([]float32, topK)
				var zk float32
				for tt := 0; tt < topK; tt++ {
					topW[tt] = probs[order[tt]]
					zk += topW[tt]
				}
				if zk > 0 {
					for tt := range topW {
						topW[tt] /= zk
					}
				}
				for tt := 0; tt < topK; tt++ {
					e := order[tt]
					w := topW[tt]
					guRaw := ReadRealTensorRowRange(g.m.dir, g.m.desc[L+"experts.gate_up_proj"],
						numExp*2*moeInter, H, e*2*moeInter, (e+1)*2*moeInter)
					gu := make([]float32, 2*moeInter*H)
					for i := 0; i < 2*moeInter*H; i++ {
						gu[i] = bf16ToF32(binary.LittleEndian.Uint16(guRaw[i*2:]))
					}
					moeMid := make([]float32, moeInter)
					for i := 0; i < moeInter; i++ {
						// expert input comes from the normalized residual
						var gv, uv float32
						for c := 0; c < H; c++ {
							gv += gu[i*H+c] * moeIn[c]
							uv += gu[(moeInter+i)*H+c] * moeIn[c]
						}
						moeMid[i] = geluTanh(gv) * uv
					}
					ddRaw := ReadRealTensorRowRange(g.m.dir, g.m.desc[L+"experts.down_proj"],
						numExp*H, moeInter, e*H, (e+1)*H)
					for r := 0; r < H; r++ {
						var acc float32
						for c := 0; c < moeInter; c++ {
							acc += bf16ToF32(binary.LittleEndian.Uint16(ddRaw[(r*moeInter+c)*2:])) * moeMid[c]
						}
						moeOut[r] += w * perExp[e] * acc
					}
				}
			}

			// Gemma4: h1 = post_ff_1(dense_mlp(x)); h2 = post_ff_2(moe(residual));
			// h = post_ff(h1 + h2); out = residual + h
			h1 := rmsNorm(denseOut, postFF1, 1e-6)
			h2 := rmsNorm(moeOut, postFF2, 1e-6)
			comb := make([]float32, H)
			for i := 0; i < H; i++ {
				comb[i] = h1[i] + h2[i]
			}
			ffNorm := rmsNorm(comb, postFF, 1e-6)
			for i := 0; i < H; i++ {
				xs[t][i] = ffRes[i] + ffNorm[i]
			}
		}
		lsW := g.m.vec(L + "layer_scalar")
		if len(lsW) > 0 {
			for t := 0; t < T; t++ {
				for i := 0; i < H; i++ {
					xs[t][i] *= lsW[0]
				}
			}
		}

		// store KV
		gf.kv.layers[l].k = make([][]float32, kvHeads)
		gf.kv.layers[l].v = make([][]float32, kvHeads)
		for h := 0; h < kvHeads; h++ {
			gf.kv.layers[l].k[h] = make([]float32, T*headDim)
			gf.kv.layers[l].v[h] = make([]float32, T*headDim)
			for t := 0; t < T; t++ {
				for i := 0; i < headDim; i++ {
					gf.kv.layers[l].k[h][t*headDim+i] = ks[t][h*headDim+i]
					gf.kv.layers[l].v[h][t*headDim+i] = vs[t][h*headDim+i]
				}
			}
		}
		gf.kv.layers[l].n = T

		for t := 0; t < T; t++ {
			seq[t] = xs[t]
		}
		if os.Getenv("PNM_DEBUG") != "" {
			var n float64
			for t := 0; t < T; t++ {
				for i := 0; i < H; i++ {
					n += float64(seq[t][i]) * float64(seq[t][i])
				}
			}
			os.WriteFile("/tmp/pnm_norm.txt", []byte(fmt.Sprintf("layer %d rms %.4f\n", l, math.Sqrt(n/float64(T*H)))), 0644)
		}
	}
	gf.prefPos = T
	return nil
}

// forward runs the whole 30-layer stack + final norm + tied logits for one
// token embedding vector, returning the logits over the vocab (this is the
// expensive path; for decoding we compute hidden then score with the
// embedding matrix).
func (g *gemmaModel) forwardDecode(gf *gemmaForward, cur []float32) ([]float32, error) {
	H := g.hidden
	if gf.kv == nil {
		return nil, fmt.Errorf("decode before prefill")
	}
	// per-layer: process the current position through every layer
	pos := cur
	for l := 0; l < g.cfg.TextConfig.NumHiddenLayers; l++ {
		L := fmt.Sprintf("model.language_model.layers.%d.", l)
		full := false
		if g.cfg.TextConfig.LayerTypes != nil && l >= 0 && l < len(g.cfg.TextConfig.LayerTypes) {
			full = g.cfg.TextConfig.LayerTypes[l] == "full_attention"
		}

		headDim := g.cfg.TextConfig.HeadDim
		kvHeads := g.cfg.TextConfig.NumKeyValueHeads
		qHeads := g.cfg.TextConfig.NumAttentionHeads
		if full {
			headDim = g.cfg.TextConfig.GlobalHeadDim
			kvHeads = g.cfg.TextConfig.NumGlobalKVHeads
		}
		qRows := qHeads * headDim
		kRows := kvHeads * headDim
		inter := g.cfg.TextConfig.IntermediateSize
		moeInter := g.cfg.TextConfig.MoEIntermediateSize
		numExp := g.cfg.TextConfig.NumExperts
		topK := g.cfg.TextConfig.TopKExperts
		sliding := g.cfg.TextConfig.SlidingWindow

		Wq := g.m.mat(L+"self_attn.q_proj.weight", qRows, H)
		Wk := g.m.mat(L+"self_attn.k_proj.weight", kRows, H)
		Wv := g.m.mat(L+"self_attn.v_proj.weight", kRows, H)
		Wo := g.m.mat(L+"self_attn.o_proj.weight", H, qRows)
		qNormW := g.m.vec(L + "self_attn.q_norm.weight")
		kNormW := g.m.vec(L + "self_attn.k_norm.weight")
		inNorm := g.m.vec(L + "input_layernorm.weight")
		postNorm := g.m.vec(L + "post_attention_layernorm.weight")
		preNorm := g.m.vec(L + "pre_feedforward_layernorm.weight")
		preNorm2 := g.m.vec(L + "pre_feedforward_layernorm_2.weight")
		postFF := g.m.vec(L + "post_feedforward_layernorm.weight")
		postFF1 := g.m.vec(L + "post_feedforward_layernorm_1.weight")
		postFF2 := g.m.vec(L + "post_feedforward_layernorm_2.weight")
		Wgate := g.m.mat(L+"mlp.gate_proj.weight", inter, H)
		Wup := g.m.mat(L+"mlp.up_proj.weight", inter, H)
		Wdown := g.m.mat(L+"mlp.down_proj.weight", H, inter)
		routerW := g.m.mat(L+"router.proj.weight", numExp, H)
		perExp := g.m.vec(L + "router.per_expert_scale")

		// attention for the current position
		xn := rmsNorm(pos, inNorm, 1e-6)
		q := make([]float32, qRows)
		k := make([]float32, kRows)
		v := make([]float32, kRows)
		matVec(Wq, xn, q)
		matVec(Wk, xn, k)
		if full {
			copy(v, k)
		} else {
			matVec(Wv, xn, v)
		}
		v = vNorm(v, 1e-6)
		qH := splitHeads(q, qHeads, headDim)
		kH := splitHeads(k, kvHeads, headDim)
		vH := splitHeads(v, kvHeads, headDim)
		for i := 0; i < qHeads; i++ {
			nq := rmsNorm(qH[i], qNormW, 1e-6)
			copy(qH[i], nq)
		}
		for i := 0; i < kvHeads; i++ {
			nk := rmsNorm(kH[i], kNormW, 1e-6)
			copy(kH[i], nk)
		}
		posDec := gf.prefPos
		if full {
			rotary(qH, 1e6, 0.25, posDec)
			rotary(kH, 1e6, 0.25, posDec)
		} else {
			rotary(qH, 1e4, 1.0, posDec)
			rotary(kH, 1e4, 1.0, posDec)
		}

		// append to KV cache
		kv := &gf.kv.layers[l]
		n := kv.n
		for h := 0; h < kvHeads; h++ {
			// grow
			need := (n + 1) * headDim
			if len(kv.k[h]) < need {
				nk2 := make([]float32, need*2)
				copy(nk2, kv.k[h])
				kv.k[h] = nk2
				nv2 := make([]float32, need*2)
				copy(nv2, kv.v[h])
				kv.v[h] = nv2
			}
			for i := 0; i < headDim; i++ {
				kv.k[h][n*headDim+i] = kH[h][i]
				kv.v[h][n*headDim+i] = vH[h][i]
			}
		}

		// attend to all KV positions (causal; sliding windows apply a window)
		scale := float32(1.0) // Gemma4: scaling = 1.0
		groups := qHeads / kvHeads
		attnOut := make([]float32, qRows)
		for qh := 0; qh < qHeads; qh++ {
			kh := qh / groups
			lo := 0
			if !full && sliding > 0 && n >= sliding {
				lo = n - sliding + 1
			}
			mx := float32(-1e30)
			ln := make([]float32, n-lo+1)
			for p := lo; p <= n; p++ {
				var sc float32
				for i := 0; i < headDim; i++ {
					sc += qH[qh][i] * kv.k[kh][p*headDim+i]
				}
				ln[p-lo] = sc * scale
				if ln[p-lo] > mx {
					mx = ln[p-lo]
				}
			}
			var z float32
			for p := lo; p <= n; p++ {
				ln[p-lo] = float32(math.Exp(float64(ln[p-lo] - mx)))
				z += ln[p-lo]
			}
			if z > 0 {
				for p := lo; p <= n; p++ {
					ln[p-lo] /= z
				}
			}
			for i := 0; i < headDim; i++ {
				var acc float32
				for p := lo; p <= n; p++ {
					acc += ln[p-lo] * kv.v[kh][p*headDim+i]
				}
				attnOut[qh*headDim+i] = acc
			}
		}
		kv.n = n + 1
		gf.prefPos = kv.n

		// residual + post-attn norm
		oFlat := make([]float32, H)
		matVec(Wo, attnOut, oFlat)
		oNorm := rmsNorm(oFlat, postNorm, 1e-6)
		for i := 0; i < H; i++ {
			pos[i] = pos[i] + oNorm[i]
		}

		// FFN
		ffRes := make([]float32, H)
		copy(ffRes, pos)
		x2 := rmsNorm(pos, preNorm, 1e-6)
		gate := make([]float32, inter)
		up := make([]float32, inter)
		mid := make([]float32, inter)
		matVec(Wgate, x2, gate)
		matVec(Wup, x2, up)
		for i := 0; i < inter; i++ {
			mid[i] = geluTanh(gate[i]) * up[i]
		}
		denseOut := make([]float32, H)
		matVec(Wdown, mid, denseOut)

		moeOut := make([]float32, H)
		if numExp > 0 && topK > 0 {
			// experts consume pre_ff_2(residual); router transforms plain residual
			moeIn := rmsNorm(ffRes, preNorm2, 1e-6)
			rtScale := g.m.vec(L + "router.scale")
			ri := gemmaRouterInput(ffRes, rtScale, H)
			logits := make([]float32, numExp)
			matVec(routerW, ri, logits)
			var lmax float32 = -1e30
			for i := range logits {
				if logits[i] > lmax {
					lmax = logits[i]
				}
			}
			probs := make([]float32, numExp)
			var z float32
			for i := range logits {
				probs[i] = float32(math.Exp(float64(logits[i] - lmax)))
				z += probs[i]
			}
			if z > 0 {
				for i := range probs {
					probs[i] /= z
				}
			}
			order := make([]int, numExp)
			for i := range order {
				order[i] = i
			}
			sort.Slice(order, func(a, b int) bool { return probs[order[a]] > probs[order[b]] })
			topW := make([]float32, topK)
			var zk float32
			for tt := 0; tt < topK; tt++ {
				topW[tt] = probs[order[tt]]
				zk += topW[tt]
			}
			if zk > 0 {
				for tt := range topW {
					topW[tt] /= zk
				}
			}
			for tt := 0; tt < topK; tt++ {
				e := order[tt]
				w := topW[tt]
				guRaw := ReadRealTensorRowRange(g.m.dir, g.m.desc[L+"experts.gate_up_proj"],
					numExp*2*moeInter, H, e*2*moeInter, (e+1)*2*moeInter)
				gu := make([]float32, 2*moeInter*H)
				for i := 0; i < 2*moeInter*H; i++ {
					gu[i] = bf16ToF32(binary.LittleEndian.Uint16(guRaw[i*2:]))
				}
				moeMid := make([]float32, moeInter)
				for i := 0; i < moeInter; i++ {
					var gv, uv float32
					for c := 0; c < H; c++ {
						gv += gu[i*H+c] * moeIn[c]
						uv += gu[(moeInter+i)*H+c] * moeIn[c]
					}
					moeMid[i] = geluTanh(gv) * uv
				}
				ddRaw := ReadRealTensorRowRange(g.m.dir, g.m.desc[L+"experts.down_proj"],
					numExp*H, moeInter, e*H, (e+1)*H)
				for r := 0; r < H; r++ {
					var acc float32
					for c := 0; c < moeInter; c++ {
						acc += bf16ToF32(binary.LittleEndian.Uint16(ddRaw[(r*moeInter+c)*2:])) * moeMid[c]
					}
					moeOut[r] += w * perExp[e] * acc
				}
			}
		}
		h1 := rmsNorm(denseOut, postFF1, 1e-6)
		h2 := rmsNorm(moeOut, postFF2, 1e-6)
		comb := make([]float32, H)
		for i := 0; i < H; i++ {
			comb[i] = h1[i] + h2[i]
		}
		ffNorm := rmsNorm(comb, postFF, 1e-6)
		for i := 0; i < H; i++ {
			pos[i] = ffRes[i] + ffNorm[i]
		}
		lsW := g.m.vec(L + "layer_scalar")
		if len(lsW) > 0 {
			for i := 0; i < H; i++ {
				pos[i] *= lsW[0]
			}
		}
	}


// final norm + tied logits
	finalW := g.m.vec("model.language_model.norm.weight")
	if finalW == nil {
		finalW = g.m.vec("model.language_model.model.norm.weight")
	}
	if finalW == nil {
		for name := range g.m.desc {
			if strings.HasSuffix(name, ".norm.weight") {
				finalW = g.m.vec(name)
				if finalW != nil {
					break
				}
			}
		}
	}
	if finalW == nil {
		return nil, fmt.Errorf("final norm weight not found")
	}
	hs := rmsNorm(pos, finalW, 1e-6)

	embed := g.m.mat("model.language_model.embed_tokens.weight", g.cfg.TextConfig.VocabSize, g.hidden)
	logits := make([]float32, g.cfg.TextConfig.VocabSize)
	for v := 0; v < g.cfg.TextConfig.VocabSize; v++ {
		var acc float32
		row := embed[v]
		for c := 0; c < g.hidden; c++ {
			acc += row[c] * hs[c]
		}
		logits[v] = acc
	}
	softcap(logits, 30)
	return logits, nil
}



// ============================================================================
// High-level generation entry point
// ============================================================================

// RealGenerate loads the real checkpoint and decodes GreedyTokens tokens
// autoregressively for the prompt, returning decoded text.  Returns an
// error with a clear message when the shards are absent (synthetic fallback
// should be used instead).
func RealGenerate(modelDir string, dims Dims, prompt string, maxTokens int, vocab *BPEVocab) (string, []int, error) {
	if vocab == nil {
		return "", nil, fmt.Errorf("real generate: nil vocab")
	}
	cfg, err := LoadModelConfig(modelDir)
	if err != nil {
		return "", nil, err
	}
	idx, err := LoadSafetensorsIndex(modelDir)
	if err != nil {
		return "", nil, err
	}
	desc, err := ParseSafetensorsHeaders(modelDir, idx)
	if err != nil {
		return "", nil, err
	}
	rm := newRealModel(modelDir, desc)
	// check the embed weights exist (the critical real-weight file)
	if rm.tensorBytes("model.language_model.embed_tokens.weight") == nil {
		return "", nil, fmt.Errorf("real weights missing (embed_tokens not found); use the synthetic client")
	}
	g := &gemmaModel{m: rm, cfg: cfg, hidden: cfg.TextConfig.HiddenSize, vocab: vocab}

	ids, err := vocab.Encode(prompt)
	if err != nil {
		return "", nil, err
	}
	// prepend BOS
	full := append([]int{g.vocab.BosID}, ids...)

	// embed tokens -> hidden sequence [T][H]
	embed := g.m.mat("model.language_model.embed_tokens.weight", cfg.TextConfig.VocabSize, g.hidden)
	T := len(full)
	seq := make([][]float32, T)
	embScale := float32(math.Sqrt(float64(g.hidden)))
	for tt, id := range full {
		row := make([]float32, g.hidden)
		for c := 0; c < g.hidden; c++ {
			row[c] = embed[id][c] * embScale
		}
		seq[tt] = row
	}

	// prefill: run the whole prompt with real multi-position attention
	gf := newGF(g)
	if err := gf.prefill(seq); err != nil {
		return "", nil, err
	}
	hidden := make([]float32, g.hidden)
	copy(hidden, seq[T-1])

	// decode loop: greedy, one token at a time (re-run all layers on the
	// single next-token position with the KV cache from prefill).
	generated := []int{}
	for t := 0; t < maxTokens; t++ {
		logits, err := g.forwardDecode(gf, hidden)
		if err != nil {
			break
		}
		best := sampleToken(logits, 0.8) // temperature sampling
		generated = append(generated, best)
		if os.Getenv("PNM_DEBUG") != "" {
			type lg struct{ id int; v float32 }
			var top [8]lg
			for i, v := range logits {
				for j := 0; j < 8; j++ {
					if v > top[j].v {
						copy(top[j+1:], top[j:7])
						top[j] = lg{i, v}
						break
					}
				}
			}
			var sb strings.Builder
			vt := g.vocab.IDToToken
			for _, l := range top {
				tk := "?"
				if l.id < len(vt) {
					tk = vt[l.id]
				}
				sb.WriteString(fmt.Sprintf("%q=%.1f ", tk, l.v))
			}
			// probe a few expected tokens
			for _, probe := range []string{"Paris", "Europe", "France", "Berlin"} {
				if id, ok := g.vocab.TokenToID[probe]; ok {
					sb.WriteString(fmt.Sprintf(" [%s=%d:%.1f]", probe, id, logits[id]))
				} else if id, ok := g.vocab.TokenToID["\u2581"+probe]; ok {
					sb.WriteString(fmt.Sprintf(" [%s=%d:%.1f]", probe, id, logits[id]))
				}
			}
			os.WriteFile("/tmp/pnm_step.txt", []byte(fmt.Sprintf("step %d hidRMS=%.2f top8: %s", t, hiddenRMS(hidden), sb.String())), 0644)
		}
		tok := g.vocab.IDToToken[best]
		if tok == "<eos>" || tok == "<end_of_turn>" || tok == "<pad>" {
			break
		}
		// next hidden = embedded (scaled) token
		for c := 0; c < g.hidden; c++ {
			hidden[c] = embed[best][c] * embScale
		}
	}

	out := generated
	text := vocab.Decode(out)
	return strings.TrimSpace(text), out, nil
}
