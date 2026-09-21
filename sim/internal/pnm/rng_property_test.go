package pnm

import (
	"testing"
	"testing/quick"
)

// TestPyRand_IntnRangeProperty verifies ChoiceInt(n) always returns [0, n).
func TestPyRand_IntnRangeProperty(t *testing.T) {
	f := func(seed uint32, n uint16) bool {
		if n == 0 {
			return true
		}
		r := NewPyRand(uint64(seed))
		for i := 0; i < 100; i++ {
			v := r.ChoiceInt(int(n))
			if v < 0 || v >= int(n) {
				return false
			}
		}
		return true
	}
	if err := quick.Check(f, &quick.Config{MaxCount: 500}); err != nil {
		t.Error(err)
	}
}

// TestPyRand_DeterminismProperty verifies the same seed produces identical sequences.
func TestPyRand_DeterminismProperty(t *testing.T) {
	f := func(seed uint32) bool {
		r1 := NewPyRand(uint64(seed))
		r2 := NewPyRand(uint64(seed))
		for i := 0; i < 100; i++ {
			if r1.ChoiceInt(1000) != r2.ChoiceInt(1000) {
				return false
			}
		}
		return true
	}
	if err := quick.Check(f, &quick.Config{MaxCount: 1000}); err != nil {
		t.Error(err)
	}
}

// TestPyRand_DifferentSeedsProperty verifies different seeds produce different sequences.
func TestPyRand_DifferentSeedsProperty(t *testing.T) {
	f := func(seed1, seed2 uint32) bool {
		if seed1 == seed2 {
			return true
		}
		r1 := NewPyRand(uint64(seed1))
		r2 := NewPyRand(uint64(seed2))
		for i := 0; i < 10; i++ {
			if r1.ChoiceInt(10000) != r2.ChoiceInt(10000) {
				return true
			}
		}
		return false
	}
	if err := quick.Check(f, &quick.Config{MaxCount: 500}); err != nil {
		t.Error(err)
	}
}

// TestPyRand_RandomRangeProperty verifies random() returns [0, 1).
func TestPyRand_RandomRangeProperty(t *testing.T) {
	f := func(seed uint32) bool {
		r := NewPyRand(uint64(seed))
		for i := 0; i < 100; i++ {
			v := r.random()
			if v < 0.0 || v >= 1.0 {
				return false
			}
		}
		return true
	}
	if err := quick.Check(f, &quick.Config{MaxCount: 1000}); err != nil {
		t.Error(err)
	}
}

// TestPyRand_ShuffleProperty verifies that after shuffling, all original
// elements are still present (permutation invariant).
func TestPyRand_ShuffleProperty(t *testing.T) {
	f := func(seed uint32) bool {
		r := NewPyRand(uint64(seed))
		n := int(r.ChoiceInt(20) + 5) // 5..24
		original := make([]int, n)
		for i := range original {
			original[i] = i
		}
		shuffled := make([]int, n)
		copy(shuffled, original)
		r.Shuffle(n, func(i, j int) {
			shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
		})
		seen := make(map[int]bool)
		for _, v := range shuffled {
			seen[v] = true
		}
		for _, v := range original {
			if !seen[v] {
				return false
			}
		}
		return true
	}
	if err := quick.Check(f, &quick.Config{MaxCount: 500}); err != nil {
		t.Error(err)
	}
}

// TestPyRand_RandRangeProperty verifies RandRange(a,b) returns [a, b).
func TestPyRand_RandRangeProperty(t *testing.T) {
	f := func(seed uint32, a int16, b int16) bool {
		lo := int(a)
		hi := int(b)
		if lo >= hi || hi-lo > 10000 {
			return true
		}
		r := NewPyRand(uint64(seed))
		for i := 0; i < 100; i++ {
			v := r.RandRange(lo, hi)
			if v < lo || v >= hi {
				return false
			}
		}
		return true
	}
	if err := quick.Check(f, &quick.Config{MaxCount: 500}); err != nil {
		t.Error(err)
	}
}
