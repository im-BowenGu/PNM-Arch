package pnm

import (
	"math"
	"testing"
)

// Reference outputs captured from CPython random.Random (3.11+): pins the
// Go port's RNG primitives to CPython's. Scenario stimuli are not pinned
// (Go scenarios draw a per-node bias constant the Python harness never did).
func TestPyRandMatchesCPython(t *testing.T) {
	r := NewPyRand(1)
	wantRandom := []float64{
		0.13436424411240122, 0.8474337369372327, 0.763774618976614,
		0.2550690257394217, 0.49543508709194095,
	}
	for i, w := range wantRandom {
		if g := r.random(); math.Abs(g-w) > 1e-17 {
			t.Fatalf("random() #%d: got %.17g want %.17g", i, g, w)
		}
	}
	wantRandrange := []int{230, 241, 194, 107, 48}
	for i, w := range wantRandrange {
		if g := r.RandRange(0, 256); g != w {
			t.Fatalf("randrange(256) #%d: got %d want %d", i, g, w)
		}
	}
	if g, w := r.RandInt(1, 64), 63; g != w {
		t.Fatalf("randint(1,64): got %d want %d", g, w)
	}
	if g, w := []int{1, 2, 4, 8}[r.ChoiceInt(4)], 1; g != w {
		t.Fatalf("choice((1,2,4,8)): got %d want %d", g, w)
	}
	if g, w := r.RandRange(1, 16), 15; g != w {
		t.Fatalf("randrange(1,16): got %d want %d", g, w)
	}
	c := []int{0, 1, 2, 3, 4, 5, 6, 7, 8, 9}
	r.Shuffle(len(c), func(i, j int) { c[i], c[j] = c[j], c[i] })
	wantShuffle := []int{8, 7, 4, 1, 2, 3, 5, 0, 9, 6}
	for i := range wantShuffle {
		if c[i] != wantShuffle[i] {
			t.Fatalf("shuffle: got %v want %v", c, wantShuffle)
		}
	}
	cum := []float64{1.0, 3.0, 6.0}
	if g := []string{"a", "b", "c"}[r.ChoicesWeighted(cum, 6.0)]; g != "c" {
		t.Fatalf("choices: got %q want c", g)
	}
	r2 := NewPyRand(0xC0FFEE)
	want2 := []float64{0.9585021777618897, 0.618826681177001, 0.016322680719979}
	for i, w := range want2 {
		if g := r2.random(); math.Abs(g-w) > 1e-17 {
			t.Fatalf("random() #%d (seed 0xC0FFEE): got %.17g want %.17g", i, g, w)
		}
	}
}
