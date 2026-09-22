// ============================================================================
// Model-driven fabric co-simulation bridge.
//
// Binds the two halves of the proof pipeline that previously had no
// connection: the host-side driver/firmware (NewDriver + Firmware.PlanInference,
// which produces the dispatch PLAN) and the cycle-exact Verilog fabric
// (RunOne, which needs a *Program of injects).  BuildModelProgram converts
// every planned dispatch record into the exact wire flit the orchestrator
// would inject, so the RTL gates actually carry the model's traffic.
//
// The fabric runs at 100 MHz byte-serial in vvp -- inherently slower than
// the 1 GHz x 128-bit physical links the paper describes (a ~160x gap) -- so
// "run the Verilog slower" is the point: a scaled-down realistic workload is
// simulated exactly, cycle by cycle, in a few seconds of wall time.
// ============================================================================

package pnm

import (
	"path/filepath"
	"fmt"
	"os"
	"runtime"
	"sort"
)

// ModelFabricConfig controls the model-driven fabric proof run.
type ModelFabricConfig struct {
	Tokens        int    // number of tokens to dispatch (default 1)
	Seed          int64  // deterministic weight/backpressure RNG seed
	UploadWeights bool   // also inject the weight-upload flits (POST phase 3)
	Groups        int    // parallel vvp slices (0 = min(layers, NumCPU))
	Replays       int    // determinism replays (2 = bit-identical log check)
	Prompt        string // tokenize this prompt and use its token bytes as payloads (empty = synthetic token)
}

// ModelFabricResult summarizes one proof run.
type ModelFabricResult struct {
	Prog          *Program
	Records       []DispatchRecord
	PlannedWFlits int // weight-upload flits injected
	PlannedDFlits int // inference dispatch flits injected
	WireBytes     int
	Dense         int
	MoE           int
	KVOffload     int
	OK            bool
}

// PromptTokenPayloads tokenizes a prompt with the model's vocabulary and
// returns count 32-byte payloads, each packing up to 16 token IDs as 2-byte
// big-endian words (wrapping for multi-token runs, zero-padded).  Returns nil
// when the prompt is empty so BuildModelProgram keeps the synthetic token.
// The payload bytes are what the gating network scores (FNV-1a over the token)
// and what the fabric delivers to the expert nodes.
func PromptTokenPayloads(drv *Driver, prompt string, count int) [][]byte {
	if prompt == "" || count < 1 {
		return nil
	}
	size := drv.Config.TextConfig.VocabSize
	if size < 1 {
		size = 1
	}
	var bpe *BPEVocab
	if tb, err := LoadBPEVocab(filepath.Join(drv.ModelDir, "tokenizer.json")); err == nil {
		bpe = tb
	}
	tokens := make([]string, size)
	for i := 0; i < size; i++ {
		tokens[i] = fmt.Sprintf("token_%d", i)
	}
	ids := NewVocabulary(tokens, bpe).Encode(prompt)
	if len(ids) == 0 {
		ids = []int{0}
	}
	out := make([][]byte, count)
	for t := 0; t < count; t++ {
		payload := make([]byte, 32)
		for w := 0; w < 16; w++ {
			id := ids[(t*16+w)%len(ids)]
			payload[2*w] = byte(id >> 8)
			payload[2*w+1] = byte(id & 0xFF)
		}
		out[t] = payload
	}
	return out
}

// BuildModelProgram runs the firmware dispatch for cfg.Tokens tokens (and,
// optionally, the Phase-3 weight upload) and returns a fabric *Program whose
// injected stream is byte-identical to the orchestrator's planned flits.
//
// The firmware must already be in the READY state (all five BootPhase calls).
// Each node's resident kernel is "dot" over a deterministic per-node weight
// vector (seeded), so the Go golden model can verify the delivered payload
// through the node MAC pipe, not just count bytes.
func BuildModelProgram(drv *Driver, fw *Firmware, cfg ModelFabricConfig) (*ModelFabricResult, error) {
	dims := drv.Dims
	nodes := AllNodes(dims.Layers, dims.Bx, dims.By)

	if cfg.Tokens < 1 {
		cfg.Tokens = 1
	}

	prog := NewProgram("model-fabric", nodes, "bounded")
	rng := NewPyRand(uint64(cfg.Seed))
	for _, n := range nodes {
		prog.BP[n] = 1 // idle fabric: no backpressure, full-speed delivery
		weights := make([]int, 16)
		for j := range weights {
			weights[j] = rng.RandRange(0, 256)
		}
		prog.ProgramNode(n, "dot", weights, 0)
	}

	res := &ModelFabricResult{Prog: prog}

	// Phase 3 optionally: push the model's weight blobs through the fabric.
	// Each command is a full wormhole flit via the standard spelling
	// (Flit(layer+1, module, 0x80, payload)); the payload is the bounded
	// deterministic sample (SizeBytes keeps the authoritative accounting).
	if cfg.UploadWeights {
		cmds, err := drv.BuildWeightCommands()
		if err != nil {
			return nil, fmt.Errorf("build weight commands: %w", err)
		}
		for _, cmd := range cmds {
			n := NodeID{L: cmd.TargetLayer, X: int(cmd.TargetModule >> 4), Y: int(cmd.TargetModule & 0x0F)}
			prog.InjectRouted(n, CTRL_COMPUTE_SPINE, cmd.Payload, false)
			res.PlannedWFlits++
		}
	}

	// Inference: N tokens through the model's dispatch plan.  Every record
	// that puts bytes on the wire (FlitBytes > 0) becomes one injected flit
	// carrying the same token payload the firmware laid into its flit.  With
	// a prompt configured the payload is the prompt's token IDs (so the
	// gating network scores real prompt traffic); otherwise it is the
	// synthetic deterministic token.
	payloads := PromptTokenPayloads(drv, cfg.Prompt, cfg.Tokens)
	for t := 0; t < cfg.Tokens; t++ {
		var token []byte
		if payloads != nil {
			token = payloads[t]
		} else {
			token = make([]byte, 32)
			for k := range token {
				token[k] = byte((t*37 + k*13 + 1) & 0xFF)
			}
		}
		records, err := fw.PlanInference(token)
		if err != nil {
			return nil, fmt.Errorf("token %d inference plan: %w", t, err)
		}
		for _, r := range records {
			if r.FlitBytes <= 0 {
				// KV load/offload bookkeeping: no wire traffic in the
				// transport proof (the KV cache lives node-side).
				if r.Phase == "kv_offload" {
					res.KVOffload++
				}
				continue
			}
			if r.Phase == "moe" {
				// Real-MoE semantics: the same hidden state (token payload)
				// multiplies per-expert weights.  The weight vector is a
				// deterministic function of the gating-selected expert index,
				// so each expert returns a distinct output on the node.
				erng := NewPyRand(uint64(cfg.Seed)*0x9E3779B97F4A7C15 + uint64(r.ExpertIdx))
				ew := make([]int, 16)
				for j := range ew {
					ew[j] = erng.RandRange(0, 256)
				}
				prog.InjectRoutedWeights(r.TargetNode, CTRL_COMPUTE_SPINE, token, ew, false)
			} else {
				prog.InjectRouted(r.TargetNode, CTRL_COMPUTE_SPINE, token, false)
			}
			res.Records = append(res.Records, r)
			if r.Phase == "moe" {
				res.MoE++
			} else {
				res.Dense++
			}
			res.PlannedDFlits++
		}
	}
	res.WireBytes = len(prog.Stream)
	return res, nil
}

// RunModelFabric runs a built model program through the actual Verilog gates
// (iverilog + vvp) and returns the ScenarioResult.  It chdirs into sim/ so
// the generated stimulus/topology/testbench files land where the harness
// expects them, matching RunCompiler.
func RunModelFabric(res *ModelFabricResult, dims Dims, cfg ModelFabricConfig) (*ScenarioResult, bool) {
	simDir := SimDir()
	if err := os.Chdir(simDir); err != nil {
		fmt.Fprintf(os.Stderr, "chdir %s: %v\n", simDir, err)
		return nil, false
	}
	groups := cfg.Groups
	if groups == 0 {
		groups = min(dims.Layers, runtime.NumCPU())
	}
	replays := cfg.Replays
	if replays == 0 {
		replays = 1
	}
	nodes := AllNodes(dims.Layers, dims.Bx, dims.By)
	return RunOne(res.Prog, nodes, dims, groups, replays)
}

// ModelFabricSummary prints the dispatch-plan accounting for the proof run.
func ModelFabricSummary(res *ModelFabricResult, cfg ModelFabricConfig, fw *Firmware) {
	byNode := map[NodeID]int{}
	for _, r := range res.Records {
		byNode[r.TargetNode]++
	}
	var dests []NodeID
	for n := range byNode {
		dests = append(dests, n)
	}
	sort.Slice(dests, func(i, j int) bool {
		a, b := dests[i], dests[j]
		if a.L != b.L {
			return a.L < b.L
		}
		if a.X != b.X {
			return a.X < b.X
		}
		return a.Y < b.Y
	})
	fmt.Printf("  tokens: %d, dispatch flits: %d (%d dense + %d MoE), kv_offload records: %d\n",
		cfg.Tokens, res.PlannedDFlits, res.Dense, res.MoE, res.KVOffload)
	if cfg.UploadWeights {
		fmt.Printf("  weight-upload flits: %d\n", res.PlannedWFlits)
	}
	fmt.Printf("  active nodes: %d of %d\n", len(dests), len(res.Prog.Manifest))
	for _, n := range dests {
		fmt.Printf("    (%d,%d,%d): %d flit(s)\n", n.L, n.X, n.Y, byNode[n])
	}
	fmt.Printf("  total wire bytes: %d\n", res.WireBytes)
}
