package pnm

import (
	"fmt"
	"math"
	"os"
	"sort"
	"testing"
)

func TestHarnessDumpLogits(t *testing.T) {
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
	prompt := "What is the capital of France?"
	ids, err := chatIDs(vocab, prompt, false)
	if err != nil {
		t.Fatal(err)
	}
	full := append([]int{g.vocab.BosID}, ids...)
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
	type lv struct {
		id int
		v  float32
	}
	ls := make([]lv, len(logits))
	for i, v := range logits {
		ls[i] = lv{i, v}
	}
	sort.Slice(ls, func(i, j int) bool { return ls[i].v > ls[j].v })
	f, _ := os.Create("/tmp/pnm_logits.txt")
	defer f.Close()
	for i := 0; i < 30; i++ {
		fmt.Fprintf(f, "%d %v %q\n", ls[i].id, ls[i].v, vocab.IDToToken[ls[i].id])
	}
	// also dump raw top-1 token and full argmax
	fmt.Println("argmax:", ls[0].id, vocab.IDToToken[ls[0].id])
}
