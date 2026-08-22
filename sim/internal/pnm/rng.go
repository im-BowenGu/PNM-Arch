// Package pnm is the Go port of the PNM co-simulation harness (formerly
// sim/*.py): it generates the Verilog fabric + testbench, drives parallel
// iverilog/vvp slices, and verifies delivery against the golden manifest.
//
// The RNG below replicates CPython's random.Random for integer seeds, so a
// Go run with the same --seed produces bit-identical stimuli to the Python
// harness it replaces (and the paper's documented numbers stay reproducible).
package pnm

import "math/bits"

// PyRand replicates CPython's Mersenne-Twister random.Random for integer
// seeds:
//
//   - a single-word int seed goes through init_by_array([seed], 1) with the
//     19650218 pre-seed — NOT init_genrand(seed) directly;
//   - random() = (a*2^26 + b) / 2^53 with a = w>>5, b = w>>6 from two words;
//   - randrange/randint/choice/shuffle use _randbelow = getrandbits(k) with
//     rejection sampling, getrandbits(k) = w >> (32-k) for k <= 32;
//   - choices(weights=...) = bisect_right(cum_weights, random()*total).
type PyRand struct {
	mt  [624]uint32
	mti int
}

// NewPyRand seeds the generator the way CPython seeds Random(int).
func NewPyRand(seed uint64) *PyRand {
	r := &PyRand{}
	r.initGenrand(19650218)
	r.initByArray([]uint32{uint32(seed)})
	return r
}

func (r *PyRand) initGenrand(seed uint32) {
	r.mt[0] = seed
	for i := 1; i < 624; i++ {
		r.mt[i] = 1812433253*(r.mt[i-1]^(r.mt[i-1]>>30)) + uint32(i)
	}
	r.mti = 624
}

func (r *PyRand) initByArray(key []uint32) {
	const n = 624
	i, j := 1, 0
	k := max(n, len(key)) // CPython: N if N > keylength else keylength
	for ; k > 0; k-- {
		r.mt[i] = (r.mt[i] ^ ((r.mt[i-1] ^ (r.mt[i-1] >> 30)) * 1664525)) + key[j] + uint32(j)
		i++
		j++
		if i >= n {
			r.mt[0] = r.mt[n-1]
			i = 1
		}
		if j >= len(key) {
			j = 0
		}
	}
	for k = n - 1; k > 0; k-- {
		r.mt[i] = (r.mt[i] ^ ((r.mt[i-1] ^ (r.mt[i-1] >> 30)) * 1566083941)) - uint32(i)
		i++
		if i >= n {
			r.mt[0] = r.mt[n-1]
			i = 1
		}
	}
	r.mt[0] = 0x80000000
}

var mtMag = [2]uint32{0, 0x9908b0df}

// next is genrand_uint32: twist + tempering.
func (r *PyRand) next() uint32 {
	const n = 624
	const m = 397
	if r.mti >= n {
		var kk int
		for kk = 0; kk < n-m; kk++ {
			y := (r.mt[kk] & 0x80000000) | (r.mt[kk+1] & 0x7fffffff)
			r.mt[kk] = r.mt[kk+m] ^ (y >> 1) ^ mtMag[y&1]
		}
		for ; kk < n-1; kk++ {
			y := (r.mt[kk] & 0x80000000) | (r.mt[kk+1] & 0x7fffffff)
			r.mt[kk] = r.mt[kk+(m-n)] ^ (y >> 1) ^ mtMag[y&1]
		}
		y := (r.mt[n-1] & 0x80000000) | (r.mt[0] & 0x7fffffff)
		r.mt[n-1] = r.mt[m-1] ^ (y >> 1) ^ mtMag[y&1]
		r.mti = 0
	}
	y := r.mt[r.mti]
	r.mti++
	y ^= y >> 11
	y ^= (y << 7) & 0x9d2c5680
	y ^= (y << 15) & 0xefc60000
	y ^= y >> 18
	return y
}

// getrandbits returns k bits (k <= 32): one tempered word, shifted.
func (r *PyRand) getrandbits(k int) uint32 {
	return r.next() >> (32 - k)
}

// random is CPython's 53-bit random() in [0, 1).
func (r *PyRand) random() float64 {
	a := r.next() >> 5
	b := r.next() >> 6
	return (float64(a)*67108864.0 + float64(b)) / 9007199254740992.0
}

// randbelow returns a uniform int in [0, n): _randbelow_with_getrandbits.
func (r *PyRand) randbelow(n int) int {
	if n <= 0 {
		return 0
	}
	k := bits.Len(uint(n))
	for {
		if v := int(r.getrandbits(k)); v < n {
			return v
		}
	}
}

// RandRange returns a uniform int in [a, b).
func (r *PyRand) RandRange(a, b int) int { return a + r.randbelow(b-a) }

// RandInt returns a uniform int in [a, b] inclusive.
func (r *PyRand) RandInt(a, b int) int { return a + r.randbelow(b-a+1) }

// ChoiceInt returns an index into a sequence of length n.
func (r *PyRand) ChoiceInt(n int) int { return r.randbelow(n) }

// Shuffle performs Python's in-place Fisher-Yates (reversed range).
func (r *PyRand) Shuffle(n int, swap func(i, j int)) {
	for i := n - 1; i >= 1; i-- {
		j := r.randbelow(i + 1)
		swap(i, j)
	}
}

// ChoicesWeighted returns an index into a population of length len(cum),
// replicating random.choices(..., weights=cum-derived): x = random()*total,
// then bisect_right(cum, x, 0, n-1) — the first index whose cumulative
// weight exceeds x (after all elements equal to x).
func (r *PyRand) ChoicesWeighted(cum []float64, total float64) int {
	x := r.random() * total
	lo, hi := 0, len(cum)-1
	for lo < hi {
		mid := (lo + hi) / 2
		if x < cum[mid] {
			hi = mid
		} else {
			lo = mid + 1
		}
	}
	return lo
}
