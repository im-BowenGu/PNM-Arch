package pnm

import (
	"os"
	"path/filepath"
	"sort"
	"testing"
)

// newTestDriver builds a Driver for the synthetic Gemma-4 test model.
func newTestDriver(t *testing.T, dims Dims) *Driver {
	t.Helper()
	modelDir := filepath.Join(SimDir(), "examples", "gemma4_test")
	if _, err := os.Stat(filepath.Join(modelDir, "config.json")); err != nil {
		t.Skip("gemma4_test model not found")
	}
	drv, err := NewDriver(DriverConfig{ModelDir: modelDir, Dims: dims})
	if err != nil {
		t.Fatalf("NewDriver: %v", err)
	}
	return drv
}

// bootFirmware runs the full boot sequence and returns a ready firmware.
func bootFirmware(t *testing.T, drv *Driver) *Firmware {
	t.Helper()
	fw := drv.FW
	for i := 0; i < 5; i++ {
		if _, err := fw.BootPhase(); err != nil {
			t.Fatalf("boot phase %d: %v", i, err)
		}
	}
	if fw.State != FWStateReady {
		t.Fatalf("expected FWStateReady, got %d", fw.State)
	}
	return fw
}

// TestMoEDispatchReachesFullExpertPopulation guards against the MoE dispatch
// loop always targeting experts 0..TopKExperts-1.  With 128 experts and
// top-k=8, gating must route tokens across the whole expert population, so
// across a diverse set of tokens the set of dispatched global experts must not
// be confined to {0..7}.
func TestMoEDispatchReachesFullExpertPopulation(t *testing.T) {
	drv := newTestDriver(t, Dims{Layers: 4, Bx: 4, By: 4})
	fw := bootFirmware(t, drv)
	tc := &drv.Config.TextConfig
	if tc.NumExperts < 2*tc.TopKExperts {
		t.Skip("model too small for this test")
	}

	dispatched := map[int]bool{}
	for tok := 0; tok < 64; tok++ {
		// Distinct token bytes so gating scores differ across tokens.
		token := []byte{byte(tok), byte(tok >> 8)}
		records, err := fw.PlanInference(token)
		if err != nil {
			t.Fatalf("PlanInference: %v", err)
		}
		for _, r := range records {
			if r.Phase != "moe" || r.ExpertIdx < 0 {
				continue
			}
			dispatched[r.ExpertIdx] = true
		}
	}

	// At least one expert beyond 0..TopKExperts-1 must have been dispatched:
	// otherwise gating is broken and 120 of 128 experts are unreachable.
	if len(dispatched) <= tc.TopKExperts {
		t.Errorf("MoE dispatch confined to %d experts (all within 0..%d); gating should reach the full population",
			len(dispatched), tc.TopKExperts-1)
	}
}

// TestSlidingWindowPerModelLayer guards against full-attention model layers
// being mislabeled as sliding window because of physical-layer collapsing.
// gemma4 has "full_attention" at model indices 5, 11, 17, 23, 29; those must
// produce WindowStart == -1 regardless of the physical layer they land in.
func TestSlidingWindowPerModelLayer(t *testing.T) {
	drv := newTestDriver(t, Dims{Layers: 4, Bx: 4, By: 4})
	fw := bootFirmware(t, drv)
	tc := &drv.Config.TextConfig

	fullLayers := map[int]bool{}
	for ml, lt := range tc.LayerTypes {
		if lt == "full_attention" {
			fullLayers[ml] = true
		}
	}
	if len(fullLayers) == 0 {
		t.Skip("model has no full_attention layers")
	}

	token := []byte{0xAA, 0xBB}
	records, err := fw.PlanInference(token)
	if err != nil {
		t.Fatalf("PlanInference: %v", err)
	}

	// Map model layer -> window start from the first attention record.
	// The dense path emits Phase "flash_attn" when flash attention is enabled.
	windowStartByLayer := map[int]int{}
	for _, r := range records {
		if r.Phase != "flash_attn" {
			continue
		}
		if _, seen := windowStartByLayer[r.Layer]; !seen {
			windowStartByLayer[r.Layer] = r.WindowStart
		}
	}

	for ml := range fullLayers {
		ws, ok := windowStartByLayer[ml]
		if !ok {
			t.Errorf("no attention dispatch record for model layer %d", ml)
			continue
		}
		if ws != -1 {
			t.Errorf("full_attention model layer %d got WindowStart=%d (want -1); physical-layer collapse is leaking sliding metadata",
				ml, ws)
		}
	}

	// Sanity: some sliding layer actually got a real window so the test is
	// not trivially passing because nothing is marked sliding.
	gotSlidingWindow := false
	for _, r := range records {
		if r.Phase == "flash_attn" && r.WindowStart >= 0 {
			gotSlidingWindow = true
			break
		}
	}
	if !gotSlidingWindow {
		t.Error("no sliding layer produced a real window; test may be vacuous")
	}
}

// TestSpeculativeSeqPositions guards against the speculative-decoding path
// advancing SeqPositions more times than there are accepted tokens.
//
// Historically the draft phase advanced every model layer once per drafted
// token, then the verify phase advanced every model layer once per drafted
// token again, and on a mismatch the extra (rejected-token) advances were
// never unwound -- so positions overshot by len(drafted)-len(accepted).
func TestSpeculativeSeqPositions(t *testing.T) {
	drv := newTestDriver(t, Dims{Layers: 4, Bx: 4, By: 4})
	fw := bootFirmware(t, drv)
	if fw.Speculative.DraftTokens <= 0 {
		fw.Speculative.DraftTokens = 3
	}

	// Establish a baseline: a committed PlanInference populates SeqPositions
	// for every model layer, so the speculative tests below are not vacuous.
	if _, err := fw.PlanInference([]byte{0x11, 0x22}); err != nil {
		t.Fatalf("baseline PlanInference: %v", err)
	}
	// Snapshot positions after the baseline inference.
	pre := map[int]int{}
	for k, v := range fw.SeqPositions {
		pre[k] = v
	}
	if len(pre) == 0 {
		t.Fatal("baseline PlanInference produced no SeqPositions")
	}
	// Force a mismatch by driving a draft token that diverges from the main
	// model's prediction (predictDraftToken is deterministic, so pick a
	// prevToken whose next prediction will not be accepted across all drafts).
	prev := 12345
	_, accepted, err := fw.PlanInferenceSpeculative(prev)
	if err != nil {
		t.Fatalf("PlanInferenceSpeculative: %v", err)
	}
	if len(accepted) == 0 {
		t.Fatal("expected at least one accepted token (the main-model fallback)")
	}

	// Each model layer must be at exactly pre[ml] + len(accepted), neither the
	// pre-draft baseline nor the over-counted len(drafted).
	for ml, old := range pre {
		got, ok := fw.SeqPositions[ml]
		if !ok {
			t.Errorf("layer %d: SeqPositions missing after speculative decode", ml)
			continue
		}
		want := old + len(accepted)
		if got != want {
			t.Errorf("layer %d: SeqPositions=%d, want %d (pre=%d, accepted=%d, drafted=%d)",
				ml, got, want, old, len(accepted), fw.Speculative.DraftTokens)
		}
	}

	// And the map must not contain any new layer keys the draft created.
	for ml := range fw.SeqPositions {
		if _, existed := pre[ml]; !existed {
			t.Errorf("layer %d: SeqPositions key created during speculative decode", ml)
		}
	}
}

// cSelectTopk mirrors the C firmware's select_topk scoring (fw/pnm_fw.c) so we
// can cross-check that the Go firmware picks the same experts for a sparse
// per-layer population.  The C side scores each candidate by its ACTUAL global
// expert index (h ^ experts[e]*K); the Go side must do the same or the two
// twins diverge whenever a layer's candidate set is not exactly 0..N-1.
func cSelectTopk(token []byte, ml int, pop []int, topK int) []int {
	h := uint64(14695981039346656037)
	for _, b := range token {
		h ^= uint64(b)
		h *= 1099511628211
	}
	h ^= uint64(ml) * 0x9E3779B97F4A7C15
	h = (h * 1099511628211) >> 0

	type scored struct {
		score  uint64
		expert int
	}
	scores := make([]scored, len(pop))
	for i, ex := range pop {
		sh := h ^ uint64(ex)*0x2545F4914F6CDD1D
		sh ^= sh >> 33
		sh *= 0xFF51AFD7ED558CCD
		sh ^= sh >> 33
		scores[i] = scored{score: sh, expert: ex}
	}
	sort.SliceStable(scores, func(i, j int) bool {
		if scores[i].score != scores[j].score {
			return scores[i].score > scores[j].score
		}
		return scores[i].expert < scores[j].expert
	})
	if topK > len(scores) {
		topK = len(scores)
	}
	out := make([]int, topK)
	for i := 0; i < topK; i++ {
		out[i] = scores[i].expert
	}
	return out
}

// TestSelectTopExpertsSparsePopulation guards against the Go gating scoring by
// loop index instead of global expert index.  Each layer's candidate population
// is stored in the MoE map keyed by its actual global index; for sparse
// populations (e.g. {10,20,30}) the old loop-index scoring picked the wrong
// experts and diverged from the C firmware.
func TestSelectTopExpertsSparsePopulation(t *testing.T) {
	token := []byte("sparse-token")
	ml := 3

	cases := []struct {
		name string
		pop  []int
	}{
		{"sparse", []int{10, 20, 30}},
		{"shifted", []int{100, 101, 102, 103}},
		{"gap", []int{7, 42}},
		{"contiguous", []int{0, 1, 2, 3}},
		{"single", []int{99}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			topK := len(tc.pop)
			got := selectTopExperts(token, ml, tc.pop, topK)
			want := cSelectTopk(token, ml, tc.pop, topK)
			if len(got) != len(want) {
				t.Fatalf("selectTopExperts(%d experts) returned %d results, want %d",
					len(tc.pop), len(got), len(want))
			}
			for i := range want {
				if got[i] != want[i] {
					t.Errorf("rank %d: got expert %d, C mirror wants %d (population %v)",
						i, got[i], want[i], tc.pop)
				}
			}
		})
	}

	// Known-good spot check: sparse {10,20,30} with this token/layer yields
	// [10 30 20] under global-index scoring (verified against the C twin).  If a
	// loop-index regression returns [0 1 2]-style results this fails loudly.
	got := selectTopExperts(token, ml, []int{10, 20, 30}, 3)
	if got[0] != 10 || got[1] != 30 || got[2] != 20 {
		t.Fatalf("sparse {10,20,30} scored by global index: got %v, want [10 30 20]", got)
	}
}


// TestR35SlidingWindowPhysicalMapping guards against ConfigureSlidingWindow
// treating model-layer indices as physical-layer indices.  The historical code
// indexed kc.Layers with the MODEL-layer index (ml) and broke out at
// ml >= len(kc.Layers), so a "full_attention" model layer early in the list
// silently suppressed the sliding flag of the PHYSICAL layer it shares with
// sliding model layers.  Here model layer 1 (physical layer 0, perPhysical=8
// for 30 model layers on 4 physical layers) is full-attention, but physical
// layer 0 also holds sliding model layers 0, 2, 3 (and 4..7), so Layers[0]
// must be marked sliding.
func TestR35SlidingWindowPhysicalMapping(t *testing.T) {
	kc := NewKVCache(Dims{Layers: 4, Bx: 4, By: 4}, 0, nil)
	types := make([]string, 30)
	for i := range types {
		types[i] = "sliding_attention"
	}
	types[1] = "full_attention" // inside physical layer 0
	types[9] = "full_attention" // inside physical layer 1
	kc.ConfigureSlidingWindow(1024, types)
	for pl := 0; pl < len(kc.Layers); pl++ {
		if !kc.Layers[pl].IsSliding {
			t.Errorf("physical layer %d not marked sliding (IsSliding=false); sliding flag was indexed by model layer", pl)
		}
		if kc.Layers[pl].SlidingWindow != 1024 {
			t.Errorf("physical layer %d SlidingWindow=%d (want 1024)", pl, kc.Layers[pl].SlidingWindow)
		}
	}
}

// TestR35LayerIsSlidingFallback covers the Mistral/Gemma-1 style fallback:
// SlidingWindow>0 with no per-model layer_types.  After the firmware guard
// change every physical layer is marked sliding, so layerIsSliding must report
// a real window for every model layer (the historical code left IsSliding
// false and produced WindowStart=-1 on every dispatch record).
func TestR35LayerIsSlidingFallback(t *testing.T) {
	drv := newTestDriver(t, Dims{Layers: 4, Bx: 4, By: 4})
	fw := bootFirmware(t, drv)
	tc := &drv.Config.TextConfig
	if tc.SlidingWindow <= 0 {
		t.Skip("model has no sliding window")
	}
	// Simulate a Mistral-style config: no per-model layer types.
	tc.LayerTypes = nil
	if tc.SlidingWindow > 0 {
		fw.KV.ConfigureSlidingWindow(tc.SlidingWindow, tc.LayerTypes)
	}
	for ml := 0; ml < tc.NumHiddenLayers; ml++ {
		sliding, win := fw.layerIsSliding(ml)
		if !sliding || win != tc.SlidingWindow {
			t.Errorf("model layer %d fallback: sliding=%v win=%d (want true, %d)", ml, sliding, win, tc.SlidingWindow)
		}
	}
}

// TestR35ConfigureSlidingWindowFallback guards the no-layerTypes path: a
// Mistral-style model has SlidingWindow>0 but no per-model layer_types, so
// every physical layer must be marked sliding.  The historical function
// returned with no layers configured for an empty type list.
func TestR35ConfigureSlidingWindowFallback(t *testing.T) {
	kc := NewKVCache(Dims{Layers: 4, Bx: 4, By: 4}, 0, nil)
	kc.ConfigureSlidingWindow(1024, nil)
	for pl := 0; pl < len(kc.Layers); pl++ {
		if !kc.Layers[pl].IsSliding {
			t.Errorf("fallback: physical layer %d not marked sliding", pl)
		}
		if kc.Layers[pl].SlidingWindow != 1024 {
			t.Errorf("fallback: physical layer %d SlidingWindow=%d (want 1024)", pl, kc.Layers[pl].SlidingWindow)
		}
	}
}
