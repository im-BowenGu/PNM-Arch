package pnm

import "testing"

func TestExpertNodeMapping(t *testing.T) {
	// X-major spread across a 4x4 board, wrapping in Y.
	cases := []struct {
		expert int
		x, y   int
	}{
		{0, 0, 0},
		{3, 3, 0},
		{4, 0, 1},
		{109, 1, 3}, // 109%4=1, (109/4)%4=3
		{127, 3, 3},
	}
	for _, c := range cases {
		got := ExpertNode(2, c.expert, 4, 4)
		if got.L != 2 || got.X != c.x || got.Y != c.y {
			t.Errorf("ExpertNode(2,%d,4,4)=%s want (2,%d,%d)", c.expert, got, c.x, c.y)
		}
	}
	// Degenerate boards must not divide by zero.
	if n := ExpertNode(0, 5, 0, 0); n != (NodeID{L: 0, X: 0, Y: 0}) {
		t.Errorf("ExpertNode zero board = %s", n)
	}
}

func TestBuildGatedFabricProgram(t *testing.T) {
	decisions := map[int][]int{0: {109, 103, 51, 41, 1, 79, 4, 56}}
	payload := make([]byte, 32)
	for i := range payload {
		payload[i] = byte(i)
	}
	dims := Dims{Layers: 1, Bx: 4, By: 4}
	res, err := BuildGatedFabricProgram(decisions, payload, GatedFabricConfig{Dims: dims, Seed: 1})
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	if res.PlannedDFlits != 8 || res.MoE != 8 {
		t.Fatalf("planned=%d moe=%d, want 8/8", res.PlannedDFlits, res.MoE)
	}
	if len(res.Prog.Stream) == 0 {
		t.Fatal("empty wire stream")
	}
	for _, r := range res.Records {
		want := ExpertNode(0, r.ExpertIdx, dims.Bx, dims.By)
		if r.TargetNode != want {
			t.Errorf("expert %d -> %s, want %s", r.ExpertIdx, r.TargetNode, want)
		}
	}
	// A second identical build (same seed) must be bit-identical.
	res2, err := BuildGatedFabricProgram(decisions, payload, GatedFabricConfig{Dims: dims, Seed: 1})
	if err != nil {
		t.Fatalf("build2: %v", err)
	}
	if len(res.Prog.Stream) != len(res2.Prog.Stream) {
		t.Fatal("non-deterministic stream length")
	}
	for i := range res.Prog.Stream {
		if res.Prog.Stream[i] != res2.Prog.Stream[i] {
			t.Fatalf("non-deterministic wire byte at %d", i)
		}
	}
}

func TestBuildGatedFabricDropsOutOfChassisLayers(t *testing.T) {
	// Layer 3 is outside a 1-layer chassis: its experts are dropped, not
	// silently mapped onto layer 0.
	res, err := BuildGatedFabricProgram(
		map[int][]int{0: {1, 2}, 3: {4, 5}},
		make([]byte, 32),
		GatedFabricConfig{Dims: Dims{Layers: 1, Bx: 4, By: 4}, Seed: 1})
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	if res.PlannedDFlits != 2 {
		t.Fatalf("planned=%d, want 2 (layer 3 dropped)", res.PlannedDFlits)
	}
}
