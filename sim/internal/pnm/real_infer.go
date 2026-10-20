package pnm

import (
	"encoding/binary"
	"fmt"
	"math"
	"os"
	"sort"
	"strings"
)

// maxGenSafetyTokens caps the decode loop when the caller asks for
// "unbounded" generation (maxTokens <= 0): the model normally stops on a
// stop token long before this, but a runaway loop is still bounded.
const maxGenSafetyTokens = 8192

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

// roundBF16 rounds x to nearest-even bf16 (round-to-odd trap avoided). The
// reference (HF/torch/vLLM) stores the residual stream, embeddings and KV
// cache in bf16 between operations; rounding at the same boundaries pins the
// engine onto the reference trajectory so near-ties (router top-k, stop
// tokens) break the same way, while inner ops keep full f32 precision.
func roundBF16(x float32) float32 {
	bits := math.Float32bits(x)
	if bits&0x7F800000 == 0x7F800000 {
		return x // inf/nan pass through
	}
	return math.Float32frombits((bits + 0x7FFF + ((bits >> 16) & 1)) & 0xFFFF0000)
}

// gemmaRouterInput applies the Gemma4 router pre-transform:
// norm_NO_scale(x) * router.scale * hidden_size^-0.5, returning a new vector.
// HF (Gemma4TextRouter.forward) stores the norm output, the *scale product
// and the *scalar_root_size product as bf16 between steps — emulate the same
// three casts so near-ties in the top-k gate break identically.
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
		a := roundBF16(x[i] * inv)
		b := roundBF16(a * s)
		out[i] = roundBF16(b * root)
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
		// RMSNorm output is stored bf16 (type_as) in the reference
		out[i] = roundBF16(x[i] * inv * w[i])
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
		// every Linear output is stored bf16 in the reference
		out[r] = roundBF16(acc)
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
	// The checkpoint's generation_config.json is
	// {do_sample:true, temperature:1.0, top_k:64, top_p:0.95}; the official
	// model is meant to be sampled, not run greedily (greedy degenerates to
	// echoing the prompt for this template). Apply the same top-k/top-p
	// truncation here so sampled output matches the reference distribution.
	// top_p is tightened to 0.90 (vs the checkpoint's 0.95) so sampled runs
	// stay on the answer instead of wandering into a tangential completion.
	const topK = 64
	const topP = 0.90
	// softmax with temperature
	mx := logits[0]
	for _, v := range logits {
		if v > mx {
			mx = v
		}
	}
	type sp struct {
		idx int
		pr  float64
	}
	cand := make([]sp, len(logits))
	for i, v := range logits {
		cand[i] = sp{i, math.Exp(float64(v-mx) / float64(temp))}
	}
	// top-p (nucleus): sort by probability descending, keep the smallest set
	// whose cumulative mass reaches topP (always at least one token).
	sort.Slice(cand, func(a, b int) bool { return cand[a].pr > cand[b].pr })
	nk := topK
	if nk > len(cand) {
		nk = len(cand)
	}
	var mass float64
	for i := 0; i < len(cand); i++ {
		if i >= nk {
			cand[i].pr = 0
			continue
		}
		mass += cand[i].pr
	}
	var kept float64
	cut := topK
	for i := 0; i < len(cand) && i < topK; i++ {
		kept += cand[i].pr
		if kept/mass >= topP {
			cut = i + 1
			break
		}
	}
	if cut < 1 {
		cut = 1
	}
	var sum float64
	probs := make([]float64, len(logits))
	for i := 0; i < cut; i++ {
		probs[cand[i].idx] = cand[i].pr
		sum += cand[i].pr
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
		if pr == 0 {
			continue
		}
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
	// HF applies final_logit_softcapping to the bf16 lm_head output with
	// bf16-preserving ops: div, tanh and mul each store bf16.
	for i := range x {
		v := roundBF16(x[i] / c)
		v = roundBF16(float32(math.Tanh(float64(v))))
		x[i] = roundBF16(v * c)
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
			// rope runs on bf16 tensors: cos/sin cast to bf16, each
			// rotation output stored bf16
			c := roundBF16(float32(math.Cos(freq)))
			s := roundBF16(float32(math.Sin(freq)))
			x0 := q[h][i]
			x1 := q[h][i+half]
			q[h][i] = roundBF16(x0*c - x1*s)
			q[h][i+half] = roundBF16(x0*s + x1*c)
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
	// gate, when non-nil, supplies router logits for selected layers from the
	// hardware Gating ASIC instead of the software matVec. See gating_harness.go.
	gate routerGate

	// prefillLastGate limits ASIC gating during prefill to the final position
	// (all positions are gated when false).
	prefillLastGate bool
	prefillT        int
}

// routerGate abstracts a hardware Gating ASIC serving router logits.
type routerGate interface {
	// Has reports whether layer l's routing is supplied by the hardware.
	Has(layer int) bool
	// Route returns numExperts BF16 router logits for the given (already
	// per-dim BF16) router input vector.
	Route(layer int, ri []float32) ([]float32, error)
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
	// embeddings are stored bf16 in the reference
	for t := 0; t < T; t++ {
		for c := 0; c < H; c++ {
			seq[t][c] = roundBF16(seq[t][c])
		}
	}
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
			vH0 := splitHeads(v, kvHeads, headDim)
			for i := 0; i < kvHeads; i++ {
				nv := vNorm(vH0[i], 1e-6)
				for j := range nv {
					nv[j] = roundBF16(nv[j]) // v_norm out is bf16
				}
				copy(vH0[i], nv)
			}
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
			for i := range attnOut[t] {
				attnOut[t][i] = roundBF16(attnOut[t][i]) // SDPA out is bf16
			}
		}

		for t := 0; t < T; t++ {
			oFlat := make([]float32, H)
			matVec(Wo, attnOut[t], oFlat)
			oNorm := rmsNorm(oFlat, postNorm, 1e-6)
			for i := 0; i < H; i++ {
				xs[t][i] = roundBF16(xs[t][i] + oNorm[i])
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
				mid[i] = roundBF16(roundBF16(geluTanh(gate[i])) * up[i])
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
				if gf.gate != nil && gf.gate.Has(l) && (!gf.prefillLastGate || t == T-1) {
					al, gerr := gf.gate.Route(l, ri)
					if gerr != nil {
						return gerr
					}
					copy(logits, al)
				} else {
					matVec(routerW, ri, logits)
					for i := range logits {
						logits[i] = roundBF16(logits[i]) // HF Linear out is bf16
					}
				}
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
						probs[i] = roundBF16(probs[i] / z) // HF softmax out is bf16
					}
				}
				order := make([]int, numExp)
				for i := range order {
					order[i] = i
				}
				sort.SliceStable(order, func(a, b int) bool { return probs[order[a]] > probs[order[b]] })
				topW := make([]float32, topK)
				var zk float32
				for tt := 0; tt < topK; tt++ {
					topW[tt] = probs[order[tt]]
					zk += topW[tt]
				}
				if zk > 0 {
					for tt := range topW {
						topW[tt] = roundBF16(topW[tt] / roundBF16(zk)) // normalized weights bf16
					}
				}
				if os.Getenv("PNM_DUMP_ROUTES") != "" && t == T-1 {
					f, _ := os.OpenFile("/tmp/pnm_routes.txt", os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
					fmt.Fprintf(f, "route %d ids %v w %v\n", l, order[:topK], topW)
					f.Close()
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
						gv = roundBF16(gv)
						uv = roundBF16(uv)
						moeMid[i] = roundBF16(roundBF16(geluTanh(gv)) * uv)
					}
					ddRaw := ReadRealTensorRowRange(g.m.dir, g.m.desc[L+"experts.down_proj"],
						numExp*H, moeInter, e*H, (e+1)*H)
					for r := 0; r < H; r++ {
						var acc float32
						for c := 0; c < moeInter; c++ {
							acc += bf16ToF32(binary.LittleEndian.Uint16(ddRaw[(r*moeInter+c)*2:])) * moeMid[c]
						}
						acc = roundBF16(acc) // expert down-proj out is bf16
						wt := roundBF16(roundBF16(w) * perExp[e])
						moeOut[r] = roundBF16(moeOut[r] + roundBF16(wt*acc)) // bf16 accumulate
					}
				}
			}

			// Gemma4: h1 = post_ff_1(dense_mlp(x)); h2 = post_ff_2(moe(residual));
			// h = post_ff(h1 + h2); out = residual + h
			h1 := rmsNorm(denseOut, postFF1, 1e-6)
			h2 := rmsNorm(moeOut, postFF2, 1e-6)
			comb := make([]float32, H)
			for i := 0; i < H; i++ {
				comb[i] = roundBF16(h1[i] + h2[i])
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
		// layer-boundary residual stream is stored bf16 in the reference
		for t := 0; t < T; t++ {
			for i := 0; i < H; i++ {
				xs[t][i] = roundBF16(xs[t][i])
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
					gf.kv.layers[l].k[h][t*headDim+i] = roundBF16(ks[t][h*headDim+i])
					gf.kv.layers[l].v[h][t*headDim+i] = roundBF16(vs[t][h*headDim+i])
				}
			}
		}
		gf.kv.layers[l].n = T

		for t := 0; t < T; t++ {
			seq[t] = xs[t]
		}
		if os.Getenv("PNM_DUMP_LAYERS") != "" {
			var b strings.Builder
			for i := 0; i < 8 && i < H; i++ {
				fmt.Fprintf(&b, "%.6g ", seq[T-1][i])
			}
			var n float64
			for i := 0; i < H; i++ {
				n += float64(seq[T-1][i]) * float64(seq[T-1][i])
			}
			f, _ := os.OpenFile("/tmp/pnm_layers.txt", os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
			fmt.Fprintf(f, "layer %d rms %.4f first8 [%s]\n", l, math.Sqrt(n/float64(H)), b.String())
			f.Close()
		}
		if os.Getenv("PNM_DUMP_VECS") != "" {
			var b strings.Builder
			for i := 0; i < H; i++ {
				fmt.Fprintf(&b, "%.8g ", seq[T-1][i])
			}
			f, _ := os.OpenFile("/tmp/pnm_vecs.txt", os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
			fmt.Fprintf(f, "layer %d %s\n", l, b.String())
			f.Close()
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
	for i := 0; i < H; i++ {
		pos[i] = roundBF16(pos[i]) // embedding is stored bf16 in the reference
	}
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
		vH := splitHeads(v, kvHeads, headDim)
		for i := 0; i < kvHeads; i++ {
			nv := vNorm(vH[i], 1e-6)
			for j := range nv {
				nv[j] = roundBF16(nv[j]) // v_norm out is bf16
			}
			copy(vH[i], nv)
		}
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
				kv.k[h][n*headDim+i] = roundBF16(kH[h][i])
				kv.v[h][n*headDim+i] = roundBF16(vH[h][i])
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
		for i := range attnOut {
			attnOut[i] = roundBF16(attnOut[i]) // SDPA out is bf16
		}
		kv.n = n + 1
		gf.prefPos = kv.n

		// residual + post-attn norm
		oFlat := make([]float32, H)
		matVec(Wo, attnOut, oFlat)
		oNorm := rmsNorm(oFlat, postNorm, 1e-6)
		for i := 0; i < H; i++ {
			pos[i] = roundBF16(pos[i] + oNorm[i])
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
			mid[i] = roundBF16(roundBF16(geluTanh(gate[i])) * up[i])
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
			if gf.gate != nil && gf.gate.Has(l) {
				al, gerr := gf.gate.Route(l, ri)
				if gerr != nil {
					return nil, gerr
				}
				copy(logits, al)
			} else {
				matVec(routerW, ri, logits)
				for i := range logits {
					logits[i] = roundBF16(logits[i]) // HF Linear out is bf16
				}
			}
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
					probs[i] = roundBF16(probs[i] / z) // HF softmax out is bf16
				}
			}
			order := make([]int, numExp)
			for i := range order {
				order[i] = i
			}
			sort.SliceStable(order, func(a, b int) bool { return probs[order[a]] > probs[order[b]] })
			topW := make([]float32, topK)
			var zk float32
			for tt := 0; tt < topK; tt++ {
				topW[tt] = probs[order[tt]]
				zk += topW[tt]
			}
			if zk > 0 {
				for tt := range topW {
					topW[tt] = roundBF16(topW[tt] / roundBF16(zk)) // normalized weights bf16
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
					gv = roundBF16(gv)
					uv = roundBF16(uv)
					moeMid[i] = roundBF16(roundBF16(geluTanh(gv)) * uv)
				}
				ddRaw := ReadRealTensorRowRange(g.m.dir, g.m.desc[L+"experts.down_proj"],
					numExp*H, moeInter, e*H, (e+1)*H)
				for r := 0; r < H; r++ {
					var acc float32
					for c := 0; c < moeInter; c++ {
						acc += bf16ToF32(binary.LittleEndian.Uint16(ddRaw[(r*moeInter+c)*2:])) * moeMid[c]
					}
					acc = roundBF16(acc) // expert down-proj out is bf16
					wt := roundBF16(roundBF16(w) * perExp[e])
					moeOut[r] = roundBF16(moeOut[r] + roundBF16(wt*acc)) // bf16 accumulate
				}
			}
		}
		h1 := rmsNorm(denseOut, postFF1, 1e-6)
		h2 := rmsNorm(moeOut, postFF2, 1e-6)
		comb := make([]float32, H)
		for i := 0; i < H; i++ {
			comb[i] = roundBF16(h1[i] + h2[i])
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
		// layer-boundary residual stream is stored bf16 in the reference
		for i := 0; i < H; i++ {
			pos[i] = roundBF16(pos[i])
		}
	}

	return g.finalLogits(pos)
}

// finalLogits applies the final RMS norm and the tied embedding head to a
// hidden state that has already passed through all decoder layers (the output
// of prefill's last position, or forwardDecode's output).
func (g *gemmaModel) finalLogits(pos []float32) ([]float32, error) {
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
	if os.Getenv("PNM_DUMP_VECS") != "" {
		var b strings.Builder
		for i := 0; i < len(hs); i++ {
			fmt.Fprintf(&b, "%.8g ", hs[i])
		}
		f, _ := os.OpenFile("/tmp/pnm_vecs.txt", os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
		fmt.Fprintf(f, "final %s\n", b.String())
		f.Close()
	}
	if os.Getenv("PNM_DUMP_LAYERS") != "" {
		var b strings.Builder
		for i := 0; i < 8 && i < len(hs); i++ {
			fmt.Fprintf(&b, "%.6g ", hs[i])
		}
		var n float64
		for i := 0; i < len(hs); i++ {
			n += float64(hs[i]) * float64(hs[i])
		}
		f, _ := os.OpenFile("/tmp/pnm_layers.txt", os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
		fmt.Fprintf(f, "final rms %.4f first8 [%s]\n", math.Sqrt(n/float64(len(hs))), b.String())
		f.Close()
	}

	embed := g.m.mat("model.language_model.embed_tokens.weight", g.cfg.TextConfig.VocabSize, g.hidden)
	logits := make([]float32, g.cfg.TextConfig.VocabSize)
	for v := 0; v < g.cfg.TextConfig.VocabSize; v++ {
		var acc float32
		row := embed[v]
		for c := 0; c < g.hidden; c++ {
			acc += row[c] * hs[c]
		}
		logits[v] = roundBF16(acc) // lm_head Linear out is bf16
	}
	softcap(logits, 30)
	return logits, nil
}

// ============================================================================
// High-level generation entry point
// ============================================================================

// chatIDs wraps a user prompt in the Gemma-4 IT chat template shipped with
// the model (chat_template.jinja), rendered with enable_thinking=true:
// "<|turn>system\n<|think|>\n<turn|>\n<|turn>user\n{p}<turn|>\n<|turn>model\n".
// The injected system turn (jinja:179-186) is present even without a user
// system message; WITHOUT it the engine drifted from HF and flipped the
// stop-token tie at step 7 (verified: ids now identical to HF's
// apply_chat_template output, and Germany greedy matches HF through the
// terminating "<turn|>"). The template's thinking-DISABLED variant adds an
// empty "<|channel>thought\n<channel|>" block that makes the model echo the
// conversation instead of answering. Special tokens are looked up by ID so
// the pretokenizer never splits them.
func chatIDs(vocab *BPEVocab, prompt string, forceThink bool) ([]int, error) {
	id := func(s string) (int, error) {
		v, ok := vocab.TokenToID[s]
		if !ok {
			return 0, fmt.Errorf("chat template token %q missing from vocab", s)
		}
		return v, nil
	}
	// piece returns Encode output but appends a real newline token (id 107)
	// when the text ended with '\n', since Encode strips whitespace.
	piece := func(s string) ([]int, error) {
		nl := strings.HasSuffix(s, "\n")
		ids, err := vocab.Encode(strings.TrimRight(s, "\n"))
		if err != nil {
			return nil, err
		}
		if nl {
			v, ok := vocab.TokenToID["\n"]
			if ok {
				ids = append(ids, v)
			}
		}
		return ids, nil
	}
	var out []int
	t := func(toks ...string) error {
		for _, s := range toks {
			v, err := id(s)
			if err != nil {
				return err
			}
			out = append(out, v)
		}
		return nil
	}
	if err := t("<|turn>"); err != nil {
		return nil, err
	}
	// enable_thinking rendering: the template injects a system turn with
	// <|think|> at the very top (chat_template.jinja:179-186), even when
	// the caller supplies no system message: <turn>system\n<|think|>\n<turn|>\n
	sysHdr, err := piece("system\n")
	if err != nil {
		return nil, err
	}
	out = append(out, sysHdr...)
	if err := t("<|think|>"); err != nil {
		return nil, err
	}
	nlT, err := piece("\n")
	if err != nil {
		return nil, err
	}
	out = append(out, nlT...)
	if err := t("<turn|>"); err != nil {
		return nil, err
	}
	nlT2, err := piece("\n")
	if err != nil {
		return nil, err
	}
	out = append(out, nlT2...)
	// end injected system turn; now the real user turn
	if err := t("<|turn>"); err != nil {
		return nil, err
	}
	wrap, err := piece("user\n")
	if err != nil {
		return nil, err
	}
	out = append(out, wrap...)
	pids, err := piece(prompt)
	if err != nil {
		return nil, err
	}
	out = append(out, pids...)
	if err := t("<turn|>"); err != nil {
		return nil, err
	}
	nl, err := piece("\n")
	if err != nil {
		return nil, err
	}
	out = append(out, nl...)
	if err := t("<|turn>"); err != nil {
		return nil, err
	}
	m, err := piece("model\n")
	if err != nil {
		return nil, err
	}
	out = append(out, m...)
	if forceThink {
		// Reasoning datapath: the model's thinking turn opens with the
		// reasoning channel "<|channel>thought\n" (special token 100 followed by
		// the literal "thought\n", exactly as chat_template.jinja emits when
		// thinking is DISABLED to CLOSE it) and closes it with "<channel|>"
		// (101) before the final answer. Prefilling the opener makes the model
		// reason deterministically instead of relying on the bf16 sampler to
		// pick token 100 on its own; realGenerateCore then splits the emitted
		// stream into reasoning (before 101) and answer (after 101).
		if err := t("<|channel>"); err != nil {
			return nil, err
		}
		th, err := piece("thought\n")
		if err != nil {
			return nil, err
		}
		out = append(out, th...)
	}
	return out, nil
}

// RealGenerate loads the real checkpoint and decodes GreedyTokens tokens
// autoregressively for the prompt, returning decoded text.  Returns an
// error with a clear message when the shards are absent (synthetic fallback
// should be used instead).
func RealGenerate(modelDir string, dims Dims, prompt string, maxTokens int, vocab *BPEVocab, temp float32) (string, []int, error) {
	if vocab == nil {
		return "", nil, fmt.Errorf("real generate: nil vocab")
	}
	g, err := loadRealGemmaModel(modelDir, vocab)
	if err != nil {
		return "", nil, err
	}

	ids, err := chatIDs(vocab, prompt, false)
	if err != nil {
		return "", nil, err
	}
	// prepend BOS
	full := append([]int{g.vocab.BosID}, ids...)

	answer, _, tokens, err := realGenerateCore(g, full, maxTokens, temp, nil, false, false)
	return answer, tokens, err
}

// RealGenerateThinking is RealGenerate with the reasoning datapath enabled:
// the "<|channel>thought\n" opener is prefilled, the generated stream is split
// at the closing "<channel|>" token, and the reasoning trace is returned
// separately from the final answer.
func RealGenerateThinking(modelDir string, dims Dims, prompt string, maxTokens int, vocab *BPEVocab, temp float32) (answer, reasoning string, tokens []int, err error) {
	if vocab == nil {
		return "", "", nil, fmt.Errorf("real generate: nil vocab")
	}
	g, err := loadRealGemmaModel(modelDir, vocab)
	if err != nil {
		return "", "", nil, err
	}
	ids, err := chatIDs(vocab, prompt, true)
	if err != nil {
		return "", "", nil, err
	}
	full := append([]int{g.vocab.BosID}, ids...)
	return realGenerateCore(g, full, maxTokens, temp, nil, false, true)
}

// loadRealGemmaModel opens the real checkpoint and returns a model handle.
func loadRealGemmaModel(modelDir string, vocab *BPEVocab) (*gemmaModel, error) {
	cfg, err := LoadModelConfig(modelDir)
	if err != nil {
		return nil, err
	}
	idx, err := LoadSafetensorsIndex(modelDir)
	if err != nil {
		return nil, err
	}
	desc, err := ParseSafetensorsHeaders(modelDir, idx)
	if err != nil {
		return nil, err
	}
	rm := newRealModel(modelDir, desc)
	// check the embed weights exist (the critical real-weight file)
	if rm.tensorBytes("model.language_model.embed_tokens.weight") == nil {
		return nil, fmt.Errorf("real weights missing (embed_tokens not found); use the synthetic client")
	}
	return &gemmaModel{m: rm, cfg: cfg, hidden: cfg.TextConfig.HiddenSize, vocab: vocab}, nil
}

// realGenerateCore runs prefill + greedy/sampled decode over the real weights.
// A non-nil gate supplies router logits for selected layers from the Gating
// ASIC instead of the software router matVec.
func realGenerateCore(g *gemmaModel, full []int, maxTokens int, temp float32, gate routerGate, prefillLast, forceThink bool) (answer, reasoning string, tokens []int, err error) {
	// maxTokens <= 0 means "generate until the model emits a stop token
	// (<turn|>/<eos>/...)" — bounded by a safety cap so a runaway model cannot
	// loop forever.
	if maxTokens <= 0 {
		maxTokens = maxGenSafetyTokens
	}
	// embed tokens -> hidden sequence [T][H]
	embed := g.m.mat("model.language_model.embed_tokens.weight", g.cfg.TextConfig.VocabSize, g.hidden)
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
	gf.gate = gate
	gf.prefillLastGate = prefillLast
	if err := gf.prefill(seq); err != nil {
		return "", "", nil, err
	}

	// decode loop: greedy, one token at a time (re-run all layers on the
	// single next-token position with the KV cache from prefill).
	// First-token logits come straight from the prefill output (already
	// layer-processed); feeding that back through forwardDecode would run
	// the stack twice.
	generated := []int{}
	logits, err := g.finalLogits(seq[T-1])
	if err != nil {
		return "", "", nil, err
	}
	// Reasoning datapath state. The IT model emits "<|channel>" (100) to open
	// its reasoning channel before "thought\n...", then "<channel|>" (101) to
	// close it and answer. We always split the generated stream on those
	// tokens; forceThink additionally pre-fills the opener (needed only for a
	// model that does not open the channel on its own, e.g. the base model).
	channelOpen, channelClose := -1, -1
	if v, ok := g.vocab.TokenToID["<|channel>"]; ok {
		channelOpen = v
	}
	if v, ok := g.vocab.TokenToID["<channel|>"]; ok {
		channelClose = v
	}
	inReasoning := forceThink
	var reasonToks, answerToks []int
	hidden := make([]float32, g.hidden)
	for t := 0; t < maxTokens; t++ {
		best := sampleToken(logits, temp) // temp<=0 = greedy
		generated = append(generated, best)
		if os.Getenv("PNM_DEBUG") != "" {
			type lg struct {
				id int
				v  float32
			}
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
		// stop on generation_config.json eos_token_id [1, 106, 50]
		// (<eos>, <turn|>, <|tool_response>) plus legacy end markers
		if tok == "<eos>" || tok == "<end_of_turn>" || tok == "<pad>" ||
			tok == "<turn|>" || tok == "<|tool_response>" {
			break
		}
		// reasoning/answer split: "<|channel>" opens, "<channel|>" closes; the
		// structural tokens are kept out of both streams.
		if best == channelOpen {
			inReasoning = true
		} else if best == channelClose {
			inReasoning = false
		} else if inReasoning {
			reasonToks = append(reasonToks, best)
		} else {
			answerToks = append(answerToks, best)
		}
		// next hidden = embedded (scaled) token
		for c := 0; c < g.hidden; c++ {
			hidden[c] = embed[best][c] * embScale
		}
		logits, err = g.forwardDecode(gf, hidden)
		if err != nil {
			break
		}
	}

	reasoning = strings.TrimSpace(g.vocab.Decode(reasonToks))
	// the channel content is labelled with a leading "thought\n"
	reasoning = strings.TrimSpace(strings.TrimPrefix(reasoning, "thought"))
	answer = strings.TrimSpace(g.vocab.Decode(answerToks))
	return answer, reasoning, generated, nil
}
