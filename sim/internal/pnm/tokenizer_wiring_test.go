package pnm

import (
	"encoding/binary"
	"path/filepath"
	"testing"
)

// TestRealBPEInHostSDK verifies the real Gemma BPE tokenizer flows through
// the host SDK vocabulary and the model-fabric prompt payloads when the
// model directory carries tokenizer.json.
func TestRealBPEInHostSDK(t *testing.T) {
	dir := "/data/gemma4_dl/complete"
	tokPath := filepath.Join(dir, "tokenizer.json")
	bpe, err := LoadBPEVocab(tokPath)
	if err != nil {
		t.Skipf("no real tokenizer: %v", err)
	}
	tokens := make([]string, bpe.VocabSize())
	v := NewVocabulary(tokens, bpe)
	ids := v.Encode("Who was Alan Turing?")
	if len(ids) != 5 {
		t.Fatalf("expected 5 tokens, got %v", ids)
	}
	if ids[0] != 15938 || ids[3] != 63809 {
		t.Fatalf("real BPE ids wrong: %v", ids)
	}
	back := v.Decode(ids)
	if back != "Who was Alan Turing?" {
		t.Fatalf("decode mismatch: %q", back)
	}
	t.Logf("host SDK BPE round-trip OK: %v -> %q", ids, back)
}

// TestRealBPEInFabricPayloads verifies the fabric prompt payloads carry the
// real BPE token stream when the driver has a tokenizer.json.
func TestRealBPEInFabricPayloads(t *testing.T) {
	drv, err := NewDriver(DriverConfig{ModelDir: "/data/gemma4_dl/complete", Dims: Dims{Layers: 2, Bx: 2, By: 2}})
	if err != nil {
		t.Skipf("no model: %v", err)
	}
	payloads := PromptTokenPayloads(drv, "Who was Alan Turing?", 1)
	if payloads == nil {
		t.Fatal("nil payloads")
	}
	first := int(binary.BigEndian.Uint16(payloads[0][0:2]))
	if first != 15938 { // "Who"
		t.Fatalf("payload first token %d != 15938 (real BPE Who)", first)
	}
	tb, err := LoadBPEVocab(filepath.Join(drv.ModelDir, "tokenizer.json"))
	if err != nil {
		t.Skip(err)
	}
	var toks []string
	for w := 0; w < 16; w++ {
		id := int(binary.BigEndian.Uint16(payloads[0][w*2:]))
		if id != 0 {
			toks = append(toks, tb.IDToToken[id])
		}
	}
	if len(toks) < 4 {
		t.Fatalf("payload decode too short: %v", toks)
	}
	t.Logf("fabric payload tokens: %q", toks[:4])
}