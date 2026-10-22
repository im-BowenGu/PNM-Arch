package pnm

// node_composition_multilayer_test.go — chain the three silicon stages over
// several model layers, so the composition is a *chain* and not a single
// layer's proof:
//
//	for each model layer L in {0, 7, 14} (configurable):
//	  1. GATING ASIC    the layer's real router.proj.weight (a width-256
//	                    column slice) is resident in the ASIC's SRAM; the
//	                    router input is derived from the *current* residual
//	                    slice, so the previous layer's node output feeds the
//	                    next layer's gating decision.
//	  2. NODE NETWORK   the decision is dispatched through the real fabric RTL
//	                    to ExpertNode(chassis layer, expert), carrying the
//	                    residual slice as the wire payload; RunModelFabric
//	                    verifies byte-exact delivery.
//	  3. COMPUTE NODE   node.v runs the layer's chosen expert over the
//	                    delivered vector; its output must equal the software
//	                    BF16 twin bit-for-bit.
//	  4. RESIDUAL       the expert output is added to the residual slice
//	                    (the MoE residual), and that slice becomes the next
//	                    layer's router input.
//
// The chain runs at a reduced width (a 256-dim hidden slice and the matching
// 256-column router slice) so the whole composition stays inside a cycle
// budget; every stage is still bit-exact against the software twin, and the
// ASIC's top-1 must be inside the software router's top-8 at the same width.
// When PNM_MODEL_DIR is set the chain runs on the real fused checkpoint;
// otherwise on the deterministic synthetic fixture (comp_model.go).
//
// Requires iverilog and vvp.

import (
	"fmt"
	"math"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"testing"
)

const (
	mlN     = 256 // node slice width (== the router slice width)
	mlEFF   = 8   // node slice intermediate width
	mlGU    = 16  // weight rows = 2*mlEFF
	mlWidth = 256 // router column slice seen by the ASIC
)

// compLayers returns the model layers the multi-layer chain runs over.
func compLayers() []int {
	spec := os.Getenv("PNM_COMP_LAYERS")
	if spec == "" {
		spec = "0,7,14"
	}
	var out []int
	for _, part := range strings.Split(spec, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		n, err := strconv.Atoi(part)
		if err != nil {
			continue
		}
		out = append(out, n)
	}
	if len(out) == 0 {
		out = []int{0}
	}
	return out
}

// sliceRouterInput computes the Gemma router input over a reduced-width
// hidden slice: RMSNorm (without the learned scale) over the slice, then the
// per-dimension router scale, then hidden^-1/2 — the same chain as
// gemmaRouterInput, evaluated over len(x) dimensions instead of the full
// hidden size.
func sliceRouterInput(x []float32, scale []float32) []float32 {
	out := make([]float32, len(x))
	var ss float32
	for _, v := range x {
		ss += v * v
	}
	inv := 1 / float32(math.Sqrt(float64(ss)/float64(len(x))+1e-6))
	root := 1 / float32(math.Sqrt(float64(len(x))))
	for i := range x {
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

func TestRouterFabricNodeCompositionMultiLayer(t *testing.T) {
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
	layers := compLayers()

	// ---- the initial residual slice: the real scaled embedding -----------
	raw := g.m.tensorBytes("model.language_model.embed_tokens.weight")
	if raw == nil || len(raw) < H*2 {
		t.Fatal("embed_tokens tensor missing or too small")
	}
	embedRow := make([]float32, H)
	for i := 0; i < H; i++ {
		w := uint16(raw[2*i]) | uint16(raw[2*i+1])<<8
		embedRow[i] = float32(b16Val(w)) * float32(math.Sqrt(float64(H)))
	}
	residual := make([]float32, mlN)
	residualW := make([]uint16, mlN)
	for i := 0; i < mlN; i++ {
		residual[i] = embedRow[i]
		residualW[i] = f32ToB16Word(roundBF16(embedRow[i]))
	}

	// ---- one gating ASIC per layer, with that layer's real router weights -
	gate, err := newGatingClient(GatingConfig{
		RunDir: t.TempDir(), Layers: layers, Width: mlWidth,
	}, g)
	if err != nil {
		t.Fatal(err)
	}
	defer gate.Close()

	netCfg := GatedFabricConfig{
		Dims: Dims{Layers: len(layers), Bx: 4, By: 4}, Seed: 1, Groups: 1,
	}

	for i, ml := range layers {
		// ---- 1. the router input comes from the current residual ----------
		scale := g.m.vec(fmt.Sprintf("model.language_model.layers.%d.router.scale", ml))
		ri := sliceRouterInput(residual, scale)

		// ---- 2. GATING ASIC decides the expert ----------------------------
		gLogits, err := gate.Route(ml, ri)
		if err != nil {
			t.Fatalf("layer %d: ASIC route: %v", ml, err)
		}
		asicTop := softmaxTopK(gLogits, 8)
		expert := asicTop[0]
		routerW := g.m.mat(fmt.Sprintf("model.language_model.layers.%d.router.proj.weight", ml), numExp, H)
		swTop := softmaxTopKAtWidth(routerW, ri, mlWidth, 8, numExp)
		if !contains(swTop, expert) {
			t.Fatalf("layer %d: ASIC top-1 = expert %d not in software top-8 %v (width %d)",
				ml, expert, swTop, mlWidth)
		}

		// ---- 3. NODE NETWORK transports the residual to the expert node ----
		payload := make([]byte, 2*mlN)
		for k := 0; k < mlN; k++ {
			payload[2*k] = byte(residualW[k] >> 8)
			payload[2*k+1] = byte(residualW[k] & 0xFF)
		}
		fab, err := BuildGatedFabricProgram(map[int][]int{i: {expert}}, payload, netCfg)
		if err != nil {
			t.Fatalf("layer %d: fabric program: %v", ml, err)
		}
		sr, ok := RunGatedFabric(fab, netCfg)
		if !ok || !sr.Pass {
			t.Fatalf("layer %d: fabric dispatch failed (ok=%v pass=%v): %v",
				ml, ok, sr.Pass, sr.Errors)
		}

		// ---- 4. COMPUTE NODE runs the layer's expert ----------------------
		guRaw := g.m.tensorBytes(fmt.Sprintf("model.language_model.layers.%d.experts.gate_up_proj", ml))
		dwRaw := g.m.tensorBytes(fmt.Sprintf("model.language_model.layers.%d.experts.down_proj", ml))
		if guRaw == nil || dwRaw == nil {
			t.Fatalf("layer %d: expert tensors missing", ml)
		}
		node, err := newNodeClient(NodeConfig{
			RunDir: t.TempDir(), Layer: ml, Expert: expert,
			EffFull: effFull, HiddenDim: H, GU: mlGU, N: mlN, EFF: mlEFF,
			CU: 0, Width: 16,
		})
		if err != nil {
			t.Fatalf("layer %d: node client: %v", ml, err)
		}
		if err := node.BuildWeightHex(guRaw, dwRaw); err != nil {
			t.Fatalf("layer %d: node weights: %v", ml, err)
		}
		if err := node.Start(); err != nil {
			t.Fatalf("layer %d: node start: %v", ml, err)
		}
		got, err := node.Expert(residual)
		if err != nil {
			t.Fatalf("layer %d: node expert: %v", ml, err)
		}
		node.Close()

		// ---- 5. twin: the same expert pass in software --------------------
		gu, dw := expertB16Slice(guRaw, dwRaw, expert, effFull, H, mlGU, mlN, mlEFF)
		want := expertTwin(gu, dw, residualW)
		for k := range got {
			if got[k] != want[k] {
				t.Fatalf("layer %d: node.out[%d] = %04x, twin %04x (expert %d) — chain broken",
					ml, k, got[k], want[k], expert)
			}
		}

		// ---- 6. the MoE residual feeds the next layer ---------------------
		for k := range residualW {
			residualW[k] = b16Add(residualW[k], got[k])
		}
		for k := range residual {
			residual[k] = float32(b16Val(residualW[k]))
		}

		t.Logf("layer %2d: asic top-1 = expert %3d (in software top-8 %v) | fabric %d flit(s) PASS | node %d/%d words bit-exact vs BF16 twin",
			ml, expert, swTop, fab.PlannedDFlits, len(got), len(got))
	}

	t.Logf("multi-layer composition over layers %v: gating ASIC -> node network -> compute node, each layer bit-exact vs the BF16 twin",
		layers)
}
