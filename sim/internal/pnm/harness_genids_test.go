package pnm

import (
	"fmt"
	"math"
	"os"
	"testing"
)

func TestHarnessGenIds(t *testing.T) {
	if os.Getenv("PNM_REAL_TESTS") == "" {
		t.Skip("set PNM_REAL_TESTS=1 to run the real-weight harness")
	}
	modelDir := "/data/gemma4_dl/complete"
	vocab, err := LoadBPEVocab(modelDir + "/tokenizer.json")
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := LoadModelConfig(modelDir)
	if err != nil {
		t.Fatal(err)
	}
	idx, err := LoadSafetensorsIndex(modelDir)
	if err != nil {
		t.Fatal(err)
	}
	desc, err := ParseSafetensorsHeaders(modelDir, idx)
	if err != nil {
		t.Fatal(err)
	}
	rm := newRealModel(modelDir, desc)
	g := &gemmaModel{m: rm, cfg: cfg, hidden: cfg.TextConfig.HiddenSize, vocab: vocab}
	prompt := os.Getenv("PNM_PROMPT")
	if prompt == "" {
		prompt = "What is the capital of France?"
	}
	ids, err := chatIDs(vocab, prompt, false)
	if err != nil {
		t.Fatal(err)
	}
	full := append([]int{g.vocab.BosID}, ids...)
	embed := g.m.mat("model.language_model.embed_tokens.weight", cfg.TextConfig.VocabSize, g.hidden)
	T := len(full)
	seq := make([][]float32, T)
	embScale := float32(math.Sqrt(float64(g.hidden)))
	for tt, id := range full {
		row := make([]float32, g.hidden)
		for c := 0; c < g.hidden; c++ {
			row[c] = embed[id][c] * embScale
		}
		seq[tt] = row
	}
	gf := newGF(g)
	if err := gf.prefill(seq); err != nil {
		t.Fatal(err)
	}
	logits, err := g.finalLogits(seq[T-1])
	if err != nil {
		t.Fatal(err)
	}
	hidden := make([]float32, g.hidden)
	gen := []int{}
	for step := 0; step < 24; step++ {
		best := 0
		for i, v := range logits {
			if v > logits[best] {
				best = i
			}
		}
		// top-5
		type lv struct {
			id int
			v  float32
		}
		ls := make([]lv, len(logits))
		for i, v := range logits {
			ls[i] = lv{i, v}
		}
		for i := 0; i < 5; i++ {
			for j := i + 1; j < len(ls); j++ {
				if ls[j].v > ls[i].v {
					ls[i], ls[j] = ls[j], ls[i]
				}
			}
		}
		fmt.Printf("step %d top5: %d %q=%.2f | %d %q=%.2f | %d %q=%.2f\n",
			step, ls[0].id, vocab.IDToToken[ls[0].id], ls[0].v,
			ls[1].id, vocab.IDToToken[ls[1].id], ls[1].v,
			ls[2].id, vocab.IDToToken[ls[2].id], ls[2].v)
		gen = append(gen, best)
		tok := g.vocab.IDToToken[best]
		if tok == "<eos>" || tok == "<end_of_turn>" || tok == "<pad>" {
			break
		}
		for c := 0; c < g.hidden; c++ {
			hidden[c] = embed[best][c] * embScale
		}
		logits, err = g.forwardDecode(gf, hidden)
		if err != nil {
			t.Fatal(err)
		}
	}
	fmt.Println("GEN:", gen)
}
