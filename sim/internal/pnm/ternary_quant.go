package pnm

// BitNet b1.58 ternary weight encoding, shared by the model compiler and the
// node's weight path. The 2-bit code matches HDL/core/weight_dequant.v
// (mode 4) and HDL/core/ternary_acc.v: 2'b01 -> +1, 2'b10 -> -1, else 0.
// Four codes pack per byte, low code in the low bits.

// TernaryCode returns the 2-bit code for a ternary value in {-1, 0, +1}.
func TernaryCode(v int8) byte {
	switch {
	case v > 0:
		return 0b01
	case v < 0:
		return 0b10
	default:
		return 0b00
	}
}

// TernaryValue decodes a 2-bit code back to {-1, 0, +1}.
func TernaryValue(code byte) int8 {
	switch code & 0b11 {
	case 0b01:
		return 1
	case 0b10:
		return -1
	default:
		return 0
	}
}

// EncodeTernary quantizes one FP weight to a ternary code by rounding w/scale
// to the nearest of {-1, 0, +1}. scale <= 0 (or a denormal) yields 0.
func EncodeTernary(w, scale float32) int8 {
	if scale <= 0 {
		return 0
	}
	r := w / scale
	if r > 0.5 {
		return 1
	}
	if r < -0.5 {
		return -1
	}
	return 0
}

// PackTernary packs codes (values in {-1,0,+1}) four per byte, padding the tail
// with 0 codes.
func PackTernary(codes []int8) []byte {
	out := make([]byte, (len(codes)+3)/4)
	for i, v := range codes {
		out[i/4] |= TernaryCode(v) << (2 * (i % 4))
	}
	return out
}

// UnpackTernary decodes n codes from packed bytes.
func UnpackTernary(packed []byte, n int) []int8 {
	out := make([]int8, n)
	for i := 0; i < n; i++ {
		out[i] = TernaryValue(packed[i/4] >> (2 * (i % 4)))
	}
	return out
}
