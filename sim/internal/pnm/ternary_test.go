package pnm

import (
	"strings"
	"testing"
)

// The BitNet b1.58 ternary unit must be a first-class compute unit: named,
// byte-accounted, and reachable from the quant-mode configuration. The RTL
// datapath itself (HDL/core/ternary_mac.v, node.v CU_TYPE 8) is validated
// bit-exact by HDL/core/node_reference_test.py --cu 8.

func TestTernaryUnitType(t *testing.T) {
	if got := CUTypeTernaryAcc.String(); got != "ternary_acc" {
		t.Errorf("CUTypeTernaryAcc.String() = %q, want %q", got, "ternary_acc")
	}
	// 2-bit weight codes pack 4 per byte; the addressable unit is 1 byte.
	if got := CUTypeTernaryAcc.DTypeBytes(); got != 1 {
		t.Errorf("CUTypeTernaryAcc.DTypeBytes() = %d, want 1", got)
	}
	if got := QuantTernary.String(); got != "ternary" {
		t.Errorf("QuantTernary.String() = %q, want \"ternary\"", got)
	}
}

func TestQuantTernaryMapping(t *testing.T) {
	c := &LLMClient{Config: LLMConfig{DataType: CUTypeBF16FMA, QuantMode: QuantTernary}}
	if got := c.QuantizedCU(); got != CUTypeTernaryAcc {
		t.Errorf("QuantizedCU() = %v, want %v", got, CUTypeTernaryAcc)
	}
	if got := c.QuantWeightBytes(); got != 1 {
		t.Errorf("QuantWeightBytes() = %d, want 1", got)
	}

	// The ternary unit is ~1.58 bits/weight: 4 codes/byte, vs BF16's 16 bits.
	bf16 := &LLMClient{Config: LLMConfig{DataType: CUTypeBF16FMA, QuantMode: QuantNone}}
	if bf16.QuantWeightBytes() <= c.QuantWeightBytes() {
		t.Error("ternary weights should be smaller than the BF16 default")
	}
}

func TestTernaryPackRoundTrip(t *testing.T) {
	codes := []int8{1, -1, 0, 1, 0, -1, 1, 1, -1}
	packed := PackTernary(codes)
	if len(packed) != (len(codes)+3)/4 {
		t.Fatalf("packed len = %d, want %d", len(packed), (len(codes)+3)/4)
	}
	got := UnpackTernary(packed, len(codes))
	for i := range codes {
		if got[i] != codes[i] {
			t.Errorf("code[%d] = %d, want %d", i, got[i], codes[i])
		}
	}
	// Byte layout: code i occupies bits 2*(i%4); +1->01, -1->10, 0->00.
	want0 := TernaryCode(1) | TernaryCode(-1)<<2 | TernaryCode(0)<<4 | TernaryCode(1)<<6
	if packed[0] != want0 {
		t.Errorf("packed[0] = %08b, want %08b", packed[0], want0)
	}
	if TernaryValue(0b01) != 1 || TernaryValue(0b10) != -1 || TernaryValue(0b11) != 0 {
		t.Error("TernaryValue decode mismatch")
	}
}

func TestEncodeTernary(t *testing.T) {
	cases := []struct {
		w, scale float32
		want     int8
	}{
		{0.6, 1, 1}, {-0.6, 1, -1}, {0.4, 1, 0}, {-0.4, 1, 0},
		{3, 10, 0}, {6, 10, 1}, {-7, 10, -1}, {1, 0, 0},
	}
	for _, c := range cases {
		if got := EncodeTernary(c.w, c.scale); got != c.want {
			t.Errorf("EncodeTernary(%v,%v) = %d, want %d", c.w, c.scale, got, c.want)
		}
	}
}

func TestCompileModelIRTernary(t *testing.T) {
	cfg := &ModelConfig{}
	tc := &cfg.TextConfig
	tc.HiddenSize = 64
	tc.IntermediateSize = 128
	tc.MoEIntermediateSize = 32
	tc.NumHiddenLayers = 2
	tc.NumExperts = 4
	tc.VocabSize = 256
	tc.HeadDim = 16
	tc.NumKeyValueHeads = 2
	idx := &SafetensorsIndex{}

	bf, err := CompileModelIR(cfg, idx)
	if err != nil {
		t.Fatalf("CompileModelIR(bf16): %v", err)
	}
	tern, err := CompileModelIR(cfg, idx, WithWeightFormat(WeightsTernary))
	if err != nil {
		t.Fatalf("CompileModelIR(ternary): %v", err)
	}
	if len(bf.Ops) != len(tern.Ops) {
		t.Fatalf("op count changed: %d -> %d", len(bf.Ops), len(tern.Ops))
	}
	weights := 0
	for i := range bf.Ops {
		b, x := bf.Ops[i], tern.Ops[i]
		if b.Role != x.Role {
			t.Fatalf("op %d role %q vs %q", i, b.Role, x.Role)
		}
		if strings.Contains(b.Role, "norm") {
			if x.DType != "BF16" || x.CUType == CUTypeTernaryAcc {
				t.Errorf("norm op %q must stay BF16, got %s/%v", b.Role, x.DType, x.CUType)
			}
			continue
		}
		weights++
		if x.DType != "TERNARY" || x.CUType != CUTypeTernaryAcc {
			t.Errorf("weight op %q not lowered: dtype=%q cu=%v", x.Role, x.DType, x.CUType)
		}
		// BF16 size is numel*2; ternary packs 2 bits/weight.
		want := TernaryBytes(b.SizeBytes / 2)
		if x.SizeBytes != want {
			t.Errorf("%s size = %d, want %d", b.Role, x.SizeBytes, want)
		}
		if x.SizeBytes > b.SizeBytes/4 {
			t.Errorf("%s ternary size %d not ~1/8 of bf16 %d", b.Role, x.SizeBytes, b.SizeBytes)
		}
	}
	if weights == 0 {
		t.Fatal("no weight ops lowered")
	}
}
