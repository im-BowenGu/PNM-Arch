package pnm

// benchmark.go — the architecture benchmark: a controlled fabric sweep plus the
// cost/TCO model the paper argues for.
//
// Two things are quantified separately (and never conflated):
//
//  1. Measured transport metrics, from the cycle-exact vvp fabric (RunOne):
//     wire bytes, DMA bytes, doorbell activations, per-flit latency and the
//     sustained bytes/cycle. These are *machine-checked* (byte-exact delivery,
//     zero drops, closed-form latency equality). The vvp link is 100 MHz x
//     1 byte/cycle; the silicon link is 1 GHz x 16 bytes/cycle (128-bit), and
//     the fabric is deterministic, so cycle counts carry over unchanged while
//     per-cycle payload scales by 16.
//
//  2. Projected model-level throughput and cost/TCO, from the paper's stated
//     parameters (270 dispatches/token, $/GB, power). These are analytic
//     projections, clearly labelled, on top of the measured substrate.
//
// `pnmhost benchmark` runs this and optionally exports CSV/JSON.

import (
	"encoding/csv"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// BenchmarkConfig controls the fabric sweep.
type BenchmarkConfig struct {
	DimsList    []Dims // chassis shapes to sweep
	PayloadLens []int  // flit payload sizes (bytes) to sweep
	Flits       int    // flits per point
	Seed        int64
	Groups      int
	Replays     int
}

// DefaultBenchmarkConfig is the compact reference sweep.
func DefaultBenchmarkConfig() BenchmarkConfig {
	return BenchmarkConfig{
		DimsList:    []Dims{{1, 4, 4}, {3, 4, 4}, {8, 8, 8}},
		PayloadLens: []int{32, 256, 1024},
		Flits:       64,
		Seed:        1,
		Replays:     1,
	}
}

// BenchmarkPoint is one measured sweep point.
type BenchmarkPoint struct {
	Dims          Dims
	Nodes         int
	PayloadBytes  int
	Flits         int
	WireBytes     int
	DmaBytes      int
	Packets       int
	Activations   int
	WorstSpanCyc  int
	BytesPerCycle float64
	LatencyMin    int
	LatencyMean   int
	LatencyMax    int
	Pass          bool

	// Derived projections (see file header). Silicon carries 16 B/cycle/link.
	BandwidthGBpsSilicon float64 // = BytesPerCycle * 16 * 1e9 / 1e9 (bytes/s -> GB/s)
	DispatchesPerSec     float64 // silicon dispatch rate
	TokensPerSec         float64 // / DispatchesPerToken
}

const (
	// Silicon link model (Paper §2.3): 1 GHz, 128-bit = 16 bytes/cycle/link.
	// The vvp model is 100 MHz byte-serial; cycle counts are identical, the
	// per-cycle payload is 16x.
	siliconBytesPerCycle = 16.0
	siliconClockHz       = 1e9
	// Framing overhead per flit on the wire (LAYER|MODULE|CTRL|LEN_LO|LEN_HI|CRC x2)
	wireFramingBytes = 7
	// Gemma-4-class reference: dispatches per generated token (Paper §2.6).
	DispatchesPerToken = 270.0
)

// BenchmarkProgram builds a controlled benchmark program: `flits` routed flits
// of `payloadLen` bytes, no backpressure (BP=1), spread round-robin over the
// nodes plus a share to the worst-case corner. Closed-form latency applies.
func BenchmarkProgram(dims Dims, payloadLen, flits int, seed int64) *Program {
	nodes := AllNodes(dims.Layers, dims.Bx, dims.By)
	p := NewProgram("bench", nodes, "exact")
	rng := NewPyRand(uint64(seed))
	for _, n := range nodes {
		p.ProgramNode(n, "dot", randBytesInt(rng, 16), 0)
		p.BP[n] = 1 // idle fabric: full-speed delivery
	}
	payload := make([]byte, payloadLen)
	for i := 0; i < flits; i++ {
		for j := range payload {
			payload[j] = byte((i*31 + j*7 + 1) & 0xFF)
		}
		n := nodes[rng.ChoiceInt(len(nodes))]
		p.InjectRouted(n, CTRL_COMPUTE_SPINE|((i&0x0F)&^1), payload, false)
	}
	return p
}

// fillDerived populates the silicon-equivalent projections from a raw point.
func fillDerived(p *BenchmarkPoint) {
	p.BandwidthGBpsSilicon = p.BytesPerCycle * siliconBytesPerCycle * siliconClockHz / 1e9
	p.DispatchesPerSec = p.BandwidthGBpsSilicon * 1e9 / float64(p.PayloadBytes+wireFramingBytes)
	p.TokensPerSec = p.DispatchesPerSec / DispatchesPerToken
}

// RunBenchmarkSweep runs the controlled sweep through the real fabric gates.
func RunBenchmarkSweep(cfg BenchmarkConfig) ([]BenchmarkPoint, bool) {
	if cfg.Flits < 1 {
		cfg.Flits = 64
	}
	var pts []BenchmarkPoint
	okAll := true
	for _, dims := range cfg.DimsList {
		nodes := AllNodes(dims.Layers, dims.Bx, dims.By)
		for _, plen := range cfg.PayloadLens {
			prog := BenchmarkProgram(dims, plen, cfg.Flits, cfg.Seed)
			groups := cfg.Groups
			sr, ok := RunOne(prog, nodes, dims, groups, cfg.Replays)
			if sr == nil {
				okAll = false
				continue
			}
			// bytes/cycle on the wire; framing already included in wire bytes.
			pt := BenchmarkPoint{
				Dims:          dims,
				Nodes:         len(nodes),
				PayloadBytes:  plen,
				Flits:         cfg.Flits,
				WireBytes:     sr.WireBytes,
				DmaBytes:      sr.DmaBytes,
				Packets:       sr.Packets,
				Activations:   sr.Activations,
				WorstSpanCyc:  sr.WorstSpanCyc,
				BytesPerCycle: sr.BytesPerCycle,
				LatencyMin:    sr.LatencyMin,
				LatencyMean:   sr.LatencyMean,
				LatencyMax:    sr.LatencyMax,
				Pass:          ok,
			}
			fillDerived(&pt)
			pts = append(pts, pt)
			if !ok {
				okAll = false
			}
		}
	}
	return pts, okAll
}

// CostModelRow is one row of the cost/TCO comparison table.
type CostModelRow struct {
	System    string
	Capacity  string
	Aggregate string
	Power     string
	CostUSD   string
	CostPerGB string
	ModelFlex string // model/programmability fixedness at the silicon level
}

// CostModel returns the cost/TCO comparison the paper argues for. Every figure
// is a projection parameter from the paper (Table 2 / §3.3 / §4) or, for
// third-party systems, the vendor's own published claim (as of 2026: Taalas
// HC1 per Next Platform/Register, Groq LPU, Cerebras CS-3, NVIDIA GPUs);
// none of these rows is measured here. Column model-flex ranks where the model
// lives: DRAM+SW, on-chip SRAM (static dataflow), or etched ROM (MSIC).
func CostModel() []CostModelRow {
	return []CostModelRow{
		{
			System:    "PNM 512-node chassis (LPDDR6 + DUV MAC)",
			Capacity:  "64 TB",
			Aggregate: "~262 TB/s node-local",
			Power:     "~10 kW (15 W/node)",
			CostUSD:   "~$1.0M (~$2,000/node BOM)",
			CostPerGB: "~$16/GB",
			ModelFlex: "any model/program (compile-time schedule)",
		},
		{
			System:    "HBM GPU fleet (H100/H200-class), capacity-equivalent",
			Capacity:  "64 TB (819 GPUs x ~80 GB HBM)",
			Aggregate: "far higher (idle in decode)",
			Power:     "~0.25 MW",
			CostUSD:   "~$24.6M (819 x H100-class @ ~$30k)",
			CostPerGB: "~$375/GB",
			ModelFlex: "any model (software; SWA cache)",
		},
		{
			System:    "Groq LPU (on-chip SRAM static dataflow)",
			Capacity:  "~230 MB SRAM/chip (capacity-bound infeasible at 64 TB)",
			Aggregate: "~80 TB/s chip-local (SRAM)",
			Power:     "~275 W/chip; high per byte",
			CostUSD:   "infeasible: ~278k chips to reach 64 TB",
			CostPerGB: "orders of magnitude >$16/GB",
			ModelFlex: "any model at compile time (no runtime instruction fetch)",
		},
		{
			System:    "Cerebras CS-3 (waferscale on-chip SRAM)",
			Capacity:  "~44 GB SRAM/wafer (capacity-bound infeasible at 64 TB)",
			Aggregate: "~21 PB/s (SRAM, low latency)",
			Power:     "~20 kW/module; ~1,455 wafers for 64 TB",
			CostUSD:   "infeasible at 64 TB capacity",
			CostPerGB: "orders of magnitude >$16/GB",
			ModelFlex: "any model at compile time (static dataflow)",
		},
		{
			System:    "Taalas HC1 (mask-ROM MSIC, Llama-3.1-8B)",
			Capacity:  "8B params etched; SRAM recall fabric for KV/adapters",
			Aggregate: "~17k tok/s per user on 8B (vendor-claimed demo)",
			Power:     "~200 W/card; 2.5 kW per 10-card server",
			CostUSD:   "not published (AMD acquisition, closing Q4 2026)",
			CostPerGB: "ultra-dense ROM cost but model-frozen",
			ModelFlex: "fixed 8B model; any change = 2-metal-layer re-spin",
		},
	}
}

// Paper reference capacities for the weight-format table (Paper §2.4 node
// 2x64 GB = 128 GB; §3.1 chassis 512 nodes x 128 GB = 64 TB).
const (
	NodeCapacityGB    = 128
	ChassisCapacityTB = 64
)

// WeightFormatRow is one row of the weight-encoding capacity table: how many
// weights a fixed-capacity node and chassis hold for a given per-weight bit
// width. Analytic (capacity is bits x DRAM); weights only -- KV cache and
// activations are budgeted separately (Paper §2.7). Not a measurement.
type WeightFormatRow struct {
	Format        string  `json:"format"`
	BitsPerWt     float64 `json:"bits_per_weight"`
	WtPerNodeG    float64 `json:"weights_per_node_billions"`     // 128 GB node
	WtPerChassisT float64 `json:"weights_per_chassis_trillions"` // 64 TB chassis
	Note          string  `json:"note"`
}

// WeightFormatSpectrum returns the capacity-per-encoding table. The point it
// makes for the paper (§4.5): the same 64 TB chassis holds ~32 T BF16 weights
// but ~324 T ternary weights, so BitNet-class encodings (Paper §3.6) let a
// single commodity-DRAM chassis hold models that need a GPU fleet otherwise.
func WeightFormatSpectrum() []WeightFormatRow {
	rows := []struct {
		name string
		bits float64
		note string
	}{
		{"BF16", 16, "reference precision (Paper §3.6 default)"},
		{"INT8", 8, "2x compression; repo weight_dequant int8 mode"},
		{"INT4 / FP4", 4, "4x compression; repo weight_dequant int4/fp4 modes"},
		{"MXFP4", 4.25, "4-bit payload + shared 8-bit scale per 32 weights"},
		{"Ternary (BitNet b1.58)", 1.58, "select-add accumulator; ~10x vs BF16 (Paper §3.6)"},
	}
	out := make([]WeightFormatRow, 0, len(rows))
	for _, r := range rows {
		out = append(out, WeightFormatRow{
			Format: r.name, BitsPerWt: r.bits,
			WtPerNodeG:    float64(NodeCapacityGB) * 8.0 / r.bits,    // GB x 8 (Gbit) / bits = G params
			WtPerChassisT: float64(ChassisCapacityTB) * 8.0 / r.bits, // TB x 8 (Tb) / bits = T params
			Note:          r.note,
		})
	}
	return out
}

// DRAMSpec is one row of the memory-class estimate table. Every figure is a
// characterized model input -- a published-typical class value or the repo's
// RTL controller profile -- NOT a measurement of this checkout. The paper's
// validation scope (Paper §4.4) labels all ns-level latencies as projections.
type DRAMSpec struct {
	Name        string  // memory class
	PerNodeGBps float64 // node-local read bandwidth (GB/s)
	LatencyNS   float64 // typical read-to-first-data latency (ns)
	RefreshPct  float64 // refresh overhead as a share of peak bandwidth (0..1)
	Note        string  // provenance label
}

// ReferenceParams carries the paper's reference-chassis sizing the DRAM model
// is evaluated against (Paper §2.1, §2.6, §2.8, Table 2).
type ReferenceParams struct {
	ChassisNodes     int     // 512 nodes
	ModelLayers      int     // 30 decoder layers per token (Gemma-4-class fixture)
	DispatchesPerTok float64 // 270 dispatches per generated token
	PayloadBytes     int     // token-dispatch payload bytes (matches the 32-byte sweep point)
	FabricTokPSec    float64 // conservative cross-layer fabric anchor (Paper §2.8, alpha=7/8)
}

// DefaultReferenceParams is the paper's reference chassis. FabricTokPSec is the
// honest cross-layer sizing R = B/(alpha*S) at alpha=7/8 (~3e8 dispatches/s /
// 270 = ~1.1e6 tok/s) -- the sizing the paper argues for, not the optimistic
// layer-local corner.
func DefaultReferenceParams() ReferenceParams {
	return ReferenceParams{ChassisNodes: 512, ModelLayers: 30, DispatchesPerTok: DispatchesPerToken, PayloadBytes: 32, FabricTokPSec: 1.1e6}
}

// DRAMTypes returns the memory-class table. Bandwidth anchors: LPDDR6 512
// GB/s/node is the paper's §2.4 dual-module figure (two 64 GB 192-bit
// LPCAMM2 modules per node, 384-bit total); DDR5 is the repo's §3.7 dual-slot
// DDR5-5600 baseline (~90 GB/s); the LPDDR5/5X rows pair the repo's RTL
// controller profiles (CAS 16 / CAS 14, see AGENTS.md) with published-typical
// x32 rates; HBM3E and GDDR6 rows are aggregate-class figures for the
// latency/capacity contrast. All are characterized model inputs.
func DRAMTypes() []DRAMSpec {
	return []DRAMSpec{
		{Name: "LPDDR6 (reference)", PerNodeGBps: 512, LatencyNS: 18, RefreshPct: 0.02,
			Note: "paper §2.4 node: 2x64 GB 192-bit LPCAMM2 modules (384-bit, ~512 GB/s)"},
		{Name: "LPDDR5X", PerNodeGBps: 68, LatencyNS: 15, RefreshPct: 0.02,
			Note: "published-typical x32 @ 8533 MT/s; repo RTL profile CAS 14"},
		{Name: "LPDDR5", PerNodeGBps: 51, LatencyNS: 20, RefreshPct: 0.02,
			Note: "published-typical x32 @ 6400 MT/s; repo RTL profile CAS 16"},
		{Name: "DDR5-5600 (baseline)", PerNodeGBps: 90, LatencyNS: 16, RefreshPct: 0.02,
			Note: "repo §3.7 node baseline: dual-slot DDR5-5600 (~90 GB/s)"},
		{Name: "HBM3E (H100-class stack)", PerNodeGBps: 3350, LatencyNS: 100, RefreshPct: 0.01,
			Note: "per-GPU aggregate class; ~100 ns read latency is the well-known HBM axis"},
		{Name: "GDDR6 (16-chip module)", PerNodeGBps: 576, LatencyNS: 50, RefreshPct: 0.01,
			Note: "consumer-class contrast"},
	}
}

// DRAMAnalysis is the DRAM-bound estimate for one memory class on the
// reference chassis, computed against the fabric transport anchors.
type DRAMAnalysis struct {
	Spec  DRAMSpec `json:"spec"`
	Point struct {
		ChassisNodes     int     `json:"chassis_nodes"`
		ModelLayers      int     `json:"model_layers"`
		DispatchesPerTok float64 `json:"dispatches_per_token"`
		PayloadBytes     int     `json:"payload_bytes"`
		FabricAnchor     float64 `json:"fabric_anchor_tok_sec"` // conservative alpha=7/8 anchor
	} `json:"reference"`

	AggregateGBps   float64 `json:"aggregate_gbps"`    // PerNodeGBps x chassis nodes
	BandTokPSec     float64 `json:"bandwidth_tok_sec"` // DRAM-bandwidth-bound tokens/s
	SerialTokPSec   float64 `json:"serial_tok_sec"`    // serial memory-latency floor (tokens/s)
	MemoryTokPSec   float64 `json:"memory_tok_sec"`    // min(bandwidth, serial) -- DRAM-imposed ceiling
	MeasuredTokPSec float64 `json:"measured_tok_sec"`  // measured reference-chassis (8x8x8, 32-B) fabric rate
	Headroom        float64 `json:"headroom_x"`        // MemoryTokPSec / FabricAnchor; >1 = fabric binds
	BoundBy         string  `json:"bound_by"`          // which term binds at the fabric anchor
}

// AnalyzeDRAM evaluates every memory class against the paper's reference
// chassis and the fabric transport anchors.
//
//   - BandTokPSec: DRAM bandwidth alone could sustain
//     aggregate_BW*(1-refresh) / (270 dispatches/token x dispatch bytes)
//     tokens/s. The aggregate chassis bandwidth (262 TB/s at LPDDR6) swamps
//     the ~10 KB of traffic a token generates, so bandwidth never binds.
//   - SerialTokPSec: a strict floor that charges each of the ModelLayers
//     decode layers one DRAM read-to-first-data wait -- 1/(layers x read
//     latency). Compute, queueing, and the softmax round trip are excluded;
//     real weight-streaming reads are pipelined across the 32 sub-channels
//     (Paper §2.16), so this is the worst case, not the typical read.
//   - MemoryTokPSec = min(bandwidth, serial); Headroom = MemoryTokPSec / the
//     conservative fabric anchor. Headroom > 1 means the fabric transport,
//     not the memory class, sets the token-rate ceiling at the honest alpha
//     = 7/8 sizing; the measured reference-chassis rate (MeasuredTokPSec,
//     8x8x8/32-B sweep point) is shown for contrast at the optimistic
//     layer-local corner.
func AnalyzeDRAM(specs []DRAMSpec, ref ReferenceParams, measuredTokPSec float64) []DRAMAnalysis {
	out := make([]DRAMAnalysis, 0, len(specs))
	for _, s := range specs {
		agg := s.PerNodeGBps * float64(ref.ChassisNodes)
		eff := agg * (1 - s.RefreshPct)
		bytesPerTok := ref.DispatchesPerTok * float64(ref.PayloadBytes+wireFramingBytes)
		bandTok := eff * 1e9 / bytesPerTok
		serialTok := 1e9 / (float64(ref.ModelLayers) * s.LatencyNS)
		memTok := bandTok
		bound := "bandwidth"
		if serialTok < memTok {
			memTok = serialTok
			bound = "serial read latency"
		}
		a := DRAMAnalysis{Spec: s, AggregateGBps: agg, BandTokPSec: bandTok, SerialTokPSec: serialTok,
			MemoryTokPSec: memTok, MeasuredTokPSec: measuredTokPSec}
		a.Point.ChassisNodes = ref.ChassisNodes
		a.Point.ModelLayers = ref.ModelLayers
		a.Point.DispatchesPerTok = ref.DispatchesPerTok
		a.Point.PayloadBytes = ref.PayloadBytes
		a.Point.FabricAnchor = ref.FabricTokPSec
		if ref.FabricTokPSec > 0 {
			a.Headroom = memTok / ref.FabricTokPSec
		}
		if a.Headroom >= 1 {
			a.BoundBy = "fabric transport (memory " + bound + " headroom " +
				fmt.Sprintf("%.1f", a.Headroom) + "x at the alpha=7/8 anchor)"
		} else {
			a.BoundBy = "memory " + bound
		}
		out = append(out, a)
	}
	return out
}

// referenceFabricTokPSec is the measured fabric-bound token rate for the
// reference chassis: the 512-node (8x8x8) point with a 32-byte token-class
// payload, falling back to the best sweep point if that corner is absent.
func referenceFabricTokPSec(pts []BenchmarkPoint) float64 {
	best := 0.0
	for i := range pts {
		if pts[i].Dims == (Dims{Layers: 8, Bx: 8, By: 8}) && pts[i].PayloadBytes == 32 {
			best = pts[i].TokensPerSec
		}
	}
	if best > 0 {
		return best
	}
	for i := range pts {
		if pts[i].TokensPerSec > best {
			best = pts[i].TokensPerSec
		}
	}
	return best
}

// BenchmarkReport is the combined measured + analytic report.
type BenchmarkReport struct {
	Points         []BenchmarkPoint  `json:"points"`
	Cost           []CostModelRow    `json:"cost_model"`
	DRAM           []DRAMAnalysis    `json:"dram_estimate"`
	Energy         []EnergyAnalysis  `json:"energy_estimate"`
	MemoryChannels []MemChannelRow   `json:"memory_channels"`
	WeightFormats  []WeightFormatRow `json:"weight_formats"`
}

// Render prints a human-readable benchmark report.
func (r *BenchmarkReport) Render() string {
	var sb strings.Builder
	sb.WriteString("=== Fabric benchmark (machine-checked, cycle-exact vvp) ===\n")
	sb.WriteString(fmt.Sprintf("%-14s %-6s %-9s %-8s %-8s %-8s %-10s %-14s %-14s\n",
		"chassis", "nodes", "payload", "pkts", "bytes/cyc", "lat mean", "pass",
		"~BW(GB/s)*", "~tok/s**"))
	for _, p := range r.Points {
		sb.WriteString(fmt.Sprintf("%-14s %-6d %-9d %-8d %-8.2f %-8d %-10v %-14.1f %-14.0f\n",
			p.Dims.String(), p.Nodes, p.PayloadBytes, p.Packets, p.BytesPerCycle,
			p.LatencyMean, p.Pass, p.BandwidthGBpsSilicon, p.TokensPerSec))
	}
	sb.WriteString("  * silicon-equivalent CHASSIS aggregate bandwidth (1 GHz x 128-bit links, cycle-exact\n")
	sb.WriteString("    fabric over parallel layer slices; per-node serialized in vvp at 100 MHz).\n")
	sb.WriteString(fmt.Sprintf("  ** model-level tokens/s = dispatches/s / %g dispatches/token (Paper §2.6, analytic).\n", DispatchesPerToken))
	sb.WriteString("\n=== Cost / TCO model (paper projections + vendor claims, none measured here) ===\n")
	sb.WriteString(fmt.Sprintf("%-42s %-40s %-26s %-18s %-34s %-20s %s\n",
		"system", "capacity", "aggregate BW", "power", "cost (USD)", "$/GB", "model flexibility"))
	for _, c := range r.Cost {
		sb.WriteString(fmt.Sprintf("%-42s %-40s %-26s %-18s %-34s %-20s %s\n",
			c.System, c.Capacity, c.Aggregate, c.Power, c.CostUSD, c.CostPerGB, c.ModelFlex))
	}
	sb.WriteString("\n=== Weight-format capacity (analytic: bits/weight x node 128 GB / chassis 64 TB) ===\n")
	sb.WriteString(fmt.Sprintf("%-26s %-13s %-18s %-20s %s\n",
		"weight format", "bits/weight", "weights/node (G)", "weights/chassis (T)", "note"))
	for _, w := range r.WeightFormats {
		sb.WriteString(fmt.Sprintf("%-26s %-13.2f %-18.0f %-20.0f %s\n",
			w.Format, w.BitsPerWt, w.WtPerNodeG, w.WtPerChassisT, w.Note))
	}
	sb.WriteString("  weights-only capacity (KV cache / activations budgeted separately, Paper §2.7); the\n")
	sb.WriteString("  ternary row is the BitNet b1.58 encoding of Paper §3.6 -- ~10x the BF16 parameter count.\n")
	sb.WriteString("\n=== DRAM latency / bandwidth estimate (characterized model inputs, none measured) ===\n")
	sb.WriteString(fmt.Sprintf("%-26s %-11s %-11s %-10s %-14s %-14s %-13s %-13s %s\n",
		"memory class", "node BW", "read lat", "aggregate", "BW-bound", "serial-floor", "fabric(7/8)", "measured", "headroom"))
	sb.WriteString(fmt.Sprintf("%-26s %-11s %-11s %-10s %-14s %-14s %-13s %-13s %s\n",
		"", "(GB/s)", "(ns)", "(TB/s)", "tok/s", "tok/s", "anchor", "peak", "(x)"))
	for _, d := range r.DRAM {
		sb.WriteString(fmt.Sprintf("%-26s %-11.0f %-11.0f %-10.2f %-14.0f %-14.0f %-13.0f %-13.0f %-7.1f %s\n",
			d.Spec.Name, d.Spec.PerNodeGBps, d.Spec.LatencyNS, d.AggregateGBps/1000,
			d.BandTokPSec, d.SerialTokPSec, d.Point.FabricAnchor, d.MeasuredTokPSec, d.Headroom, d.BoundBy))
	}
	sb.WriteString("  BW-bound = chassis aggregate BW x (1-refresh) / (270 dispatches/token x dispatch bytes);\n")
	sb.WriteString("  serial-floor = 1/(30 decode layers x read latency) -- strict worst case: real streaming\n")
	sb.WriteString("  reads pipeline across 32 sub-channels (Paper Sec 2.16); fabric(7/8) anchor = the honest\n")
	sb.WriteString("  alpha=7/8 cross-layer sizing (Sec 2.8, ~1.1M tok/s); measured = reference chassis\n")
	sb.WriteString("  sweep point (8x8x8, 32-B payload);\n")
	sb.WriteString("  headroom = min(bandwidth, serial)/anchor -> >1 means the fabric, not the memory class,\n")
	sb.WriteString("  sets the token-rate ceiling (below the optimistic layer-local corner).\n")
	sb.WriteString(r.RenderEnergy())
	return sb.String()
}

// WriteBenchmarkCSV writes the measured sweep points to CSV.
func WriteBenchmarkCSV(path string, pts []BenchmarkPoint) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	w := csv.NewWriter(f)
	defer w.Flush()
	if err := w.Write([]string{"chassis", "nodes", "payload_bytes", "flits",
		"wire_bytes", "dma_bytes", "packets", "activations", "worst_span_cyc",
		"bytes_per_cycle", "latency_min", "latency_mean", "latency_max", "pass",
		"bw_gbps_silicon", "dispatches_per_sec", "tokens_per_sec"}); err != nil {
		return err
	}
	for _, p := range pts {
		row := []string{
			p.Dims.String(), strconv.Itoa(p.Nodes), strconv.Itoa(p.PayloadBytes),
			strconv.Itoa(p.Flits), strconv.Itoa(p.WireBytes), strconv.Itoa(p.DmaBytes),
			strconv.Itoa(p.Packets), strconv.Itoa(p.Activations), strconv.Itoa(p.WorstSpanCyc),
			fmt.Sprintf("%.3f", p.BytesPerCycle), strconv.Itoa(p.LatencyMin),
			strconv.Itoa(p.LatencyMean), strconv.Itoa(p.LatencyMax), strconv.FormatBool(p.Pass),
			fmt.Sprintf("%.2f", p.BandwidthGBpsSilicon), fmt.Sprintf("%.1f", p.DispatchesPerSec),
			fmt.Sprintf("%.0f", p.TokensPerSec),
		}
		if err := w.Write(row); err != nil {
			return err
		}
	}
	return nil
}

// WriteBenchmarkJSON writes the full report to JSON.
func WriteBenchmarkJSON(path string, r *BenchmarkReport) error {
	data, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}

// RunBenchmark runs the sweep, prints the report, and (if outDir != "") exports.
func RunBenchmark(cfg BenchmarkConfig, outDir string) (bool, string) {
	pts, ok := RunBenchmarkSweep(cfg)
	ref := DefaultReferenceParams()
	rep := &BenchmarkReport{Points: pts, Cost: CostModel(), WeightFormats: WeightFormatSpectrum()}
	rep.DRAM = AnalyzeDRAM(DRAMTypes(), ref, referenceFabricTokPSec(pts))
	rep.Energy = AnalyzeSweepEnergy(pts, ref, DefaultEnergyParams())
	rep.MemoryChannels = AnalyzeMemoryChannels(PerNodeChannelGBps, ref.ChassisNodes, 2, DefaultMemChannelCounts())
	out := rep.Render()
	if outDir != "" {
		_ = os.MkdirAll(outDir, 0o755)
		if err := WriteBenchmarkCSV(filepath.Join(outDir, "pnm_benchmark.csv"), pts); err != nil {
			return false, out + "\nbenchmark export error: " + err.Error()
		}
		if err := WriteBenchmarkJSON(filepath.Join(outDir, "pnm_benchmark.json"), rep); err != nil {
			return false, out + "\nbenchmark export error: " + err.Error()
		}
		out += fmt.Sprintf("\nwrote %s and %s\n",
			filepath.Join(outDir, "pnm_benchmark.csv"), filepath.Join(outDir, "pnm_benchmark.json"))
	}
	return ok, out
}

// SortedPoints removed: sweep already emits points in deterministic
// (dims, payload) order.
