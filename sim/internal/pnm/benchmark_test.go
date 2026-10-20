package pnm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBenchmarkProgramDeterministic(t *testing.T) {
	dims := Dims{Layers: 2, Bx: 4, By: 4}
	p1 := BenchmarkProgram(dims, 32, 16, 7)
	p2 := BenchmarkProgram(dims, 32, 16, 7)
	if len(p1.Stream) != len(p2.Stream) {
		t.Fatalf("stream length mismatch: %d vs %d", len(p1.Stream), len(p2.Stream))
	}
	for i := range p1.Stream {
		if p1.Stream[i].Data != p2.Stream[i].Data ||
			p1.Stream[i].Sop != p2.Stream[i].Sop ||
			p1.Stream[i].Eop != p2.Stream[i].Eop {
			t.Errorf("stream byte %d mismatch: %+v vs %+v", i, p1.Stream[i], p2.Stream[i])
		}
	}
	if p1.NInjected != 16 {
		t.Errorf("NInjected = %d, want 16", p1.NInjected)
	}
}

func TestCostModel(t *testing.T) {
	rows := CostModel()
	wantSystems := []string{"PNM", "HBM", "Groq", "Cerebras", "Taalas"}
	if len(rows) != len(wantSystems) {
		t.Fatalf("cost model rows = %d, want %d", len(rows), len(wantSystems))
	}
	for i, r := range rows {
		if !strings.Contains(r.System, wantSystems[i]) {
			t.Errorf("row %d system %q missing %q", i, r.System, wantSystems[i])
		}
		if r.CostPerGB == "" || r.Capacity == "" || r.ModelFlex == "" {
			t.Errorf("row %d missing capacity/cost/flex fields", i)
		}
	}
}

func TestWeightFormatSpectrum(t *testing.T) {
	rows := WeightFormatSpectrum()
	if len(rows) < 4 {
		t.Fatalf("weight-format rows = %d, want >= 4", len(rows))
	}
	find := func(name string) WeightFormatRow {
		for _, r := range rows {
			if r.Format == name {
				return r
			}
		}
		t.Fatalf("missing format %q", name)
		return WeightFormatRow{}
	}
	bf16 := find("BF16")
	if bf16.WtPerChassisT != 32 {
		t.Errorf("BF16 weights/chassis = %v T, want 32", bf16.WtPerChassisT)
	}
	tern := find("Ternary (BitNet b1.58)")
	if tern.BitsPerWt != 1.58 {
		t.Errorf("ternary bits/weight = %v, want 1.58", tern.BitsPerWt)
	}
	// ~10x the BF16 parameter count for the same chassis capacity.
	if ratio := tern.WtPerChassisT / bf16.WtPerChassisT; ratio < 8 || ratio > 12 {
		t.Errorf("ternary/BF16 capacity ratio = %.2f, want ~10", ratio)
	}
	// Monotonic: lower bit width holds more weights.
	for i := 1; i < len(rows); i++ {
		if rows[i].BitsPerWt < rows[i-1].BitsPerWt && rows[i].WtPerChassisT < rows[i-1].WtPerChassisT {
			t.Errorf("capacity not monotonic at %q", rows[i].Format)
		}
	}
}

func TestBenchmarkDerived(t *testing.T) {
	p := BenchmarkPoint{BytesPerCycle: 2.28, PayloadBytes: 32}
	fillDerived(&p)
	if got, want := p.BandwidthGBpsSilicon, 2.28*16; got != want {
		t.Errorf("silicon BW = %v, want %v", got, want)
	}
	if p.DispatchesPerSec <= 0 {
		t.Errorf("dispatches/s <= 0: %v", p.DispatchesPerSec)
	}
	if got := p.TokensPerSec; got <= 0 {
		t.Errorf("tokens/s <= 0: %v", got)
	}
}

func TestDRAMTypesAnchors(t *testing.T) {
	types := DRAMTypes()
	if len(types) != 6 {
		t.Fatalf("DRAM types = %d, want 6", len(types))
	}
	byName := map[string]DRAMSpec{}
	for _, s := range types {
		byName[s.Name] = s
	}
	if s := byName["LPDDR6 (reference)"]; s.PerNodeGBps != 512 {
		t.Errorf("LPDDR6 node BW = %v, want 512 (dual 64 GB 192-bit modules)", s.PerNodeGBps)
	}
	if s := byName["DDR5-5600 (baseline)"]; s.PerNodeGBps != 90 {
		t.Errorf("DDR5 baseline BW = %v, want 90", s.PerNodeGBps)
	}
	for _, s := range types {
		if s.PerNodeGBps <= 0 || s.LatencyNS <= 0 || s.RefreshPct < 0 || s.RefreshPct >= 0.2 {
			t.Errorf("bad spec %q: BW=%v lat=%v refresh=%v", s.Name, s.PerNodeGBps, s.LatencyNS, s.RefreshPct)
		}
	}
}

func TestAnalyzeDRAMMath(t *testing.T) {
	ref := DefaultReferenceParams()
	rows := AnalyzeDRAM(DRAMTypes(), ref, 3.5e6)
	if len(rows) != 6 {
		t.Fatalf("analysis rows = %d, want 6", len(rows))
	}
	lpddr6 := rows[0]
	wantAgg := 512.0 * 512
	if lpddr6.AggregateGBps != wantAgg {
		t.Errorf("LPDDR6 aggregate = %v, want %v", lpddr6.AggregateGBps, wantAgg)
	}
	// Bandwidth-bound: effective GB/s * 1e9 / (270 * (32+7)).
	eff := wantAgg * (1 - 0.02) * 1e9
	bytesPerTok := 270.0 * float64(32+wireFramingBytes)
	wantBand := eff / bytesPerTok
	if got := lpddr6.BandTokPSec; got != wantBand {
		t.Errorf("LPDDR6 BW-bound tok/s = %v, want %v", got, wantBand)
	}
	// Serial floor: 1 / (30 x 18 ns) -- strict worst case, so for LPDDR6 the
	// memory ceiling is the latency term, comfortably above the alpha=7/8 anchor.
	wantSerial := 1e9 / (30.0 * 18.0)
	if got := lpddr6.SerialTokPSec; got != wantSerial {
		t.Errorf("LPDDR6 serial floor = %v, want %v", got, wantSerial)
	}
	if lpddr6.MemoryTokPSec != wantSerial {
		t.Errorf("LPDDR6 memory ceiling = %v, want serial floor %v", lpddr6.MemoryTokPSec, wantSerial)
	}
	wantHeadroom := wantSerial / ref.FabricTokPSec
	if got := lpddr6.Headroom; got != wantHeadroom {
		t.Errorf("LPDDR6 headroom = %v, want %v", got, wantHeadroom)
	}
	if lpddr6.Headroom < 1 {
		t.Errorf("LPDDR6 headroom = %v, want >= 1 at the alpha=7/8 anchor", lpddr6.Headroom)
	}
	if !strings.Contains(lpddr6.BoundBy, "fabric transport") {
		t.Errorf("LPDDR6 bound-by = %q, want fabric transport", lpddr6.BoundBy)
	}
	if lpddr6.MeasuredTokPSec != 3.5e6 {
		t.Errorf("LPDDR6 measured = %v, want the value passed in (3.5e6)", lpddr6.MeasuredTokPSec)
	}
	// HBM3E's ~100 ns read latency drops the serial floor below the conservative
	// anchor, flipping the binding term to memory.
	hbm := rows[4]
	if hbm.SerialTokPSec > wantSerial {
		t.Errorf("HBM serial floor = %v, must be worse than LPDDR6 (%v)", hbm.SerialTokPSec, wantSerial)
	}
	if hbm.Headroom >= 1 {
		t.Errorf("HBM headroom = %v, want < 1 (memory-latency bound)", hbm.Headroom)
	}
	if !strings.Contains(hbm.BoundBy, "memory") || !strings.Contains(hbm.BoundBy, "latency") {
		t.Errorf("HBM bound-by = %q, want memory serial read latency", hbm.BoundBy)
	}
}

func TestAnalyzeDRAMDegenerate(t *testing.T) {
	// A zero fabric anchor must not produce NaN or a misclassified bound.
	ref := DefaultReferenceParams()
	ref.FabricTokPSec = 0
	rows := AnalyzeDRAM(DRAMTypes(), ref, 0)
	for _, d := range rows {
		if d.BandTokPSec != d.BandTokPSec || d.SerialTokPSec != d.SerialTokPSec || d.Headroom != d.Headroom {
			t.Errorf("NaN in analysis for %s", d.Spec.Name)
		}
		if d.BandTokPSec <= 0 || d.SerialTokPSec <= 0 || d.MemoryTokPSec <= 0 {
			t.Errorf("non-positive derived metric for %s", d.Spec.Name)
		}
	}
}

func TestReferenceFabricTokPSec(t *testing.T) {
	// The reference chassis (8,8,8) with a 32-byte payload wins even when a
	// different point is faster.
	pts := []BenchmarkPoint{
		{Dims: Dims{Layers: 3, Bx: 4, By: 4}, PayloadBytes: 32, TokensPerSec: 3.5e6},
		{Dims: Dims{Layers: 8, Bx: 8, By: 8}, PayloadBytes: 32, TokensPerSec: 3.3e6},
		{Dims: Dims{Layers: 8, Bx: 8, By: 8}, PayloadBytes: 256, TokensPerSec: 5e6},
	}
	if got := referenceFabricTokPSec(pts); got != 3.3e6 {
		t.Errorf("reference = %v, want 3.3e6 (8x8x8/32-B point)", got)
	}
	// Fallback to the best point when the reference corner is absent.
	reduced := []BenchmarkPoint{{Dims: Dims{Layers: 3, Bx: 4, By: 4}, PayloadBytes: 32, TokensPerSec: 4e6}}
	if got := referenceFabricTokPSec(reduced); got != 4e6 {
		t.Errorf("fallback = %v, want 4e6", got)
	}
	if got := referenceFabricTokPSec(nil); got != 0 {
		t.Errorf("best of empty = %v, want 0", got)
	}
}

func TestRenderDRAMTable(t *testing.T) {
	rows := AnalyzeDRAM(DRAMTypes(), DefaultReferenceParams(), 3.5e6)
	rep := &BenchmarkReport{Cost: CostModel(), DRAM: rows}
	out := rep.Render()
	for _, want := range []string{
		"DRAM latency / bandwidth estimate",
		"LPDDR6 (reference)",
		"DDR5-5600 (baseline)",
		"HBM3E (H100-class stack)",
		"BW-bound",
		"serial-floor",
		"fabric transport",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("render missing %q", want)
		}
	}
}

func TestBenchmarkJSONHasDRAM(t *testing.T) {
	rep := &BenchmarkReport{Points: make([]BenchmarkPoint, 1), Cost: CostModel(),
		DRAM: AnalyzeDRAM(DRAMTypes(), DefaultReferenceParams(), 3.5e6)}
	path := filepath.Join(t.TempDir(), "report.json")
	if err := WriteBenchmarkJSON(path, rep); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"dram_estimate"`) {
		t.Fatalf("json missing dram_estimate: %s", data)
	}
	var back BenchmarkReport
	if err := json.Unmarshal(data, &back); err != nil {
		t.Fatal(err)
	}
	if len(back.DRAM) != len(DRAMTypes()) {
		t.Errorf("round-trip DRAM rows = %d, want %d", len(back.DRAM), len(DRAMTypes()))
	}
	if back.DRAM[0].Spec.PerNodeGBps != 512 {
		t.Errorf("round-trip LPDDR6 BW = %v", back.DRAM[0].Spec.PerNodeGBps)
	}
}
