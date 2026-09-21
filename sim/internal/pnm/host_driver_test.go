package pnm

import "testing"

func TestDatatypeFromString(t *testing.T) {
	cases := []struct {
		in   string
		want ComputeUnitType
	}{
		{"bf16", CUTypeBF16FMA},
		{"fp16", CUTypeFP16FMA},
		{"FP16", CUTypeFP16FMA},
		{"", CUTypeBF16FMA},
		{"garbage", CUTypeBF16FMA},
	}
	for _, c := range cases {
		if got := datatypeFromString(c.in); got != c.want {
			t.Errorf("datatypeFromString(%q) = %v, want %v", c.in, got, c.want)
		}
	}
}

func TestNewHostDriverHotFracZeroPreserved(t *testing.T) {
	// HotFrac=0 must survive construction (disable hotspot traffic), not
	// be silently rewritten to the 0.35 default.
	hd := NewHostDriver(HostConfig{Layers: 2, Bx: 2, By: 2, HotFrac: 0})
	if hd.Cfg.HotFrac != 0 {
		t.Errorf("HotFrac = %v, want 0 preserved", hd.Cfg.HotFrac)
	}
}
