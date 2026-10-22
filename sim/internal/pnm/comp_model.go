package pnm

// comp_model.go — the composition tests' model fixture.
//
// The gating -> fabric -> node composition (node_composition_test.go and
// node_composition_multilayer_test.go) used to require the 49 GB real
// checkpoint (PNM_MODEL_DIR), so the paper's §2.20 chain was skipped by the
// always-on suite.  loadCompositionModel returns the real checkpoint when it
// is present, and a deterministic synthetic Gemma-4-shaped fixture otherwise
// — the chain itself is identical either way, only the stimulus differs, so
// the machine check runs everywhere.
//
// The synthetic shape is a scaled-down Gemma-4 (512 hidden, 32 experts,
// 64-wide MoE intermediate) with the same fused tensor layouts the real
// path slices: gate_up rows = numExps*2*effFull x hidden, down rows =
// numExps*hidden x effFull, router proj = numExps x hidden.

import (
	"encoding/binary"
	"fmt"
	"os"
	"testing"
)

const (
	synHidden = 512 // synthetic hidden size
	synExps   = 32  // synthetic expert count
	synEff    = 64  // synthetic MoE intermediate width
	synLayers = 16  // synthetic model layer count (0,7,14 are gated layers)
)

// loadCompositionModel returns the model the composition chain runs on:
// the real fused checkpoint when PNM_MODEL_DIR points at one, else the
// deterministic synthetic fixture.
func loadCompositionModel(t *testing.T) *gemmaModel {
	t.Helper()
	if modelDir := os.Getenv("PNM_MODEL_DIR"); modelDir != "" {
		vocab, err := LoadBPEVocab(modelDir + "/tokenizer.json")
		if err != nil {
			t.Skipf("no tokenizer (needs the real checkpoint): %v", err)
		}
		g, err := loadRealGemmaModel(modelDir, vocab)
		if err != nil {
			t.Fatal(err)
		}
		return g
	}
	return syntheticCompositionModel()
}

// syntheticCompositionModel builds a Gemma-4-shaped model whose tensors are
// deterministic BF16 noise, sized so the whole fixture is a few megabytes
// instead of the checkpoint's gigabytes.
func syntheticCompositionModel() *gemmaModel {
	cfg := &ModelConfig{}
	cfg.TextConfig.HiddenSize = synHidden
	cfg.TextConfig.NumExperts = synExps
	cfg.TextConfig.MoEIntermediateSize = synEff
	cfg.TextConfig.TopKExperts = 8
	cfg.TextConfig.NumHiddenLayers = synLayers

	rm := &realModel{desc: nil, cache: map[string][]byte{}}
	rm.cache["model.language_model.embed_tokens.weight"] = synTensor(1, synHidden)
	for _, ml := range []int{0, 7, 14} {
		p := fmt.Sprintf("model.language_model.layers.%d.", ml)
		base := uint64(ml+1) * 101
		rm.cache[p+"router.scale"] = synTensor(base+1, synHidden)
		rm.cache[p+"router.proj.weight"] = synTensor(base+2, synExps*synHidden)
		rm.cache[p+"experts.gate_up_proj"] = synTensor(base+3, synExps*2*synEff*synHidden)
		rm.cache[p+"experts.down_proj"] = synTensor(base+4, synExps*synHidden*synEff)
	}
	return &gemmaModel{m: rm, cfg: cfg, hidden: synHidden}
}

// synTensor generates n deterministic BF16 words: class-1 normals with the
// exponent in [-16, -4] — small enough that the multi-layer residual chain
// stays inside the well-validated BF16 regime (the RTL reference tests use
// [-8, 8] for single passes; a chained composition accumulates, so the
// fixture is two orders of magnitude quieter, matching real checkpoint
// statistics where embeddings and expert weights are O(0.01)), and always
// normal, so the exact float64 oracle and the RTL datapath stay
// bit-comparable — no subnormals, no inf/nan on either side.
func synTensor(seed uint64, n int) []byte {
	r := NewPyRand(seed)
	b := make([]byte, 2*n)
	for i := 0; i < n; i++ {
		var u uint16
		for {
			u = uint16(r.getrandbits(16))
			if b16Class(u) == 1 {
				e := int((u>>7)&0xFF) - 127
				if e >= -16 && e <= -4 {
					break
				}
			}
		}
		binary.LittleEndian.PutUint16(b[2*i:], u)
	}
	return b
}
