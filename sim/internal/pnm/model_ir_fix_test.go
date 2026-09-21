package pnm

import (
	"path/filepath"
	"testing"
)

// TestR35KVCacheFrameConsistency guards the AOT schema's per-entry KV size
// against the RTL/co-sim frame (kv_cache_bank ENTRY_BYTES=512, the Go
// DefaultKVCacheConfig pin, and the C twin's PNM_KV_ENTRY_BYTES).  The
// historical code used hiddenSize*4 (11264 for gemma4), inflating the
// reserved KV bytes to 184 MB/node instead of the 8 MB the silicon frame
// can actually hold.
func TestR35KVCacheFrameConsistency(t *testing.T) {
	modelDir := filepath.Join(SimDir(), "examples", "gemma4_test_synthetic")
	cfg, err := LoadModelConfig(modelDir)
	if err != nil {
		t.Skipf("gemma4_test_synthetic model config unavailable: %v", err)
	}
	idx, err := LoadSafetensorsIndex(modelDir)
	if err != nil {
		t.Skipf("gemma4_test_synthetic safetensors index unavailable: %v", err)
	}
	ir, err := CompileModelIR(cfg, idx)
	if err != nil {
		t.Fatalf("CompileModelIR: %v", err)
	}
	mc, err := ir.PopulateSchema(Dims{Layers: 4, Bx: 4, By: 4})
	if err != nil {
		t.Fatalf("PopulateSchema: %v", err)
	}

	maxFrame := int64(16384) * 512 // hard cap at RTL frame size
	found := false
	for nid, na := range mc.NodeAssignments {
		for _, tr := range na.Tensors {
			if tr.Role != "kv_cache" {
				continue
			}
			found = true
			if tr.SizeBytes%512 != 0 {
				t.Errorf("node %v: kv_cache SizeBytes=%d not a multiple of the 512-byte RTL frame", nid, tr.SizeBytes)
			}
			if tr.SizeBytes > maxFrame {
				t.Errorf("node %v: kv_cache SizeBytes=%d exceeds the 16K-entry x 512-byte frame cap (%d); entry size was derived from hiddenSize instead of the RTL frame", nid, tr.SizeBytes, maxFrame)
			}
		}
	}
	if !found {
		t.Error("no kv_cache tensor emitted by the schema; test vacuous")
	}
}
