package pnm

// bf16_oracle.go — exact BF16 oracle for the compute-node composition test,
// a straight port of HDL/core/bf16_fp_ref.py (which the RTL is validated
// against op-for-op) restricted to the ops the expert pass needs:
//
//   fma_chain: acc = RNE16(w*v + acc)  (single rounding, mirrors fma_core.v)
//   gelu:      bf16_gelu op-for-op (sqrt(2/pi) tanh form, exp via log2e
//              reduction + the 17-entry EXP2F LUT)
//
// All finite intermediate values are dyadic rationals with bounded
// significands, so float64 arithmetic is exact here and b16RNE applies the
// same nearest-even rule as bf16_fp_ref.round_bf16.

import "math"

const (
	ob16One   = 0x3F80
	ob16Two   = 0x4000
	ob16Half  = 0x3F00
	ob16GA    = 0x3F4C // bf16(sqrt(2/pi))
	ob16GB    = 0x3D37 // bf16(0.044715)
	ob16Log2E = 0x3FB9 // bf16(log2 e)
	ob16Nan   = 0x7FC0
	ob16Inf   = 0x7F80
)

var exp2fLUT = [17]uint16{0x3F80, 0x3FA9, 0x3FD2, 0x3FFD, 0x4027, 0x4052,
	0x407E, 0x40AB, 0x40D9, 0x4109, 0x413A, 0x416C, 0x41A0, 0x41D5, 0x420B, 0x4243, 0x427C}

// b16Class: 0 = zero, 1 = normal, 2 = inf, 3 = nan/subnormal-invalid (matches cls).
func b16Class(u uint16) int {
	if (u>>7)&0xFF == 0xFF {
		if u&0x7F == 0 {
			return 2
		}
		return 3
	}
	if (u>>7)&0xFF == 0 {
		return 0
	}
	return 1
}

// b16Val is the exact finite value of a BF16 word (normal or zero).
func b16Val(u uint16) float64 {
	if b16Class(u) != 1 {
		return 0
	}
	e := int((u>>7)&0xFF) - 127
	m := math.Ldexp(float64(0x80|(u&0x7F)), e-7)
	if u&0x8000 != 0 {
		return -m
	}
	return m
}

// b16RNE rounds an exact value to the nearest-even BF16 word, FTZ subnormals,
// overflow to +-Inf (mirrors round_bf16).
func b16RNE(x float64) uint16 {
	if x == 0 {
		return 0
	}
	if math.IsNaN(x) {
		return ob16Nan
	}
	neg := x < 0
	a := math.Abs(x)
	var sign uint16
	if neg {
		sign = 0x8000
	}
	if math.IsInf(a, 0) {
		return sign | ob16Inf
	}
	e := int(math.Floor(math.Log2(a)))
	if e < -126 {
		return sign // FTZ
	}
	sc := math.Ldexp(a, 7-e) // a / 2^(e-7), in [128, 256)
	fl := math.Floor(sc)
	m := int64(fl)
	if f := sc - fl; f > 0.5 || (f == 0.5 && m&1 == 1) {
		m++
	}
	if m == 256 {
		m, e = 128, e+1
	}
	if e+127 >= 255 {
		return sign | ob16Inf
	}
	if e+127 < 1 {
		return sign
	}
	return sign | uint16((e+127)<<7) | uint16(m-128)
}

func b16Mul(a, b uint16) uint16 {
	s := ((a ^ b) >> 15) & 1
	ca, cb := b16Class(a), b16Class(b)
	if ca == 3 || cb == 3 {
		return ob16Nan
	}
	if ca == 0 || cb == 0 {
		return s << 15
	}
	if ca == 2 || cb == 2 {
		return (s << 15) | ob16Inf
	}
	return b16RNE(b16Val(a) * b16Val(b))
}

func b16Add(a, b uint16) uint16 {
	ca, cb := b16Class(a), b16Class(b)
	if ca == 3 || cb == 3 {
		return ob16Nan
	}
	if ca == 0 && cb == 0 {
		return 0
	}
	if ca == 0 {
		return b
	}
	if cb == 0 {
		return a
	}
	if ca == 2 || cb == 2 {
		return ob16Inf
	}
	return b16RNE(b16Val(a) + b16Val(b))
}

func b16Sub(a, b uint16) uint16 { return b16Add(a, b^0x8000) }

func b16Div(a, b uint16) uint16 {
	s := ((a ^ b) >> 15) & 1
	ca, cb := b16Class(a), b16Class(b)
	if ca == 3 || cb == 3 {
		return ob16Nan
	}
	if ca == 0 && cb == 0 {
		return ob16Nan
	}
	if cb == 0 {
		if ca == 2 {
			return ob16Nan
		}
		return (s << 15) | ob16Inf
	}
	if ca == 0 {
		return s << 15
	}
	if ca == 2 && cb == 2 {
		return ob16Nan
	}
	if ca == 2 {
		return (s << 15) | ob16Inf
	}
	if cb == 2 {
		return s << 15
	}
	return b16RNE(b16Val(a) / b16Val(b))
}

// b16FMA is the fused multiply-add used for the accumulation oracle:
// acc = RNE16(w*v + acc) with a single rounding (fma_core.v semantics).
func b16FMA(w, v, acc uint16) uint16 {
	ca, cb, cc := b16Class(w), b16Class(v), b16Class(acc)
	if ca == 3 || cb == 3 || cc == 3 {
		return ob16Nan
	}
	if (ca == 2 && cb == 0) || (ca == 0 && cb == 2) {
		return ob16Nan
	}
	if ca == 2 || cb == 2 {
		s := ((w ^ v) >> 15) & 1
		if cc == 2 && ((acc>>15)&1) != s {
			return ob16Nan
		}
		return (s << 15) | ob16Inf
	}
	if cc == 2 {
		return acc
	}
	var av, bv, cv float64
	if ca == 1 {
		av = b16Val(w)
	}
	if cb == 1 {
		bv = b16Val(v)
	}
	if cc == 1 {
		cv = b16Val(acc)
	}
	return b16RNE(av*bv + cv)
}

// int2BF packs an integer to BF16 without rounding (truncation, matches RTL).
func int2BF(iv int) uint16 {
	s := iv < 0
	mag := iv
	if s {
		mag = -mag
	}
	if mag == 0 {
		return 0
	}
	L := 0
	for x := mag; x > 0; x >>= 1 {
		L++
	}
	L-- // msb index
	e := L
	var m9 int
	if L >= 7 {
		m9 = mag >> (L - 7)
	} else {
		m9 = mag << (7 - L)
	}
	var sign uint16
	if s {
		sign = 0x8000
	}
	ee := e + 127
	if ee >= 255 {
		return sign | ob16Inf
	}
	if ee < 1 {
		return sign
	}
	return sign | uint16(ee<<7) | uint16(m9&0x7F)
}

// b16Floor is floor() of a BF16 word as an integer (mirrors floor_bf).
func b16Floor(x uint16) int {
	if b16Class(x) == 0 {
		return 0
	}
	s := (x >> 15) & 1
	sig := 0x80 | int(x&0x7F)
	e := int((x>>7)&0xFF) - 127
	if e >= 7 {
		k := sig << (e - 7)
		if s != 0 {
			return -k
		}
		return k
	}
	if e >= 0 {
		sh := 7 - e
		k := sig >> sh
		if s != 0 && (sig&((1<<sh)-1)) != 0 {
			k++
		}
		if s != 0 {
			return -k
		}
		return k
	}
	if s != 0 {
		return -1
	}
	return 0
}

// b16Exp mirrors the RTL's bf16_exp (log2e reduction + EXP2F LUT) exactly.
func b16Exp(x uint16) uint16 {
	if b16Class(x) == 0 {
		return ob16One
	}
	t := b16Mul(x, ob16Log2E)
	k := b16Floor(t)
	f := b16Sub(t, int2BF(k))
	if k > 128 {
		return ob16Inf
	}
	if k < -128 {
		return 0
	}
	var p2k uint16
	if k >= -126 {
		p2k = uint16((k+127)&0xFF) << 7
	} else {
		p2k = ob16One
	}
	idx := b16Floor(b16Mul(f, 0x4180)) // x * 128 (check against the 17-entry LUT)
	if idx > 16 {
		idx = 16
	}
	return b16Mul(p2k, exp2fLUT[idx])
}

// b16Gelu is the node's swiglu gate activation op-for-op (bf16_fp.vh gelu).
func b16Gelu(x uint16) uint16 {
	x3 := b16Mul(b16Mul(x, x), x)
	inner := b16Add(x, b16Mul(x3, ob16GB))
	t := b16Mul(inner, ob16GA)
	e2 := b16Exp(b16Mul(t, ob16Two))
	r := b16Div(ob16Two, b16Add(e2, ob16One))
	p := b16Sub(ob16One, r)
	p = b16Add(ob16One, p)
	return b16Mul(b16Mul(x, ob16Half), p)
}

// expertB16Slice extracts a real expert's gate_up/down BF16 slices as word
// matrices [rows][cols] from the fused checkpoint layout:
//
//	gate_up_proj[e] = [gate(2*EFFfull); up(2*EFFfull)] x hidden, and the slice
//	keeps rows 0..guRows-1 (gate first EFF rows, up rows 704.. for EFF=8) and
//	the first N hidden columns; down_proj[e] keeps rows 0..N-1 and the first
//	EFF columns.  Words are the raw little-endian BF16 payloads.
func expertB16Slice(rawGateUp, rawDown []byte, e, effFull, hiddenFull, guRows, N, EFF int) ([][]uint16, [][]uint16) {
	gu := make([][]uint16, guRows)
	for r := 0; r < guRows; r++ {
		row := make([]uint16, N)
		full := r
		if r >= EFF {
			full = effFull + (r - EFF) // up halves sit after the effFull gate rows
		}
		base := (e*2*effFull + full) * hiddenFull * 2
		for c := 0; c < N; c++ {
			off := base + c*2
			if off+2 <= len(rawGateUp) {
				row[c] = uint16(rawGateUp[off]) | uint16(rawGateUp[off+1])<<8
			}
		}
		gu[r] = row
	}
	dw := make([][]uint16, N)
	for r := 0; r < N; r++ {
		row := make([]uint16, EFF)
		base := (e*hiddenFull + r) * effFull * 2
		for c := 0; c < EFF; c++ {
			off := base + c*2
			if off+2 <= len(rawDown) {
				row[c] = uint16(rawDown[off]) | uint16(rawDown[off+1])<<8
			}
		}
		dw[r] = row
	}
	return gu, dw
}

// expertTwin runs the pure-software BF16 expert pass the RTL must reproduce:
// gate = FMA rows, up = FMA rows, act = gelu(gate)*up, out = FMA rows.
func expertTwin(gu, dw [][]uint16, hidden []uint16) []uint16 {
	eff := len(gu) / 2
	gate := make([]uint16, eff)
	up := make([]uint16, eff)
	for r := 0; r < eff; r++ {
		gate[r] = fmaChain(gu[r], hidden)
		up[r] = fmaChain(gu[eff+r], hidden)
	}
	act := make([]uint16, eff)
	for i := range act {
		act[i] = b16Mul(b16Gelu(gate[i]), up[i])
	}
	out := make([]uint16, len(dw))
	for r := range dw {
		out[r] = fmaChain(dw[r], act)
	}
	return out
}

func fmaChain(row, vec []uint16) uint16 {
	var acc uint16
	for i := range row {
		var v uint16
		if i < len(vec) {
			v = vec[i]
		}
		acc = b16FMA(row[i], v, acc)
	}
	return acc
}

// f32ToB16Word converts a rounded float32 (bf16 value) to its BF16 word.
func f32ToB16Word(x float32) uint16 {
	return uint16(math.Float32bits(x) >> 16)
}
