package pnm

import (
	"os"
	"path/filepath"
	"testing"
)

// TestDriverFirmware exercises the full driver + firmware pipeline on the
// synthetic Gemma-4 test model.
func TestDriverFirmware(t *testing.T) {
	modelDir := filepath.Join(SimDir(), "examples", "gemma4_test")
	if _, err := os.Stat(filepath.Join(modelDir, "config.json")); err != nil {
		t.Skip("gemma4_test model not found")
	}

	dims := Dims{Layers: 4, Bx: 4, By: 4}
	drv, err := NewDriver(DriverConfig{ModelDir: modelDir, Dims: dims})
	if err != nil {
		t.Fatalf("NewDriver: %v", err)
	}

	tc := &drv.Config.TextConfig
	if tc.NumHiddenLayers != 30 {
		t.Errorf("expected 30 layers, got %d", tc.NumHiddenLayers)
	}
	if tc.NumExperts != 128 {
		t.Errorf("expected 128 experts, got %d", tc.NumExperts)
	}

	// Verify routing tables
	if len(drv.RouteBitmaps) != dims.Layers*dims.Bx*dims.By {
		t.Errorf("routing table: expected %d entries, got %d",
			dims.Layers*dims.Bx*dims.By, len(drv.RouteBitmaps))
	}

	// Verify MoE map
	// MoE map only has entries for experts that exist in the compiled model
	if len(drv.MoeMap) == 0 {
		t.Error("MoE map is empty")
	}

	// Boot sequence
	fw := drv.FW

	// Phase 1: POST Discovery
	if _, err := fw.BootPhase(); err != nil {
		t.Fatalf("POST discovery: %v", err)
	}
	if fw.NodeCount != dims.Layers*dims.Bx*dims.By {
		t.Errorf("POST: expected %d nodes, got %d",
			dims.Layers*dims.Bx*dims.By, fw.NodeCount)
	}

	// Phase 2: Routing Table
	if _, err := fw.BootPhase(); err != nil {
		t.Fatalf("routing table: %v", err)
	}

	// Phase 3: Weight Upload
	cmds, err := fw.BootPhase()
	if err != nil {
		t.Fatalf("weight upload: %v", err)
	}
	if len(cmds) == 0 {
		t.Fatal("weight upload: no commands generated")
	}

	// Verify weight upload
	if err := fw.VerifyWeightUpload(cmds); err != nil {
		t.Errorf("weight verification: %v", err)
	}

	// Phase 4: MoE Load
	if _, err := fw.BootPhase(); err != nil {
		t.Fatalf("MoE load: %v", err)
	}

	// Phase 5: Ready
	if _, err := fw.BootPhase(); err != nil {
		t.Fatalf("ready: %v", err)
	}

	// Inference dispatch
	token := make([]byte, 32)
	for i := range token {
		token[i] = byte(i)
	}
	records, err := fw.PlanInference(token)
	if err != nil {
		t.Fatalf("inference plan: %v", err)
	}

	// Verify dispatch
	if err := fw.VerifyDispatch(records); err != nil {
		t.Errorf("dispatch verification: %v", err)
	}

	// Check dispatch counts: 30 dense + 30*8 MoE = 270
	denseCount := 0
	moeCount := 0
	for _, r := range records {
		if r.Phase == "dense" {
			denseCount++
		} else {
			moeCount++
		}
	}
	if denseCount != tc.NumHiddenLayers {
		t.Errorf("expected %d dense dispatches, got %d", tc.NumHiddenLayers, denseCount)
	}
	if moeCount != tc.NumHiddenLayers*tc.TopKExperts {
		t.Errorf("expected %d MoE dispatches, got %d",
			tc.NumHiddenLayers*tc.TopKExperts, moeCount)
	}
}

// TestRouterBitmaps verifies the routing bitmap computation.
func TestRouterBitmaps(t *testing.T) {
	modelDir := filepath.Join(SimDir(), "examples", "gemma4_test")
	if _, err := os.Stat(filepath.Join(modelDir, "config.json")); err != nil {
		t.Skip("gemma4_test model not found")
	}

	dims := Dims{Layers: 4, Bx: 4, By: 4}
	drv, err := NewDriver(DriverConfig{ModelDir: modelDir, Dims: dims})
	if err != nil {
		t.Fatalf("NewDriver: %v", err)
	}

	// Check a few known bitmaps
	// Node (0,0,0): layer=0+1=1, bits=1<<7=0x080, dist=0 → 0x080
	if bm, ok := drv.RouteBitmaps[NodeID{L: 0, X: 0, Y: 0}]; !ok {
		t.Error("missing bitmap for (0,0,0)")
	} else if bm != 0x080 {
		t.Errorf("(0,0,0): expected 0x080, got 0x%03x", bm)
	}

	// Node (0,0,3): layer=1, dist=3 → 0x083
	if bm, ok := drv.RouteBitmaps[NodeID{L: 0, X: 0, Y: 3}]; !ok {
		t.Error("missing bitmap for (0,0,3)")
	} else if bm != 0x083 {
		t.Errorf("(0,0,3): expected 0x083, got 0x%03x", bm)
	}

	// Node (2,1,2): layer=3, dist=2 → 0x182
	if bm, ok := drv.RouteBitmaps[NodeID{L: 2, X: 1, Y: 2}]; !ok {
		t.Error("missing bitmap for (2,1,2)")
	} else if bm != 0x182 {
		t.Errorf("(2,1,2): expected 0x182, got 0x%03x", bm)
	}
}
