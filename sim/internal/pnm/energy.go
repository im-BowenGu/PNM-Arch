package pnm

// energy.go — the node-network energy model and the per-node multi-channel
// memory model.
//
// Two coupled questions the paper's architecture raises:
//
//  1. Multi-channel memory.  Every compute node is paired with two 64 GB
//     192-bit LPCAMM2/LPDDR6 modules (128 GB total, the reference packaging).
//     Each module is eight 24-bit LPDDR6 channels = sixteen 12-bit
//     sub-channels, so a node is sixteen channels / thirty-two sub-channels at
//     ~512 GB/s.  Word-interleaving the subsystem across C channels multiplies
//     the node's (hence the request's) memory bandwidth by C while leaving the
//     per-channel read latency unchanged (HDL/core/node_mem.v; node.v ingest
//     width MEM_CHAN).  MemoryChannelRows quantify the scaling.
//
//  2. Node-network energy.  A flit crosses the NoB/spine through flit_gate /
//     xy_turn / lxy_repeater / vc_merge repeater cells.  The network energy per
//     token is (dispatches/token) x (mean NoB hops) x (per-hop repeater
//     energy), which scales with chassising but not with the payload-dependent
//     link model.  NodeNetworkEnergy adds it to node/router/spine/PSU power to
//     give total chassis power and the network's share of it.
//
// Every figure is a characterized model input (the repo's power_rails.v cell
// budget or a paper parameter), clearly labelled; none is a silicon
// measurement.

import (
	"fmt"
	"strings"
)

// EnergyParams bundles the power/energy model inputs.
type EnergyParams struct {
	// Per-hop, per-flit repeater energy (pJ): one flit_gate/xy_turn/lxy
	// activation.  Matches power_rails.v LINK_PJ (9.5 nJ... quoted pJ/cycle).
	RepeaterPJPerHop float64
	// SerDes energy per byte per hop (pJ).
	SerdesPJPerByteHop float64

	// Node rail budgets (W), from power_rails.v per-cycle pJ / 10.
	NodeIdleW float64
	NodeMacW  float64
	NodeDramW float64

	// Shared chassis infrastructure (W).
	RouterW float64
	SpineW  float64

	// Power-supply / thermal efficiency (0..1). Raw rail power is divided by
	// this to get wall power.
	PsuEfficiency float64
}

// DefaultEnergyParams returns the repo's reference energy model: node rails
// from power_rails.v (idle 1.15 W, MAC +8.7 W, DRAM +3.0 W), repeater energy
// from LINK_PJ, and a 92%-efficient supply (matching chassis_power's ETA_PCT).
func DefaultEnergyParams() EnergyParams {
	return EnergyParams{
		RepeaterPJPerHop:   9500, // power_rails.v LINK_PJ
		SerdesPJPerByteHop: 0.5,
		NodeIdleW:          1.15, // (CORE_IDLE 3000 + IO_IDLE 500 + DRAM_BG 8000)/10 mW
		NodeMacW:           8.7,  // MAC_PJ 87000/10 mW
		NodeDramW:          3.0,  // ~DRAM_RD_PJ 40000/10 mW
		RouterW:            10.0, // chassis_power ROUTER_MW
		SpineW:             72.0, // chassis_power SPINE_MW
		PsuEfficiency:      0.92,
	}
}

// meanAbsDiff is E|X-Y| for X,Y uniform on {0..n-1}: (n^2-1)/(3n).  It is the
// expected dimension-order hop count along one axis of an n-node extent.
func meanAbsDiff(n int) float64 {
	if n <= 1 {
		return 0
	}
	return float64(n*n-1) / (3 * float64(n))
}

// AvgNoBHops is the expected number of NoB/spine repeater hops a uniformly
// addressed flit traverses in the chassis: the spine descends to the target
// layer, then dimension-order X/Y crosses that board.
func AvgNoBHops(dims Dims) float64 {
	return meanAbsDiff(dims.Layers) + meanAbsDiff(dims.Bx) + meanAbsDiff(dims.By)
}

// EnergyAnalysis is the node-network energy budget at one token rate.
type EnergyAnalysis struct {
	Dims             Dims    `json:"dims"`
	Nodes            int     `json:"nodes"`
	TokPSec          float64 `json:"tok_per_sec"`
	AvgHops          float64 `json:"avg_hops"`
	DispatchesPerSec float64 `json:"dispatches_per_sec"`
	FlitBytes        int     `json:"flit_bytes"`

	NetworkW   float64 `json:"network_w"` // repeater + SerDes dynamic power
	NodeW      float64 `json:"node_w"`    // nodes x (idle+mac+dram)
	InfraW     float64 `json:"infra_w"`   // router + spine
	WallW      float64 `json:"wall_w"`    // (node+infra+network)/PSU, incl. thermal margin
	EnergyPJ   float64 `json:"energy_pj_per_token"`
	NetworkPct float64 `json:"network_pct"` // network share of raw rail power
}

// AnalyzeNodeNetworkEnergy computes the network/node/infra power and the
// energy per token for one chassis at a given token rate.
func AnalyzeNodeNetworkEnergy(dims Dims, tokPSec float64, payloadBytes int, p EnergyParams) EnergyAnalysis {
	nodes := dims.Layers * dims.Bx * dims.By
	hops := AvgNoBHops(dims)
	dispatches := tokPSec * DispatchesPerToken
	flitBytes := payloadBytes + wireFramingBytes

	// Network dynamic energy per dispatch (pJ): repeater hops + SerDes.
	energyPerDispatchPJ := hops * (p.RepeaterPJPerHop + float64(flitBytes)*p.SerdesPJPerByteHop)
	networkW := dispatches * energyPerDispatchPJ * 1e-12 * 1e9 / 1e9 // pJ/s -> W (1e-12 s^-1)
	networkW = dispatches * energyPerDispatchPJ / 1e12

	nodeW := float64(nodes) * (p.NodeIdleW + p.NodeMacW + p.NodeDramW)
	infraW := p.RouterW + p.SpineW
	rawW := nodeW + infraW + networkW
	wallW := rawW / p.PsuEfficiency

	netPct := 0.0
	if rawW > 0 {
		netPct = 100 * networkW / rawW
	}
	return EnergyAnalysis{
		Dims:             dims,
		Nodes:            nodes,
		TokPSec:          tokPSec,
		AvgHops:          hops,
		DispatchesPerSec: dispatches,
		FlitBytes:        flitBytes,
		NetworkW:         networkW,
		NodeW:            nodeW,
		InfraW:           infraW,
		WallW:            wallW,
		EnergyPJ:         wallW / tokPSec * 1e12,
		NetworkPct:       netPct,
	}
}

// AnalyzeSweepEnergy evaluates the node-network energy budget for every
// distinct chassis shape in a sweep, all at the same analytic token rate (the
// conservative cross-layer fabric anchor, Paper §2.8). Fixing the rate isolates
// the chassis-size effect: larger chassis add nodes and mean NoB hops, so both
// the node and the network power terms grow even at constant throughput.
func AnalyzeSweepEnergy(pts []BenchmarkPoint, ref ReferenceParams, p EnergyParams) []EnergyAnalysis {
	seen := map[Dims]bool{}
	var out []EnergyAnalysis
	for _, pt := range pts {
		if seen[pt.Dims] {
			continue
		}
		seen[pt.Dims] = true
		out = append(out, AnalyzeNodeNetworkEnergy(pt.Dims, ref.FabricTokPSec, ref.PayloadBytes, p))
	}
	return out
}

// MemChannelRow is one row of the per-node multi-channel memory scaling table.
type MemChannelRow struct {
	Channels       int     `json:"channels"`         // sub-channels
	Modules        int     `json:"modules"`          // 64 GB 192-bit modules (channels/16)
	PerChannelGBps float64 `json:"per_channel_gbps"` // 12-bit sub-channel rate
	NodeGBps       float64 `json:"node_gbps"`
	ChassisTBps    float64 `json:"chassis_tbps"`
	BytesPerBeat   int     `json:"bytes_per_beat"`
	Reference      bool    `json:"reference"` // the 128 GB dual-module config
	Note           string  `json:"note"`
}

// AnalyzeMemoryChannels scales one node's memory bandwidth with the channel
// count.  Per-channel bandwidth is unchanged; node bandwidth is
// PerChannelGBps x channels and the whole-chassis aggregate multiplies by the
// node count.  BytesPerBeat is the node_mem.v egress width in bytes (CHANNELS x
// element width) that node.v ingests per clock.  Modules = channels divided by
// the 16 sub-channels of one 64 GB 192-bit module.
func AnalyzeMemoryChannels(perChannelGBps float64, nodeCount int, elemBytes int, channels []int) []MemChannelRow {
	rows := make([]MemChannelRow, 0, len(channels))
	for _, c := range channels {
		node := perChannelGBps * float64(c)
		modules := c / SubChannelsPerModule
		note := fmt.Sprintf("node_mem %d-channel interleave", c)
		if modules == ReferenceModules {
			note += " (reference: 2x64 GB 192-bit LPCAMM2)"
		}
		rows = append(rows, MemChannelRow{
			Channels:       c,
			Modules:        modules,
			PerChannelGBps: perChannelGBps,
			NodeGBps:       node,
			ChassisTBps:    node * float64(nodeCount) / 1000,
			BytesPerBeat:   c * elemBytes,
			Reference:      modules == ReferenceModules,
			Note:           note,
		})
	}
	return rows
}

// DefaultMemChannelCounts is the channel sweep (paper §2.16 sub-channels):
// 16 = one 64 GB module, 32 = the two-module reference node, and two wider
// points for headroom.  The reference node is 32 sub-channels = ~512 GB/s.
func DefaultMemChannelCounts() []int {
	return []int{SubChannelsPerModule, 2 * SubChannelsPerModule, 4 * SubChannelsPerModule}
}

// PerNodeChannelGBps is the LPDDR6 reference divided across the paper's 16
// per-module sub-channels: the per-channel rate the multi-channel model scales
// from (256 GB/s / 16 = 16 GB/s per 12-bit sub-channel).
const PerNodeChannelGBps = 256.0 / 16.0 // 16 GB/s/sub-channel

// One 64 GB 192-bit LPCAMM2/LPDDR6 module is eight 24-bit channels = sixteen
// 12-bit sub-channels.  The reference node pairs two of them (128 GB, 384-bit,
// ~512 GB/s), so ReferenceModules = 2 and the node carries 32 sub-channels.
const (
	SubChannelsPerModule = 16
	ReferenceModules     = 2
)

// RenderEnergy prints the node-network energy and multi-channel memory tables.
func (r *BenchmarkReport) RenderEnergy() string {
	var sb strings.Builder
	sb.WriteString("\n=== Node-network energy estimate (characterized model inputs, none measured) ===\n")
	sb.WriteString(fmt.Sprintf("%-14s %-6s %-8s %-11s %-12s %-12s %-11s %-11s %-10s\n",
		"chassis", "nodes", "hops", "tok/s", "network W", "node W", "infra W", "wall W", "net %"))
	for _, e := range r.Energy {
		sb.WriteString(fmt.Sprintf("%-14s %-6d %-8.2f %-11.0f %-12.3f %-12.1f %-11.1f %-11.1f %-10.2f\n",
			e.Dims.String(), e.Nodes, e.AvgHops, e.TokPSec, e.NetworkW, e.NodeW,
			e.InfraW, e.WallW, e.NetworkPct))
	}
	sb.WriteString("  network = (270 dispatches/token) x mean NoB hops x per-hop repeater+SerDes energy;\n")
	sb.WriteString("  hops = E|layer diff| + E|dx| + E|dy| (dimension-order spine + X/Y);\n")
	sb.WriteString("  node = nodes x (idle 1.15 W + MAC 8.7 W + DRAM 3.0 W) from power_rails.v;\n")
	sb.WriteString("  wall = (node+infra+network)/0.92 (PSU); the repeater network is a small share.\n")

	sb.WriteString("\n=== Per-node multi-channel memory (node_mem.v interleave, model inputs) ===\n")
	sb.WriteString(fmt.Sprintf("%-9s %-8s %-12s %-12s %-12s %-13s %s\n",
		"channels", "modules", "per-chan", "node BW", "chassis BW", "bytes/beat", "note"))
	sb.WriteString(fmt.Sprintf("%-9s %-8s %-12s %-12s %-12s %-13s %s\n",
		"", "(64GB)", "(GB/s)", "(GB/s)", "(TB/s)", "", ""))
	for _, m := range r.MemoryChannels {
		sb.WriteString(fmt.Sprintf("%-9d %-8d %-12.1f %-12.1f %-12.2f %-13d %s\n",
			m.Channels, m.Modules, m.PerChannelGBps, m.NodeGBps, m.ChassisTBps, m.BytesPerBeat, m.Note))
	}
	sb.WriteString("  node BW = per-channel x channels; bytes/beat = channels x element width;\n")
	sb.WriteString("  one 64 GB 192-bit LPCAMM2 module = 16 sub-channels; reference node = 2 modules\n")
	sb.WriteString("  (128 GB, 384-bit, ~512 GB/s) = 32 sub-channels.\n")
	sb.WriteString("  (node.v MEM_CHAN ingest); per-channel latency is unchanged by interleaving.\n")
	return sb.String()
}
