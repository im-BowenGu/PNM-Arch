package pnm

import (
	"encoding/binary"
	"math"
	"math/rand"
	"testing"
)

// Precision envelope of the in-process forward pass (docs/real_weights.md):
// the engine accumulates in float32, so these tests bound the rounding error
// at a sensible reference scale by recomputing the same kernels in float64.
// The model's own BF16 weights carry ~2^-8 relative quantization, so any
// float32 accumulation error below ~1e-4 is irrelevant to the results;
// these bounds (~1e-6) document that the engine is numerically faithful.

// encodeBF16 converts f32 to bf16 with round-to-nearest-even on the
// 8-bit mantissa (the significant path; used to build deterministic rows).
func encodeBF16(v float32) uint16 {
	u := math.Float32bits(v)
	sign := uint16((u >> 16) & 0x8000)
	exp := int((u>>23)&0xFF) - 127 + 127
	man := (u >> 13) & 0x7F
	rem := (u >> 12) & 0x1
	if rem != 0 && ((man & 0x1) != 0 || ((u>>11)&0x7FF) != 0) {
		man++
		if man == 0x80 {
			man = 0
			exp++
		}
	}
	return sign | (uint16(exp&0xFF) << 7) | (uint16(man & 0x7F))
}

// evalDotF64 is the float64 reference accumulation of evalDot.
func evalDotF64(row []byte, cols int, in []float64) float64 {
	var acc float64
	for c := 0; c < cols; c++ {
		acc += float64(bf16ToF32(binary.LittleEndian.Uint16(row[c*2:]))) * in[c]
	}
	return acc
}

func TestForwardPass_Float32AccumulationBounded(t *testing.T) {
	rng := rand.New(rand.NewSource(17))
	cols := 2816 // Gemma-4 hidden dimension

	row := make([]byte, cols*2)
	in := make([]float32, cols)
	inF64 := make([]float64, cols)
	for c := 0; c < cols; c++ {
		v := rng.Float32() - 0.5 // BF16-ish magnitude
		binary.LittleEndian.PutUint16(row[c*2:], encodeBF16(v))
		in[c] = rng.Float32() * 0.1
		inF64[c] = float64(in[c])
	}

	f32 := evalDot(row, cols, in)
	f64 := evalDotF64(row, cols, inF64)
	rel := math.Abs(float64(f32)-f64) / math.Max(math.Abs(f64), 1e-12)
	if rel > 1e-5 {
		t.Fatalf("evalDot relative error %.3e exceeds 1e-5 (f32=%e f64=%e)", rel, f32, f64)
	}
}

// vNormF64 is the float64 reference RMSNorm (same formula as vNorm).
func vNormF64(x []float64, eps float64) []float64 {
	n := len(x)
	var ss float64
	for _, v := range x {
		ss += v * v
	}
	inv := 1 / math.Sqrt(ss/float64(n)+eps)
	out := make([]float64, n)
	for i, v := range x {
		out[i] = v * inv
	}
	return out
}

func TestForwardPass_RMSNormBounded(t *testing.T) {
	rng := rand.New(rand.NewSource(23))
	x := make([]float32, 2816)
	xF64 := make([]float64, len(x))
	for i := range x {
		x[i] = rng.Float32() - 0.5
		xF64[i] = float64(x[i])
	}

	f32 := vNorm(x, 1e-6)
	f64 := vNormF64(xF64, 1e-6)
	maxRel := 0.0
	for i := range f32 {
		r := math.Abs(float64(f32[i])-f64[i]) / math.Max(math.Abs(f64[i]), 1e-12)
		if r > maxRel {
			maxRel = r
		}
	}
	if maxRel > 1e-5 {
		t.Fatalf("vNorm max relative error %.3e exceeds 1e-5", maxRel)
	}
}