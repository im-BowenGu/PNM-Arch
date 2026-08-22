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
	// Node (0,0,0): layer=0+1=1, bits=1<<7=0x080, axis=1<<6=0x040, dist=0 → 0x0C0
	if bm, ok := drv.RouteBitmaps[NodeID{L: 0, X: 0, Y: 0}]; !ok {
		t.Error("missing bitmap for (0,0,0)")
	} else if bm != 0x0C0 {
		t.Errorf("(0,0,0): expected 0x0C0, got 0x%03x", bm)
	}

	// Node (0,0,3): layer=1, axis=Y, dist=3 → 0x0C3
	if bm, ok := drv.RouteBitmaps[NodeID{L: 0, X: 0, Y: 3}]; !ok {
		t.Error("missing bitmap for (0,0,3)")
	} else if bm != 0x0C3 {
		t.Errorf("(0,0,3): expected 0x0C3, got 0x%03x", bm)
	}

	// Node (2,1,2): layer=3, axis=Y, dist=2 → 0x1C2
	if bm, ok := drv.RouteBitmaps[NodeID{L: 2, X: 1, Y: 2}]; !ok {
		t.Error("missing bitmap for (2,1,2)")
	} else if bm != 0x1C2 {
		t.Errorf("(2,1,2): expected 0x1C2, got 0x%03x", bm)
	}
}

// TestLLMClient exercises the FP16/BF16 LLM inference client.
func TestLLMClient(t *testing.T) {
	modelDir := filepath.Join(SimDir(), "examples", "gemma4_test")
	if _, err := os.Stat(filepath.Join(modelDir, "config.json")); err != nil {
		t.Skip("gemma4_test model not found")
	}

	dims := Dims{Layers: 4, Bx: 4, By: 4}
	client, err := NewLLMClient(LLMConfig{
		ModelDir:  modelDir,
		Dims:      dims,
		MaxTokens: 10,
		DataType:  CUTypeBF16FMA,
	})
	if err != nil {
		t.Fatalf("NewLLMClient: %v", err)
	}

	// Test vocabulary
	if client.Vocab == nil {
		t.Fatal("vocabulary is nil")
	}

	// Test encode/decode roundtrip
	ids := client.Vocab.Encode("hello world")
	if len(ids) != 2 {
		t.Errorf("expected 2 tokens, got %d", len(ids))
	}
	// Verify encode produces deterministic IDs
	ids2 := client.Vocab.Encode("hello world")
	if ids[0] != ids2[0] || ids[1] != ids2[1] {
		t.Error("encode not deterministic")
	}

	// Test generation
	tokens, err := client.Generate("test prompt")
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	if len(tokens) == 0 {
		t.Error("no tokens generated")
	}
	if len(tokens) > 10 {
		t.Errorf("expected max 10 tokens, got %d", len(tokens))
	}

	// Verify stats
	if client.Stats.PrefillTokens == 0 {
		t.Error("prefill tokens not tracked")
	}
	if client.Stats.TokensGenerated == 0 {
		t.Error("generated tokens not tracked")
	}

	t.Logf("LLM Client: %s", client.Summary())
}

// TestComputeUnitTypes verifies CU type assignment.
func TestComputeUnitTypes(t *testing.T) {
	modelDir := filepath.Join(SimDir(), "examples", "gemma4_test")
	if _, err := os.Stat(filepath.Join(modelDir, "config.json")); err != nil {
		t.Skip("gemma4_test model not found")
	}

	dims := Dims{Layers: 4, Bx: 4, By: 4}
	drv, err := NewDriver(DriverConfig{ModelDir: modelDir, Dims: dims})
	if err != nil {
		t.Fatalf("NewDriver: %v", err)
	}

	// Verify CU type assignment
	cuSummary := drv.MC.ComputeUnitSummary()
	if len(cuSummary) == 0 {
		t.Error("no compute units assigned")
	}

	// Check that BF16 FMA is present (MoE experts)
	if cuSummary[CUTypeBF16FMA] == 0 {
		t.Error("expected BF16 FMA units for MoE experts")
	}

	// Check that BF16 array is present (attention)
	if cuSummary[CUTypeBF16Array] == 0 {
		t.Error("expected BF16 array units for attention")
	}

	// Check that FP32 ALU is present (layernorm)
	if cuSummary[CUTypeFP32ALU] == 0 {
		t.Error("expected FP32 ALU units for layernorm")
	}

	// Verify CU type metadata
	if CUTypeBF16FMA.DTypeBytes() != 2 {
		t.Error("BF16 FMA should be 2 bytes")
	}
	if CUTypeFP32FMA.DTypeBytes() != 4 {
		t.Error("FP32 FMA should be 4 bytes")
	}
	if CUTypeFP64FMA.DTypeBytes() != 8 {
		t.Error("FP64 FMA should be 8 bytes")
	}
	if CUTypeINT8MAC.DTypeBytes() != 1 {
		t.Error("INT8 MAC should be 1 byte")
	}

	// Verify weight commands have CU types (use smaller dims for speed)
	smallDims := Dims{Layers: 2, Bx: 2, By: 2}
	smallDrv, err := NewDriver(DriverConfig{ModelDir: modelDir, Dims: smallDims})
	if err != nil {
		t.Fatalf("NewDriver (small): %v", err)
	}
	cmds, err := smallDrv.BuildWeightCommands()
	if err != nil {
		t.Fatalf("BuildWeightCommands: %v", err)
	}
	if len(cmds) == 0 {
		t.Fatal("no weight commands")
	}
	hasBF16 := false
	for _, cmd := range cmds {
		if cmd.CUType == CUTypeBF16FMA {
			hasBF16 = true
			break
		}
	}
	if !hasBF16 {
		t.Error("expected BF16 FMA weight commands")
	}
}
