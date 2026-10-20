package pnm

// gated_fabric.go — node-network dispatch of the Gating ASIC's routing decisions.
//
// pnmgate's ASIC produces the real Gemma router top-k per gated layer (see
// gating_harness.go).  This file turns those decisions into wire flits — one
// per selected expert — and injects them into the node-network fabric RTL
// (hfr/flit_gate/xy_turn/node_eject/... under HDL/) so the token actually
// travels the X/Y grid to the expert node.  RunOne then verifies byte-exact
// delivery and per-node kernel correctness under iverilog/vvp.  The expert
// math itself stays on the CPU in the Go engine; the network is the transport
// proof for the ASIC's routing decision.

import (
	"fmt"
	"sort"
)

// GatedFabricConfig configures the post-routing node-network dispatch proof.
type GatedFabricConfig struct {
	Dims    Dims  // chassis shape the experts are mapped onto
	Seed    int64 // deterministic per-expert weight seed
	Groups  int   // parallel vvp slices (0 = min(layers, NumCPU))
	Replays int   // determinism replays (2 = bit-identical log check)
}

// ExpertNode maps expert `expert` of `layer` onto a chassis node: experts are
// spread X-major across the board's bx x by node grid.
func ExpertNode(layer, expert, bx, by int) NodeID {
	if bx < 1 {
		bx = 1
	}
	if by < 1 {
		by = 1
	}
	x := expert % bx
	y := (expert / bx) % by
	return NodeID{L: layer, X: x, Y: y}
}

// PromptPayload packs a prompt's BPE ids into the 32-byte node-dispatch
// payload used by the fabric proof (up to 16 ids as 2-byte big-endian words,
// wrapping; zero-padded) — the same wire payload BuildModelProgram carries.
func PromptPayload(vocab *BPEVocab, prompt string) []byte {
	payload := make([]byte, 32)
	var ids []int
	if vocab != nil {
		if got, err := vocab.Encode(prompt); err == nil {
			ids = got
		}
	}
	if len(ids) == 0 {
		ids = []int{0}
	}
	for w := 0; w < 16; w++ {
		id := ids[w%len(ids)]
		payload[2*w] = byte(id >> 8)
		payload[2*w+1] = byte(id & 0xFF)
	}
	return payload
}

// BuildGatedFabricProgram converts the ASIC's per-layer top-k into a fabric
// *Program: one routed flit per selected expert, carrying the token payload
// and an expert-seeded resident weight vector (so distinct experts produce
// distinct, verifiable node outputs).  decisions maps layer -> selected
// expert ids.  Layers outside the chassis shape are dropped.
func BuildGatedFabricProgram(decisions map[int][]int, payload []byte, cfg GatedFabricConfig) (*ModelFabricResult, error) {
	dims := cfg.Dims
	if dims.Layers < 1 {
		dims.Layers = 1
	}
	if dims.Bx < 1 {
		dims.Bx = 1
	}
	if dims.By < 1 {
		dims.By = 1
	}
	nodes := AllNodes(dims.Layers, dims.Bx, dims.By)
	if len(nodes) == 0 {
		return nil, fmt.Errorf("gated fabric: empty chassis %s", dims)
	}
	prog := NewProgram("pnmgate-fabric", nodes, "bounded")
	for _, n := range nodes {
		prog.BP[n] = 1 // idle fabric: no backpressure, full-speed delivery
	}
	res := &ModelFabricResult{Prog: prog}

	ls := make([]int, 0, len(decisions))
	for l := range decisions {
		ls = append(ls, l)
	}
	sort.Ints(ls)
	for _, l := range ls {
		if l < 0 || l >= dims.Layers {
			continue
		}
		seen := map[int]bool{}
		for _, e := range decisions[l] {
			if e < 0 || seen[e] {
				continue
			}
			seen[e] = true
			n := ExpertNode(l, e, dims.Bx, dims.By)
			erng := NewPyRand(uint64(cfg.Seed)*0x9E3779B97F4A7C15 + uint64(l)<<40 + uint64(e))
			ew := make([]int, 16)
			for j := range ew {
				ew[j] = erng.RandRange(0, 256)
			}
			prog.InjectRoutedWeights(n, CTRL_COMPUTE_SPINE, payload, ew, false)
			res.Records = append(res.Records, DispatchRecord{
				Layer:      l,
				Phase:      "moe",
				TargetNode: n,
				ExpertIdx:  e,
				FlitBytes:  len(payload),
				CUType:     CUTypeBF16FMA,
			})
			res.MoE++
			res.PlannedDFlits++
		}
	}
	res.WireBytes = len(prog.Stream)
	return res, nil
}

// RunGatedFabric executes a built gated-fabric program through the real HDL
// gates (iverilog + vvp) and verifies byte-exact delivery to the expert nodes.
func RunGatedFabric(res *ModelFabricResult, cfg GatedFabricConfig) (*ScenarioResult, bool) {
	return RunModelFabric(res, cfg.Dims, ModelFabricConfig{
		Groups:  cfg.Groups,
		Replays: cfg.Replays,
	})
}
