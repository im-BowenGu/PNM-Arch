package pnm

import (
	"math"
	"strings"
	"testing"
)

func TestMeanAbsDiff(t *testing.T) {
	cases := []struct {
		n    int
		want float64
	}{
		{1, 0}, {2, 0.5}, {4, 1.25}, {8, 2.625}, {16, 5.3125},
	}
	for _, c := range cases {
		if got := meanAbsDiff(c.n); math.Abs(got-c.want) > 1e-12 {
			t.Errorf("meanAbsDiff(%d)=%v want %v", c.n, got, c.want)
		}
	}
}

func TestAvgNoBHops(t *testing.T) {
	// 8x8x8: equal mean abs diff on each axis.
	if got, want := AvgNoBHops(Dims{Layers: 8, Bx: 8, By: 8}), 3*2.625; math.Abs(got-want) > 1e-12 {
		t.Errorf("AvgNoBHops(8x8x8)=%v want %v", got, want)
	}
	// single layer, 4x4 board.
	if got, want := AvgNoBHops(Dims{Layers: 1, Bx: 4, By: 4}), 2*1.25; math.Abs(got-want) > 1e-12 {
		t.Errorf("AvgNoBHops(1x4x4)=%v want %v", got, want)
	}
	// 1x1x1 has no hops.
	if got := AvgNoBHops(Dims{Layers: 1, Bx: 1, By: 1}); got != 0 {
		t.Errorf("AvgNoBHops(1x1x1)=%v want 0", got)
	}
}

func TestAnalyzeNodeNetworkEnergy(t *testing.T) {
	p := DefaultEnergyParams()
	ref := DefaultReferenceParams()
	e := AnalyzeNodeNetworkEnergy(Dims{Layers: 8, Bx: 8, By: 8}, ref.FabricTokPSec, ref.PayloadBytes, p)

	if e.Nodes != 512 {
		t.Fatalf("nodes=%d want 512", e.Nodes)
	}
	if math.Abs(e.AvgHops-7.875) > 1e-12 {
		t.Errorf("avg hops=%v want 7.875", e.AvgHops)
	}
	if e.FlitBytes != ref.PayloadBytes+wireFramingBytes {
		t.Errorf("flit bytes=%d want %d", e.FlitBytes, ref.PayloadBytes+wireFramingBytes)
	}
	if math.Abs(e.DispatchesPerSec-ref.FabricTokPSec*DispatchesPerToken) > 1 {
		t.Errorf("dispatches/s=%v want %v", e.DispatchesPerSec, ref.FabricTokPSec*DispatchesPerToken)
	}
	// Node power is nodes x (idle+mac+dram), independent of rate.
	wantNode := 512 * (p.NodeIdleW + p.NodeMacW + p.NodeDramW)
	if math.Abs(e.NodeW-wantNode) > 1e-6 {
		t.Errorf("node W=%v want %v", e.NodeW, wantNode)
	}
	if math.Abs(e.InfraW-(p.RouterW+p.SpineW)) > 1e-9 {
		t.Errorf("infra W=%v want %v", e.InfraW, p.RouterW+p.SpineW)
	}
	// Wall >= raw; network is a small share of a 512-node chassis.
	if e.WallW < e.NodeW+e.InfraW+e.NetworkW-1e-6 {
		t.Errorf("wall %v < raw sum", e.WallW)
	}
	if e.NetworkPct <= 0 || e.NetworkPct > 5 {
		t.Errorf("network share %v%% out of expected (0,5]", e.NetworkPct)
	}
	if e.EnergyPJ <= 0 {
		t.Errorf("energy/token=%v want >0", e.EnergyPJ)
	}
}

func TestEnergyScalesWithChassis(t *testing.T) {
	p := DefaultEnergyParams()
	ref := DefaultReferenceParams()
	small := AnalyzeNodeNetworkEnergy(Dims{Layers: 1, Bx: 4, By: 4}, ref.FabricTokPSec, ref.PayloadBytes, p)
	big := AnalyzeNodeNetworkEnergy(Dims{Layers: 8, Bx: 8, By: 8}, ref.FabricTokPSec, ref.PayloadBytes, p)
	if big.AvgHops <= small.AvgHops {
		t.Errorf("hops should grow with chassis: %v vs %v", small.AvgHops, big.AvgHops)
	}
	if big.NodeW <= small.NodeW {
		t.Errorf("node power should grow: %v vs %v", small.NodeW, big.NodeW)
	}
	if big.NetworkW <= small.NetworkW {
		t.Errorf("network power should grow: %v vs %v", small.NetworkW, big.NetworkW)
	}
}

func TestAnalyzeSweepEnergyDedups(t *testing.T) {
	ref := DefaultReferenceParams()
	pts := []BenchmarkPoint{
		{Dims: Dims{Layers: 1, Bx: 4, By: 4}, PayloadBytes: 32},
		{Dims: Dims{Layers: 1, Bx: 4, By: 4}, PayloadBytes: 256},
		{Dims: Dims{Layers: 8, Bx: 8, By: 8}, PayloadBytes: 32},
	}
	got := AnalyzeSweepEnergy(pts, ref, DefaultEnergyParams())
	if len(got) != 2 {
		t.Fatalf("got %d energy rows, want 2 (deduped)", len(got))
	}
	if got[0].Nodes != 16 || got[1].Nodes != 512 {
		t.Errorf("unexpected node counts: %d, %d", got[0].Nodes, got[1].Nodes)
	}
}

func TestRenderEnergyTables(t *testing.T) {
	ref := DefaultReferenceParams()
	rep := &BenchmarkReport{
		Energy:         AnalyzeSweepEnergy([]BenchmarkPoint{{Dims: Dims{Layers: 8, Bx: 8, By: 8}}}, ref, DefaultEnergyParams()),
		MemoryChannels: AnalyzeMemoryChannels(PerNodeChannelGBps, ref.ChassisNodes, 2, DefaultMemChannelCounts()),
	}
	out := rep.RenderEnergy()
	for _, want := range []string{
		"Node-network energy estimate",
		"Per-node multi-channel memory",
		"net %",
		"bytes/beat",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("RenderEnergy missing %q", want)
		}
	}
}

func TestAnalyzeMemoryChannels(t *testing.T) {
	rows := AnalyzeMemoryChannels(16, 512, 2, []int{1, 4, 8, 16})
	if len(rows) != 4 {
		t.Fatalf("got %d rows want 4", len(rows))
	}
	for i, r := range rows {
		wantNode := 16 * float64(r.Channels)
		if math.Abs(r.NodeGBps-wantNode) > 1e-9 {
			t.Errorf("row %d node BW=%v want %v", i, r.NodeGBps, wantNode)
		}
		if math.Abs(r.ChassisTBps-r.NodeGBps*512/1000) > 1e-9 {
			t.Errorf("row %d chassis TB/s=%v", i, r.ChassisTBps)
		}
		if r.BytesPerBeat != r.Channels*2 {
			t.Errorf("row %d bytes/beat=%d want %d", i, r.BytesPerBeat, r.Channels*2)
		}
		if math.Abs(r.PerChannelGBps-16) > 1e-9 {
			t.Errorf("row %d per-channel BW changed: %v", i, r.PerChannelGBps)
		}
	}
	// 16 channels = one module = 256 GB/s; the dual-module reference is 32.
	last := rows[len(rows)-1]
	if math.Abs(last.NodeGBps-256) > 1e-9 {
		t.Errorf("16-channel node BW=%v want 256", last.NodeGBps)
	}
}
