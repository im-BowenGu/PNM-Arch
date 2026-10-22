package pnm

// node_composition_test.go — compose the three silicon stages on real
// layer-0 weights and require the chained result to equal the BF16 twin.
//
//   1. GATING ASIC    moe_gating server on layer-0's real router.proj.weight
//                     (width-256 slice, pnmgate's -width mode) returns the
//                     top-k expert decision.
//   2. NODE NETWORK   the decision is dispatched through the real fabric RTL
//                     (RunOne, cycle-exact under vvp) to ExpertNode(layer, e),
//                     carrying the BF16 hidden vector as the wire payload;
//                     RunModelFabric verifies byte-exact delivery.
//   3. COMPUTE NODE   node.v server runs the chosen expert's real gate_up /
//                     down slice (N=16, EFF=8 homunculus) over the delivered
//                     hidden vector; its output must equal expertTwin
//                     (bf16_oracle.go) bit-for-bit.
//
// The same real BF16 words flow through all three legs, so this is the
// gating -> transport -> compute composition proof that the standalone RTL
// testbenches each establish in isolation.  When PNM_MODEL_DIR is set the
// chain runs on the real fused checkpoint; otherwise it runs on the
// deterministic synthetic fixture (comp_model.go) — the chain is identical,
// only the stimulus differs, so this proof is part of the always-on suite.
//
// Requires iverilog/vvp (nix develop).

import (
	"math"
	"os/exec"
	"sort"
	"testing"
)

const (
	compLayer  = 0
	compN      = 16 // node slice hidden width
	compEFF    = 8  // node slice intermediate width
	compGU     = 16 // weight rows = 2*compEFF (BF16 expert)
	compRouter = 256
)

func TestRouterFabricNodeComposition(t *testing.T) {
	if _, err := exec.LookPath("iverilog"); err != nil {
		t.Skip("iverilog not found (enter `nix develop`)")
	}
	if _, err := exec.LookPath("vvp"); err != nil {
		t.Skip("vvp not found (enter `nix develop`)")
	}
	g := loadCompositionModel(t)
	H := g.cfg.TextConfig.HiddenSize
	numExp := g.cfg.TextConfig.NumExperts
	effFull := g.cfg.TextConfig.MoEIntermediateSize

	// ---- the hidden vector: real scaled embedding of token 0 --------------
	// (the model's actual input hidden state; node_reference_test --real uses
	// the same provenance for the expert slice).
	raw := g.m.tensorBytes("model.language_model.embed_tokens.weight")
	if raw == nil || len(raw) < H*2 {
		t.Fatal("embed_tokens tensor missing or too small")
	}
	embedRow := make([]float32, H)
	for i := 0; i < H; i++ {
		w := uint16(raw[2*i]) | uint16(raw[2*i+1])<<8
		embedRow[i] = float32(b16Val(w)) * float32(math.Sqrt(float64(H)))
	}
	hiddenWords := make([]uint16, compN)
	for i := 0; i < compN; i++ {
		hiddenWords[i] = f32ToB16Word(roundBF16(embedRow[i]))
	}

	// ---- 1. GATING ASIC decides the expert --------------------------------
	rtScale := g.m.vec("model.language_model.layers.0.router.scale")
	ri := gemmaRouterInput(embedRow, rtScale, H)
	routerW := g.m.mat("model.language_model.layers.0.router.proj.weight", numExp, H)
	swTop := softmaxTopKAtWidth(routerW, ri, compRouter, 8, numExp)
	gate, err := newGatingClient(GatingConfig{
		RunDir: t.TempDir(), Layers: []int{compLayer}, Width: compRouter,
	}, g)
	if err != nil {
		t.Fatal(err)
	}
	defer gate.Close()
	gLogits, err := gate.Route(compLayer, ri)
	if err != nil {
		t.Fatal(err)
	}
	asicTop := softmaxTopK(gLogits, 8)
	asicTop1 := asicTop[0]
	// The ASIC sees only the width-256 slice; its decision must agree with the
	// software router at the same width (top-1 within the software top-8).
	if !contains(swTop, asicTop1) {
		t.Fatalf("ASIC L0 top-1 = expert %d not in software top-8 %v (width %d)",
			asicTop1, swTop, compRouter)
	}

	// ---- 2. NODE NETWORK transports the hidden vector to the expert node --
	payload := make([]byte, 32)
	for i := 0; i < compN; i++ {
		payload[2*i] = byte(hiddenWords[i] >> 8)
		payload[2*i+1] = byte(hiddenWords[i] & 0xFF)
	}
	netCfg := GatedFabricConfig{Dims: Dims{Layers: 1, Bx: 4, By: 4}, Seed: 1, Groups: 1}
	fab, err := BuildGatedFabricProgram(map[int][]int{0: {asicTop1}}, payload, netCfg)
	if err != nil {
		t.Fatal(err)
	}
	sr, ok := RunGatedFabric(fab, netCfg)
	if !ok || !sr.Pass {
		t.Fatalf("fabric dispatch failed (ok=%v pass=%v): %v", ok, sr.Pass, sr.Errors)
	}

	// ---- 3. COMPUTE NODE runs the expert over the delivered vector --------
	guRaw := g.m.tensorBytes("model.language_model.layers.0.experts.gate_up_proj")
	dwRaw := g.m.tensorBytes("model.language_model.layers.0.experts.down_proj")
	if guRaw == nil || dwRaw == nil {
		t.Fatal("layer-0 expert tensors missing")
	}
	node, err := newNodeClient(NodeConfig{
		RunDir: t.TempDir(), Layer: compLayer, Expert: asicTop1,
		EffFull: effFull, HiddenDim: H, GU: compGU, N: compN, EFF: compEFF,
		CU: 0, Width: 16,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer node.Close()
	if err := node.BuildWeightHex(guRaw, dwRaw); err != nil {
		t.Fatal(err)
	}
	if err := node.Start(); err != nil {
		t.Fatal(err)
	}
	// feed the real first compN words of the scaled embedding
	got, err := node.Expert(embedRow[:compN])
	if err != nil {
		t.Fatal(err)
	}

	// ---- twin: exact BF16 expert pass over the same hidden words ----------
	gu, dw := expertB16Slice(guRaw, dwRaw, asicTop1, effFull, H, compGU, compN, compEFF)
	want := expertTwin(gu, dw, hiddenWords)
	for i := range got {
		if got[i] != want[i] {
			t.Fatalf("node.out[%d] = %04x, twin %04x (expert %d) — composition broken",
				i, got[i], want[i], asicTop1)
		}
	}
	t.Logf("composed gating(asic top-1=%d) -> fabric(%d flits, PASS) -> node: %d/16 words bit-exact vs BF16 twin",
		asicTop1, fab.PlannedDFlits, len(got))

	// ---- 4. COMPUTE NODE in BitNet b1.58 mode (CU_TYPE 8) -----------------
	// The same gating decision and the same delivered hidden vector feed a
	// ternary node: weights are quantized per-row to {-1,0,+1} codes, the
	// hidden stream is INT8, and the select-add datapath must match the
	// integer twin bit-exactly.
	tNode, err := newNodeClient(NodeConfig{
		RunDir: t.TempDir(), Layer: compLayer, Expert: asicTop1,
		EffFull: effFull, HiddenDim: H, GU: compGU, N: compN, EFF: compEFF,
		CU: 8, Width: 8,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer tNode.Close()
	guC, dwC, err := tNode.BuildWeightHexTernary(guRaw, dwRaw)
	if err != nil {
		t.Fatal(err)
	}
	if err := tNode.Start(); err != nil {
		t.Fatal(err)
	}
	hq := ternaryQuantizeHidden(embedRow[:compN])
	tGot, err := tNode.ExpertInt8(hq)
	if err != nil {
		t.Fatal(err)
	}
	tWant := nodeTernaryTwin(guC[:compEFF], dwC, hq)
	for i := range tGot {
		if tGot[i] != tWant[i] {
			t.Fatalf("ternary node.out[%d] = %04x, twin %04x (expert %d) — composition broken",
				i, tGot[i], tWant[i], asicTop1)
		}
	}
	t.Logf("composed ternary node (CU_TYPE 8, expert %d): %d/%d words bit-exact vs select-add twin",
		asicTop1, len(tGot), len(tGot))
}

// softmaxTopK returns the top-k expert indices by softmax probability over
// logits (engine procedure: exp softmax on the raw logits).
func softmaxTopK(logits []float32, k int) []int {
	probs := softmaxProbs(logits)
	order := make([]int, len(probs))
	for i := range order {
		order[i] = i
	}
	sort.SliceStable(order, func(a, b int) bool { return probs[order[a]] > probs[order[b]] })
	out := make([]int, k)
	copy(out, order[:k])
	return out
}

// softmaxTopKAtWidth computes router logits over the first `width` hidden
// dimensions (f32 accumulate, HF stores the Linear out in bf16), then the
// top-k by softmax.
func softmaxTopKAtWidth(w [][]float32, ri []float32, width, k, numExp int) []int {
	logits := make([]float32, numExp)
	for e := 0; e < numExp; e++ {
		var acc float32
		for cc := 0; cc < width && cc < len(ri); cc++ {
			acc += w[e][cc] * ri[cc]
		}
		logits[e] = roundBF16(acc)
	}
	return softmaxTopK(logits, k)
}

func softmaxProbs(logits []float32) []float32 {
	var mx float32 = -1e30
	for _, v := range logits {
		if v > mx {
			mx = v
		}
	}
	probs := make([]float32, len(logits))
	var z float32
	for i, v := range logits {
		probs[i] = float32(math.Exp(float64(v - mx)))
		z += probs[i]
	}
	if z > 0 {
		for i := range probs {
			probs[i] /= z
		}
	}
	return probs
}

func contains(xs []int, v int) bool {
	for _, x := range xs {
		if x == v {
			return true
		}
	}
	return false
}
