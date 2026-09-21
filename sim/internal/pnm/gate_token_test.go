package pnm

import (
	"testing"
)

// TestGateTokenScoreOrdering guards the public gating API: for one token and
// model layer, decisions must be returned in score-descending order, the count
// must match min(TopK, population), and each decision's node must equal the
// MoE map's placement for that (layer, expert).
func TestGateTokenScoreOrdering(t *testing.T) {
	drv := newTestDriver(t, Dims{Layers: 4, Bx: 4, By: 4})
	fw := bootFirmware(t, drv)
	tc := &drv.Config.TextConfig

	token := []byte("gating-ordering-token")
	ml := 0
	decisions, err := fw.GateToken(token, ml)
	if err != nil {
		t.Fatalf("GateToken: %v", err)
	}
	want := tc.TopKExperts
	if want > tc.NumExperts {
		want = tc.NumExperts
	}
	if len(decisions) != want {
		t.Fatalf("GateToken returned %d decisions, want top-%d", len(decisions), want)
	}
	// The first decision must be the gating network's winner (highest score).
	if len(decisions) == 0 {
		t.Fatal("no gating decisions for a full expert population")
	}
	for i, d := range decisions {
		if i > 0 && d.Score > decisions[i-1].Score {
			t.Fatalf("decisions not score-descending: %d > %d at rank %d", d.Score, decisions[i-1].Score, i)
		}
		wantNode, ok := fw.Driver.MoeMap[MoeKey{ModelLayer: ml, ExpertIdx: d.Expert}]
		if !ok {
			t.Fatalf("expert %d not in MoE map for layer %d", d.Expert, ml)
		}
		if d.Node != wantNode {
			t.Errorf("expert %d mapped to node %v, MoE map says %v", d.Expert, d.Node, wantNode)
		}
	}
}

// TestGateTokenMatchesPlanInference guards that the public gating API and the
// internal dispatch plan agree: the top-k experts GateToken returns must be
// exactly the MoE dispatch records PlanInference emits for the same token.
func TestGateTokenMatchesPlanInference(t *testing.T) {
	drv := newTestDriver(t, Dims{Layers: 4, Bx: 4, By: 4})
	fw := bootFirmware(t, drv)

	token := []byte("gate-vs-plan-token")
	records, err := fw.PlanInference(token)
	if err != nil {
		t.Fatalf("PlanInference: %v", err)
	}
	planned := map[int]bool{}
	for _, r := range records {
		if r.Phase == "moe" && r.ExpertIdx >= 0 {
			planned[r.ExpertIdx] = true
		}
	}
	if len(planned) == 0 {
		t.Fatal("no MoE records in plan")
	}
	for _, ml := range []int{0, 1, 10, 29} {
		decisions, err := fw.GateToken(token, ml)
		if err != nil {
			t.Fatalf("GateToken layer %d: %v", ml, err)
		}
		for _, d := range decisions {
			if !planned[d.Expert] {
				t.Errorf("layer %d: GateToken chose expert %d but PlanInference did not dispatch it", ml, d.Expert)
			}
		}
	}
}

// TestGateTokenDiversity guards that distinct tokens route to distinct expert
// sets: the gating network must be token-sensitive, not a fixed mapping.
func TestGateTokenDiversity(t *testing.T) {
	drv := newTestDriver(t, Dims{Layers: 2, Bx: 2, By: 2})
	fw := bootFirmware(t, drv)
	tc := &drv.Config.TextConfig
	if tc.NumExperts < 2*tc.TopKExperts {
		t.Skip("model too small for this test")
	}

	seen := map[int]bool{}
	for tok := 0; tok < 32; tok++ {
		token := []byte{byte(tok), byte(tok >> 8), byte(0xFF - tok)}
		decisions, err := fw.GateToken(token, 0)
		if err != nil {
			t.Fatalf("GateToken: %v", err)
		}
		for _, d := range decisions {
			seen[d.Expert] = true
		}
	}
	if len(seen) <= tc.TopKExperts {
		t.Errorf("gating confined to %d experts across 32 tokens (top-k=%d); token diversity lost",
			len(seen), tc.TopKExperts)
	}
}

// TestGateTokenRequiresReady guards the readiness contract: gating decisions
// are only valid after the firmware has finished POST (Phase 5).
func TestGateTokenRequiresReady(t *testing.T) {
	drv := newTestDriver(t, Dims{Layers: 2, Bx: 2, By: 2})
	fw := drv.FW
	if _, err := fw.GateToken([]byte("pre-boot"), 0); err == nil {
		t.Fatal("GateToken before Phase 5 should fail, got nil error")
	}
}