// run-tasks: a small task suite for the simulated LLM system.
//
// The LLM client (LLMClient over the firmware dispatch plan) executes a set
// of simple tasks — greedy completion, sampled completion, regex-constrained
// structured generation, continuous batching, and speculative decoding —
// capturing each task's generated output and benchmarking the run (tokens,
// dispatches, KV ops, wall time).  An optional gate-level section replays the
// completion prompt's tokens through the cycle-exact Verilog fabric
// (iverilog + vvp) for the hardware-side benchmark: wire bytes, sustained
// bytes/cycle, per-token cycle cost, and per-packet latency.
//
//	go run ./cmd/pnmc run-tasks examples/gemma4_test_synthetic -l 2 -x 2 -y 2
//	go run ./cmd/pnmc run-tasks examples/gemma4_test_synthetic -fabric 4 -max-tokens 12

package main

import (
	"flag"
	"fmt"
	"os"
	"regexp"
	"strings"
	"time"

	"pnm/sim/internal/pnm"
)

type taskBench struct {
	name   string
	detail string
	output string
	tokens int
	ok     bool
	err    error
	dur    time.Duration
	d      pnm.InferenceStats // per-task stat delta
}

func (b *taskBench) report() {
	status := "OK"
	if !b.ok {
		status = "FAILED"
	}
	fmt.Printf("--- Task: %s [%s] ---\n", b.name, status)
	if b.detail != "" {
		fmt.Printf("  %s\n", b.detail)
	}
	out := b.output
	if out == "" {
		out = "(no output)"
	}
	fmt.Printf("  output (%d tokens): %s\n", b.tokens, out)
	if b.err != nil {
		fmt.Printf("  error: %v\n", b.err)
	}
	tps := 0.0
	if b.dur > 0 && b.tokens > 0 {
		tps = float64(b.tokens) / b.dur.Seconds()
	}
	fmt.Printf("  bench: %d dispatches (dense %d, MoE %d, flash %d) | KV store %d / load %d / evict %d | %d flits | wall %v | %.0f tok/s (host plan rate)\n",
		b.d.TotalDispatches, b.d.DenseDispatches, b.d.MoEDispatches, b.d.FlashAttnDispatches,
		b.d.KVStoreOps, b.d.KVLoadOps, b.d.KVEvictions, b.d.TotalFlits, b.dur.Round(time.Millisecond), tps)
	fmt.Println()
}

// runTask snapshots the client stats, runs fn, and returns the benchmark.
func runTask(name, detail string, client *pnm.LLMClient, fn func() (string, int, bool, error)) *taskBench {
	before := client.Stats // plain int fields: value copy
	start := time.Now()
	out, n, ok, err := fn()
	b := &taskBench{
		name: name, detail: detail, output: out, tokens: n, ok: ok, err: err,
		dur: time.Since(start),
	}
	b.d.TotalDispatches = client.Stats.TotalDispatches - before.TotalDispatches
	b.d.DenseDispatches = client.Stats.DenseDispatches - before.DenseDispatches
	b.d.MoEDispatches = client.Stats.MoEDispatches - before.MoEDispatches
	b.d.FlashAttnDispatches = client.Stats.FlashAttnDispatches - before.FlashAttnDispatches
	b.d.KVStoreOps = client.Stats.KVStoreOps - before.KVStoreOps
	b.d.KVLoadOps = client.Stats.KVLoadOps - before.KVLoadOps
	b.d.KVEvictions = client.Stats.KVEvictions - before.KVEvictions
	b.d.TotalFlits = client.Stats.TotalFlits - before.TotalFlits
	b.d.BatchSchedules = client.Stats.BatchSchedules - before.BatchSchedules
	b.d.SpeculativeDrafts = client.Stats.SpeculativeDrafts - before.SpeculativeDrafts
	b.d.SpeculativeAccepts = client.Stats.SpeculativeAccepts - before.SpeculativeAccepts
	b.d.StructuredTokens = client.Stats.StructuredTokens - before.StructuredTokens
	return b
}

var serialPattern = regexp.MustCompile(`(^|\s)token_[0-9]{4}(\s|$)`)
var tokenShaped = regexp.MustCompile(`^token_[0-9]+$`)

func runTasks(argv []string) int {
	fs := flag.NewFlagSet("run-tasks", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	layers := fs.Int("l", 2, "spine layers / boards")
	fs.IntVar(layers, "layers", 2, "spine layers / boards")
	bx := fs.Int("x", 2, "X columns per board")
	fs.IntVar(bx, "board-x", 2, "X columns per board")
	by := fs.Int("y", 2, "Y rows per board")
	fs.IntVar(by, "board-y", 2, "Y rows per board")
	maxTokens := fs.Int("max-tokens", 12, "max tokens generated per task")
	fabricTokens := fs.Int("fabric", 4, "gate-level fabric benchmark: tokens through the Verilog gates (0 = skip)")
	groups := fs.Int("groups", 0, "parallel vvp slices (default: min(layers, cpus))")
	seed := fs.Int64("seed", 0xC0FFEE, "RNG seed")
	cpuProf := fs.String("cpuprofile", "", "write CPU profile to file")
	memProf := fs.String("memprofile", "", "write heap profile to file")
	modelDir, argv := splitProgram(argv)
	if err := fs.Parse(argv); err != nil {
		return 2
	}
	if modelDir == "" {
		fmt.Fprintln(os.Stderr, "usage: pnmc run-tasks <model_dir> [-l layers] [-x bx] [-y by] [-max-tokens N] [-fabric N]")
		fmt.Fprintln(os.Stderr, "  Runs the simulated LLM (firmware dispatch plan + sampling) through a set of")
		fmt.Fprintln(os.Stderr, "  simple tasks, captures each task's output, and benchmarks the run; the")
		fmt.Fprintln(os.Stderr, "  -fabric N tokens also run through the cycle-exact Verilog gates.")
		return 2
	}
	stopCPU := startCPUProfile(*cpuProf)
	defer writeHeapProfile(*memProf)
	defer stopCPU()

	dims := pnm.Dims{Layers: *layers, Bx: *bx, By: *by}
	fmt.Printf("=== PNM Simulated LLM Task Suite ===\n")
	fmt.Printf("Model: %s | Chassis: %dx%dx%d = %d nodes | max tokens/task: %d\n\n",
		modelDir, dims.Layers, dims.Bx, dims.By, dims.Layers*dims.Bx*dims.By, *maxTokens)

	client, err := pnm.NewLLMClient(pnm.LLMConfig{
		ModelDir:       modelDir,
		Dims:           dims,
		MaxTokens:      *maxTokens,
		Temperature:    0,
		DataType:       pnm.CUTypeBF16FMA,
		EnableBatching: true,
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "llm client: %v\n", err)
		return 1
	}
	tc := client.Driver.Config.TextConfig
	fmt.Printf("Model: %d layers, hidden=%d, experts=%d (top-%d active), vocab=%d\n\n",
		tc.NumHiddenLayers, tc.HiddenSize, tc.NumExperts, tc.TopKExperts, tc.VocabSize)

	const completionPrompt = "the cat sat on the"
	var results []*taskBench

	// Task 1: greedy completion (temperature 0 -> argmax).
	client.Config.Temperature = 0
	client.Config.TopP = 0
	var greedy []int
	results = append(results, runTask("greedy completion", fmt.Sprintf("prompt: %q (temperature 0, greedy argmax)", completionPrompt), client, func() (string, int, bool, error) {
		tokens, err := client.Generate(completionPrompt)
		greedy = tokens
		return client.Vocab.Decode(tokens), len(tokens), err == nil, err
	}))

	// Task 2: sampled completion (temperature 1.0 + nucleus 0.9).
	client.Config.Temperature = 1.0
	client.Config.TopP = 0.9
	results = append(results, runTask("sampled completion", fmt.Sprintf("prompt: %q (temperature 1.0, nucleus 0.9)", completionPrompt), client, func() (string, int, bool, error) {
		tokens, err := client.Generate(completionPrompt)
		differs := len(tokens) != len(greedy)
		if !differs {
			for i := range tokens {
				if tokens[i] != greedy[i] {
					differs = true
					break
				}
			}
		}
		if err == nil && !differs {
			fmt.Printf("  note: sampled output identical to greedy (possible for argmax-dominated logits)\n")
		}
		return client.Vocab.Decode(tokens), len(tokens), err == nil, err
	}))
	client.Config.Temperature = 0
	client.Config.TopP = 0

	// Task 3: structured generation (regex-constrained serial code).
	const structuredPattern = "[t][o][k][e][n]_[0-9][0-9][0-9][0-9]"
	results = append(results, runTask("structured generation", fmt.Sprintf("prompt: %q, pattern: %s (FSM-masked sampling)", "issue a four digit token id", structuredPattern), client, func() (string, int, bool, error) {
		tokens, err := client.GenerateStructured("issue a four digit token id", structuredPattern)
		text := client.Vocab.Decode(tokens)
		ok := err == nil && serialPattern.MatchString(" "+text+" ")
		for _, tok := range tokens {
			if s, found := client.Vocab.IDToToken[tok]; found && !tokenShaped.MatchString(s) {
				ok = false
			}
		}
		if ok {
			fmt.Printf("  pattern conformance: output matches token_[0-9]{4}\n")
		} else if err == nil {
			fmt.Printf("  pattern conformance: VIOLATED (soft FSM enforcement ended generation early)\n")
		}
		return text, len(tokens), ok, err
	}))

	// Task 4: continuous batching across three prompts.
	batchPrompts := []string{"alpha beta gamma", "one two three", "the cat sat on the mat"}
	results = append(results, runTask("continuous batching", fmt.Sprintf("prompts: %v (batched decode)", batchPrompts), client, func() (string, int, bool, error) {
		batch, err := client.GenerateWithBatching(batchPrompts)
		if err != nil {
			return "", 0, false, err
		}
		var parts []string
		total := 0
		for i, toks := range batch {
			total += len(toks)
			parts = append(parts, fmt.Sprintf("req%d: %s", i, client.Vocab.Decode(toks)))
		}
		return strings.Join(parts, " | "), total, len(batch) == len(batchPrompts), nil
	}))

	// Task 5: speculative decoding (draft + accept-all verify).
	results = append(results, runTask("speculative decoding", fmt.Sprintf("prompt: %q (draft + verify)", "once upon a time"), client, func() (string, int, bool, error) {
		tokens, err := client.GenerateWithSpeculative("once upon a time")
		return client.Vocab.Decode(tokens), len(tokens), err == nil, err
	}))

	failed := 0
	for _, b := range results {
		b.report()
		if !b.ok {
			failed++
		}
	}

	// Suite-level benchmark summary.
	var totalTok, totalDisp int
	var totalWall time.Duration
	for _, b := range results {
		totalTok += b.tokens
		totalDisp += b.d.TotalDispatches
		totalWall += b.dur
	}
	fmt.Println("--- Suite Benchmark (host-side simulation) ---")
	if totalTok > 0 {
		fmt.Printf("  tasks: %d (%d failed) | tokens: %d | dispatches: %d | %.0f dispatches/token | wall %v | %.0f tok/s aggregate plan rate\n",
			len(results), failed, totalTok, totalDisp, float64(totalDisp)/float64(totalTok),
			totalWall.Round(time.Millisecond), float64(totalTok)/totalWall.Seconds())
	}
	for cu, count := range client.Driver.MC.ComputeUnitSummary() {
		fmt.Printf("  compute units: %-15s %d nodes\n", cu, count)
	}
	fmt.Println()

	// Gate-level fabric benchmark: replay the completion prompt's tokens
	// through the cycle-exact Verilog fabric.
	if *fabricTokens > 0 {
		fmt.Printf("--- Gate-Level Fabric Benchmark (%d token(s) through iverilog/vvp) ---\n", *fabricTokens)
		fcfg := pnm.ModelFabricConfig{
			Tokens:  *fabricTokens,
			Seed:    *seed,
			Groups:  *groups,
			Replays: 2,
			Prompt:  completionPrompt,
		}
		fres, err := pnm.BuildModelProgram(client.Driver, client.FW, fcfg)
		if err != nil {
			fmt.Fprintf(os.Stderr, "fabric program: %v\n", err)
			return 1
		}
		pnm.ModelFabricSummary(fres, fcfg, client.FW)
		fresult, ok := pnm.RunModelFabric(fres, dims, fcfg)
		if !ok {
			fmt.Println(fresult.Summary())
			fmt.Println("=== FABRIC BENCHMARK FAILED ===")
			return 1
		}
		fmt.Println(fresult.Summary())
		tok := float64(fcfg.Tokens)
		flitsPerTok := float64(fres.PlannedDFlits) / tok
		bytesPerTok := float64(fres.WireBytes) / tok
		cycPerTok := float64(fresult.WorstSpanCyc) / tok
		fmt.Printf("  per token: %.0f dispatch flits, %.0f wire bytes, ~%.0f span cycles\n", flitsPerTok, bytesPerTok, cycPerTok)
		simTokSec := 0.0
		if cycPerTok > 0 {
			simTokSec = 1e8 / cycPerTok
		}
		fmt.Printf("  sim fabric: 100 MHz byte-serial -> ~%.0f tok/s single-stream (sustained %.2f B/cyc)\n",
			simTokSec, fresult.BytesPerCycle)
		fmt.Printf("  projected: 1 GHz x 128-bit links (~160x byte rate) -> ~%.0f tok/s single-stream [projection, not measured]\n",
			simTokSec*160)
		if !fresult.Pass {
			fmt.Println("=== FABRIC BENCHMARK FAILED ===")
			return 1
		}
		fmt.Println()
	}

	if failed > 0 {
		fmt.Printf("=== TASK SUITE FAILED (%d/%d tasks) ===\n", failed, len(results))
		return 1
	}
	fmt.Println("=== TASK SUITE PASSED ===")
	return 0
}
