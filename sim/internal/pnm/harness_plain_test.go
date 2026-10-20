package pnm

import (
	"fmt"
	"math"
	"os"
	"testing"
)

func TestHarnessPlainComplete(t *testing.T) {
	if os.Getenv("PNM_REAL_TESTS") == "" {
		t.Skip("set PNM_REAL_TESTS=1 to run the real-weight harness")
	}
	modelDir := "/data/gemma4_dl/complete"
	if v := os.Getenv("PNM_MODEL"); v != "" {
		modelDir = v
	}
	prompt := "The capital of Germany is"
	if v := os.Getenv("PNM_PLAIN_PROMPT"); v != "" {
		prompt = v
	}
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
	full, err := vocab.Encode(prompt)
	if err != nil {
		t.Fatal(err)
	}
	fmt.Println("IDS:", full)
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
	for step := 0; step < 12; step++ {
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
		for i := 0; i < 5; i++ {
			fmt.Printf("step %d top5: %d %q=%.2f\n", step, ls[i].id, vocab.IDToToken[ls[i].id], ls[i].v)
		}
		best := ls[0].id
		gen = append(gen, best)
		tok := g.vocab.IDToToken[best]
		fmt.Printf("step %d: %d %q\n", step, best, tok)
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
	fmt.Printf("TEXT: %q\n", vocab.Decode(gen))
}
