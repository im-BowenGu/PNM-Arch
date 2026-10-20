package pnm

import (
	"fmt"
	"os"
	"testing"
)

// TestHarnessChatIDs prints the engine chat template ids for PNM_PROMPT so they
// can be diffed against HF's apply_chat_template(enable_thinking=True) ids.
func TestHarnessChatIDs(t *testing.T) {
	if os.Getenv("PNM_REAL_TESTS") == "" {
		t.Skip("set PNM_REAL_TESTS=1 to run the real-weight harness")
	}
	prompt := os.Getenv("PNM_PROMPT")
	if prompt == "" {
		prompt = "What is the capital of Germany"
	}
	modelDir := "/data/gemma4_dl/complete"
	if v := os.Getenv("PNM_MODEL"); v != "" {
		modelDir = v
	}
	vocab, err := LoadBPEVocab(modelDir + "/tokenizer.json")
	if err != nil {
		t.Fatalf("vocab: %v", err)
	}
	ids, err := chatIDs(vocab, prompt, false)
	if err != nil {
		t.Fatalf("chatIDs: %v", err)
	}
	full := append([]int{vocab.BosID}, ids...)
	fmt.Printf("IDS: %v\n", full)
}
