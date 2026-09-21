// Command pnmc is a tiny AOT compiler + simulator driver for PNM programs.
//
//	go run ./cmd/pnmc examples/bias_add.pnm
//	go run ./cmd/pnmc examples/bias_add.pnm -l 8 -x 8 -y 8 --groups 8
//
// Program format (one directive per line, '#' comments):
//
//	kernel <sum|echo|accum|dot> <l> <x> <y> [<hex weights...>]
//	bias   <k> <l> <x> <y>
//	token  <l> <x> <y> <hex bytes...>
//
// Model compilation (safetensors -> PNM):
//
//	go run ./cmd/pnmc compile-model /path/to/model/ -l 4 -x 4 -y 4
//
// Exits non-zero if the compiled program fails on the gates.
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime/pprof"
	"sort"
	"strings"

	"pnm/sim/internal/pnm"
)

// splitProgram pulls the program path (the single positional) out of argv so
// flag.Parse can handle flags placed after it, matching argparse's
// interspersed-positional behavior. Every pnmc flag takes exactly one value,
// so the token after a flag is consumed as its value, not as the positional.
func splitProgram(argv []string) (path string, rest []string) {
	for i := 0; i < len(argv); i++ {
		a := argv[i]
		if strings.HasPrefix(a, "-") {
			rest = append(rest, a)
			if !strings.Contains(a, "=") && i+1 < len(argv) && !strings.HasPrefix(argv[i+1], "-") {
				i++
				rest = append(rest, argv[i])
			}
			continue
		}
		if path == "" {
			path = a
		}
	}
	return path, rest
}

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(argv []string) int {
	if len(argv) > 0 && argv[0] == "compile-model" {
		return runCompileModel(argv[1:])
	}
	if len(argv) > 0 && argv[0] == "run-driver" {
		return runDriver(argv[1:])
	}
	if len(argv) > 0 && argv[0] == "run-fabric" {
		return runFabric(argv[1:])
	}
	if len(argv) > 0 && argv[0] == "run-tasks" {
		return runTasks(argv[1:])
	}
	if len(argv) > 0 && argv[0] == "workload" {
		return runWorkload(argv[1:])
	}
	return runPNMC(argv)
}

func runPNMC(argv []string) int {
	program, argv := splitProgram(argv)
	fs := flag.NewFlagSet("pnmc", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)

	var layers, bx, by int
	fs.IntVar(&layers, "l", 3, "spine layers / boards")
	fs.IntVar(&layers, "layers", 3, "spine layers / boards")
	fs.IntVar(&bx, "x", 4, "X columns per board")
	fs.IntVar(&bx, "board-x", 4, "X columns per board")
	fs.IntVar(&by, "y", 4, "Y rows per board")
	fs.IntVar(&by, "board-y", 4, "Y rows per board")
	groups := fs.Int("groups", 0, "partition layers into G slices, one parallel vvp process each (default: min(layers, cpu_count))")
	seed := fs.Int64("seed", 0xC0FFEE, "RNG seed (default 0xC0FFEE)")
	cpuProf := fs.String("cpuprofile", "", "write CPU profile to file")
	memProf := fs.String("memprofile", "", "write heap profile to file")
	if err := fs.Parse(argv); err != nil {
		return 2
	}
	if program == "" {
		fmt.Fprintln(os.Stderr, "usage: pnmc <program.pnm> [-l layers] [-x bx] [-y by] [--groups G]")
		fmt.Fprintln(os.Stderr, "       pnmc compile-model <model_dir> [-l layers] [-x bx] [-y by] [-o output]")
		fmt.Fprintln(os.Stderr, "       pnmc run-driver <model_dir> [-l layers] [-x bx] [-y by] [-o output]")
		fmt.Fprintln(os.Stderr, "       pnmc run-fabric <model_dir> [-l layers] [-x bx] [-y by] [-n tokens] [--weights] [--groups G] [--replays R]")
		fmt.Fprintln(os.Stderr, "       pnmc run-tasks <model_dir> [-l layers] [-x bx] [-y by] [-max-tokens N] [-fabric N]")
		fmt.Fprintln(os.Stderr, "       pnmc workload <name> [-l layers] [-x bx] [-y by] [-frag N] [-run]")
		return 2
	}

	if *cpuProf != "" {
		f, err := os.Create(*cpuProf)
		if err != nil {
			fmt.Fprintf(os.Stderr, "cpuprofile: %v\n", err)
			return 2
		}
		defer f.Close()
		if err := pprof.StartCPUProfile(f); err != nil {
			fmt.Fprintf(os.Stderr, "cpuprofile: %v\n", err)
			return 2
		}
		defer pprof.StopCPUProfile()
	}

	code := pnm.RunCompiler(program, layers, bx, by, *groups, *seed)

	if *memProf != "" {
		f, err := os.Create(*memProf)
		if err != nil {
			fmt.Fprintf(os.Stderr, "memprofile: %v\n", err)
			return 2
		}
		if err := pprof.WriteHeapProfile(f); err != nil {
			fmt.Fprintf(os.Stderr, "memprofile: %v\n", err)
		}
		f.Close()
	}
	return code
}

func startCPUProfile(path string) func() {
	if path == "" {
		return func() {}
	}
	f, err := os.Create(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cpuprofile: %v\n", err)
		os.Exit(2)
	}
	if err := pprof.StartCPUProfile(f); err != nil {
		fmt.Fprintf(os.Stderr, "cpuprofile: %v\n", err)
		f.Close()
		os.Exit(2)
	}
	return func() {
		pprof.StopCPUProfile()
		f.Close()
	}
}

func writeHeapProfile(path string) {
	if path == "" {
		return
	}
	f, err := os.Create(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "memprofile: %v\n", err)
		return
	}
	if err := pprof.WriteHeapProfile(f); err != nil {
		fmt.Fprintf(os.Stderr, "memprofile: %v\n", err)
	}
	f.Close()
}

func runCompileModel(argv []string) int {
	fs := flag.NewFlagSet("compile-model", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)

	var layers, bx, by int
	fs.IntVar(&layers, "l", 4, "spine layers / boards")
	fs.IntVar(&layers, "layers", 4, "spine layers / boards")
	fs.IntVar(&bx, "x", 4, "X columns per board")
	fs.IntVar(&bx, "board-x", 4, "X columns per board")
	fs.IntVar(&by, "y", 4, "Y rows per board")
	fs.IntVar(&by, "board-y", 4, "Y rows per board")
	outDir := fs.String("o", ".", "output directory for generated files")
	cpuProf := fs.String("cpuprofile", "", "write CPU profile to file")
	memProf := fs.String("memprofile", "", "write heap profile to file")
	modelDir, argv := splitProgram(argv)
	if err := fs.Parse(argv); err != nil {
		return 2
	}
	if modelDir == "" {
		fmt.Fprintln(os.Stderr, "usage: pnmc compile-model <model_dir> [-l layers] [-x bx] [-y by] [-o output]")
		fmt.Fprintln(os.Stderr, "  model_dir must contain config.json and model.safetensors.index.json")
		return 2
	}
	stopCPU := startCPUProfile(*cpuProf)
	defer writeHeapProfile(*memProf)
	defer stopCPU()

	fmt.Printf("Loading model from %s...\n", modelDir)

	// Load config
	cfg, err := pnm.LoadModelConfig(modelDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error loading config: %v\n", err)
		return 1
	}
	tc := &cfg.TextConfig
	fmt.Printf("  model: %d layers, hidden=%d, experts=%d, active=%d, vocab=%d\n",
		tc.NumHiddenLayers, tc.HiddenSize, tc.NumExperts, tc.TopKExperts, tc.VocabSize)

	// Load safetensors index
	idx, err := pnm.LoadSafetensorsIndex(modelDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error loading safetensors index: %v\n", err)
		return 1
	}
	fmt.Printf("  tensors: %d entries in weight map\n", len(idx.WeightMap))

	dims := pnm.Dims{Layers: layers, Bx: bx, By: by}
	fmt.Printf("  chassis: %dx%dx%d = %d nodes\n", dims.Layers, dims.Bx, dims.By, dims.Layers*dims.Bx*dims.By)

	// Compile: model -> IR (chassis-independent), then IR -> schema (placement)
	ir, err := pnm.CompileModelIR(cfg, idx)
	if err != nil {
		fmt.Fprintf(os.Stderr, "IR compilation error: %v\n", err)
		return 1
	}
	fmt.Println()
	fmt.Println(ir.Emit())

	mc, err := ir.PopulateSchema(dims)
	if err != nil {
		fmt.Fprintf(os.Stderr, "compilation error: %v\n", err)
		return 1
	}

	// Tokenizer: load the real BPE vocab when the model carries one so the
	// compiled artifacts (and the host SDK) speak the model actual token
	// vocabulary rather than synthetic token_N placeholders.
	var bpe *pnm.BPEVocab
	if tb, terr := pnm.LoadBPEVocab(filepath.Join(modelDir, "tokenizer.json")); terr == nil {
		bpe = tb
		fmt.Printf("  tokenizer: loaded %d tokens (BPE, tokenizer.json)\n", tb.VocabSize())
	} else {
		fmt.Printf("  tokenizer: none found (%v); synthetic token map\n", terr)
	}

	// Print listing
	fmt.Println()
	fmt.Println(mc.EmitListing())

	// Write output files
	if err := os.MkdirAll(*outDir, 0o755); err != nil {
		fmt.Fprintf(os.Stderr, "creating output dir: %v\n", err)
		return 1
	}

	schemaPath := filepath.Join(*outDir, filepath.Base(modelDir)+"_schema.txt")
	if err := os.WriteFile(schemaPath, []byte(mc.EmitSchema()), 0o644); err != nil {
		fmt.Fprintf(os.Stderr, "writing schema: %v\n", err)
		return 1
	}
	fmt.Printf("Wrote schema: %s\n", schemaPath)
	if bpe != nil {
		vocabPath := filepath.Join(*outDir, filepath.Base(modelDir)+"_vocab.txt")
		var vb strings.Builder
		fmt.Fprintf(&vb, "# %d-token Gemma BPE vocabulary (id<TAB>token)\n", bpe.VocabSize())
		for id := 0; id < len(bpe.IDToToken); id++ {
			fmt.Fprintf(&vb, "%d	%s\n", id, bpe.IDToToken[id])
		}
		if err := os.WriteFile(vocabPath, []byte(vb.String()), 0o644); err != nil {
			fmt.Fprintf(os.Stderr, "writing vocab: %v\n", err)
			return 1
		}
		fmt.Printf("Wrote vocab: %s\n", vocabPath)
	}


	programPath := filepath.Join(*outDir, filepath.Base(modelDir)+".pnm")
	if err := os.WriteFile(programPath, []byte(mc.EmitProgram()), 0o644); err != nil {
		fmt.Fprintf(os.Stderr, "writing program: %v\n", err)
		return 1
	}
	fmt.Printf("Wrote program: %s\n", programPath)

	// Print schema
	fmt.Println()
	fmt.Println(mc.EmitSchema())

	return 0
}

func runDriver(argv []string) int {
	fs := flag.NewFlagSet("run-driver", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)

	var layers, bx, by int
	fs.IntVar(&layers, "l", 4, "spine layers / boards")
	fs.IntVar(&layers, "layers", 4, "spine layers / boards")
	fs.IntVar(&bx, "x", 4, "X columns per board")
	fs.IntVar(&bx, "board-x", 4, "X columns per board")
	fs.IntVar(&by, "y", 4, "Y rows per board")
	fs.IntVar(&by, "board-y", 4, "Y rows per board")
	outDir := fs.String("o", ".", "output directory for routing table and MoE map")
	cpuProf := fs.String("cpuprofile", "", "write CPU profile to file")
	memProf := fs.String("memprofile", "", "write heap profile to file")
	modelDir, argv := splitProgram(argv)
	if err := fs.Parse(argv); err != nil {
		return 2
	}
	if modelDir == "" {
		fmt.Fprintln(os.Stderr, "usage: pnmc run-driver <model_dir> [-l layers] [-x bx] [-y by] [-o output]")
		fmt.Fprintln(os.Stderr, "  Runs the full driver + firmware boot sequence and generates")
		fmt.Fprintln(os.Stderr, "  routing_table.json, moe_map.json, and dispatch_plan.txt")
		return 2
	}
	stopCPU := startCPUProfile(*cpuProf)
	defer writeHeapProfile(*memProf)
	defer stopCPU()

	fmt.Printf("=== PNM Driver + Firmware ===\n")
	fmt.Printf("Model: %s\n", modelDir)
	fmt.Printf("Chassis: %dx%dx%d = %d nodes\n\n", layers, bx, by, layers*bx*by)

	// Create driver
	dims := pnm.Dims{Layers: layers, Bx: bx, By: by}
	drv, err := pnm.NewDriver(pnm.DriverConfig{ModelDir: modelDir, Dims: dims})
	if err != nil {
		fmt.Fprintf(os.Stderr, "driver init: %v\n", err)
		return 1
	}

	tc := &drv.Config.TextConfig
	fmt.Printf("Model: %d layers, hidden=%d, experts=%d, active=%d, vocab=%d\n",
		tc.NumHiddenLayers, tc.HiddenSize, tc.NumExperts, tc.TopKExperts, tc.VocabSize)
	fmt.Printf("Total weights: %.1f GB (BF16)\n", float64(drv.MC.TotalBytes)/1e9)
	fmt.Printf("Per-node budget: %.1f GB\n\n", float64(drv.MC.PerNodeBudget)/1e9)

	// Run boot sequence
	fw := drv.FW
	fmt.Println("--- Boot Sequence ---")

	// Phase 1: POST Discovery
	cmds, err := fw.BootPhase()
	if err != nil {
		fmt.Fprintf(os.Stderr, "boot phase 1: %v\n", err)
		return 1
	}
	fmt.Printf("Phase 1 POST Discovery: %d nodes found\n", fw.NodeCount)

	// Phase 2: Routing Table
	_, err = fw.BootPhase()
	if err != nil {
		fmt.Fprintf(os.Stderr, "boot phase 2: %v\n", err)
		return 1
	}
	fmt.Printf("Phase 2 Routing Table: %d entries\n", len(drv.RouteBitmaps))

	// Phase 3: Weight Upload
	cmds, err = fw.BootPhase()
	if err != nil {
		fmt.Fprintf(os.Stderr, "boot phase 3: %v\n", err)
		return 1
	}
	fmt.Printf("Phase 3 Weight Upload: %d commands (%.1f MB total)\n",
		fw.WeightCount, float64(totalPayloadBytes(cmds))/1e6)

	// Verify weight upload
	if err := fw.VerifyWeightUpload(cmds); err != nil {
		fmt.Fprintf(os.Stderr, "weight verification: %v\n", err)
		return 1
	}
	fmt.Println("  Weight upload verification: PASSED")

	// Phase 4: MoE Load
	_, err = fw.BootPhase()
	if err != nil {
		fmt.Fprintf(os.Stderr, "boot phase 4: %v\n", err)
		return 1
	}
	fmt.Printf("Phase 4 MoE Gating: %d expert mappings\n", len(drv.MoeMap))

	// Phase 5: Ready
	_, err = fw.BootPhase()
	if err != nil {
		fmt.Fprintf(os.Stderr, "boot phase 5: %v\n", err)
		return 1
	}
	fmt.Println("Phase 5: READY")
	fmt.Println()

	// Plan inference: tokenize the model tokenizer.json when present so the
	// dispatch plan carries real token bytes through the gating network,
	// else fall back to a deterministic synthetic token.
	fmt.Println("--- Inference Dispatch Plan ---")
	var token []byte
	if tb, terr := pnm.LoadBPEVocab(filepath.Join(modelDir, "tokenizer.json")); terr == nil {
		if ids, ierr := tb.Encode("The capital of France is"); ierr == nil && len(ids) > 0 {
			token = make([]byte, 32)
			for w := 0; w < 16; w++ {
				token[2*w] = byte(ids[w%len(ids)] >> 8)
				token[2*w+1] = byte(ids[w%len(ids)] & 0xFF)
			}
		}
	}
	if token == nil {
		token = make([]byte, 32)
		for i := range token {
			token[i] = byte(i)
		}
	}
	records, err := fw.PlanInference(token)
	if err != nil {
		fmt.Fprintf(os.Stderr, "inference plan: %v\n", err)
		return 1
	}

	// Verify dispatch
	if err := fw.VerifyDispatch(records); err != nil {
		fmt.Fprintf(os.Stderr, "dispatch verification: %v\n", err)
		return 1
	}
	fmt.Println("  Dispatch verification: PASSED")

	denseCount := 0
	moeCount := 0
	for _, r := range records {
		if r.Phase == "dense" {
			denseCount++
		} else {
			moeCount++
		}
	}
	fmt.Printf("  Total dispatches: %d (%d dense + %d MoE)\n", len(records), denseCount, moeCount)
	fmt.Printf("  Layers: %d, Experts/token: %d\n\n", tc.NumHiddenLayers, tc.TopKExperts)

	// Write output files
	if err := os.MkdirAll(*outDir, 0o755); err != nil {
		fmt.Fprintf(os.Stderr, "creating output dir: %v\n", err)
		return 1
	}

	rtPath := filepath.Join(*outDir, "routing_table.json")
	if err := drv.WriteRoutingTable(rtPath); err != nil {
		fmt.Fprintf(os.Stderr, "writing routing table: %v\n", err)
		return 1
	}
	fmt.Printf("Wrote: %s\n", rtPath)

	moePath := filepath.Join(*outDir, "moe_map.json")
	if err := drv.WriteMoeMap(moePath); err != nil {
		fmt.Fprintf(os.Stderr, "writing MoE map: %v\n", err)
		return 1
	}
	fmt.Printf("Wrote: %s\n", moePath)

	dpPath := filepath.Join(*outDir, "dispatch_plan.txt")
	planText := fw.DispatchSummary(records)
	if err := os.WriteFile(dpPath, []byte(planText), 0o644); err != nil {
		fmt.Fprintf(os.Stderr, "writing dispatch plan: %v\n", err)
		return 1
	}
	fmt.Printf("Wrote: %s\n", dpPath)

	dpCSV := filepath.Join(*outDir, "dispatch_plan.csv")
	if err := pnm.WriteDispatchCSV(dpCSV, pnm.DispatchRecordsToResults(records)); err != nil {
		fmt.Fprintf(os.Stderr, "writing dispatch CSV: %v\n", err)
		return 1
	}
	fmt.Printf("Wrote: %s\n", dpCSV)

	fmt.Println()
	fmt.Println(fw.Summary())
	fmt.Println()
	fmt.Println("=== ALL CHECKS PASSED ===")

	return 0
}

// runFabric: the model-driven cycle-exact co-simulation proof.  Runs the
// driver + firmware boot to READY, plans cfg.Tokens tokens through
// PlanInference, converts every weight-upload command and dispatch record
// into the exact wire flit the orchestrator would inject, and pushes the
// whole stream through the real Verilog fabric (iverilog + vvp) via RunOne.
// Exits non-zero if the gates drop, misroute, or mis-deliver a single byte.
func runFabric(argv []string) int {
	fs := flag.NewFlagSet("run-fabric", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)

	var layers, bx, by, tokens, groups, replays int
	fs.IntVar(&layers, "l", 4, "spine layers / boards")
	fs.IntVar(&layers, "layers", 4, "spine layers / boards")
	fs.IntVar(&bx, "x", 4, "X columns per board")
	fs.IntVar(&bx, "board-x", 4, "X columns per board")
	fs.IntVar(&by, "y", 4, "Y rows per board")
	fs.IntVar(&by, "board-y", 4, "Y rows per board")
	fs.IntVar(&tokens, "n", 1, "tokens to dispatch through the fabric (each = dense + top-k MoE dispatches per layer)")
	fs.IntVar(&tokens, "tokens", 1, "tokens to dispatch through the fabric")
	uploadWeights := fs.Bool("weights", false, "also inject the Phase-3 weight-upload flits through the fabric")
	fs.IntVar(&groups, "groups", 0, "partition layers into G vvp slices (default: min(layers, cpu_count))")
	fs.IntVar(&replays, "replays", 0, "determinism replays (2 = assert bit-identical delivery logs; default 1)")
	seed := fs.Int64("seed", 0xC0FFEE, "RNG seed (node weight vectors)")
	prompt := fs.String("prompt", "", "tokenize this prompt and run it through the MoE gating network and Verilog fabric")
	outDir := fs.String("o", ".", "output directory for artifacts (default: sim/)")
	cpuProf := fs.String("cpuprofile", "", "write CPU profile to file")
	memProf := fs.String("memprofile", "", "write heap profile to file")
	modelDir, argv := splitProgram(argv)
	if err := fs.Parse(argv); err != nil {
		return 2
	}
	if modelDir == "" {
		fmt.Fprintln(os.Stderr, "usage: pnmc run-fabric <model_dir> [-l layers] [-x bx] [-y by] [-n tokens] [--weights] [--groups G] [--replays R]")
		fmt.Fprintln(os.Stderr, "  Plans realistic MoE dispatches for a real model config and runs them")
		fmt.Fprintln(os.Stderr, "  through the cycle-exact Verilog fabric (iverilog + vvp), slower than real")
		fmt.Fprintln(os.Stderr, "  time, proving byte-exact delivery, kernel correctness, and determinism.")
		return 2
	}
	stopCPU := startCPUProfile(*cpuProf)
	defer writeHeapProfile(*memProf)
	defer stopCPU()

	fmt.Printf("=== PNM Model -> Verilog Fabric co-simulation ===\n")
	fmt.Printf("Model: %s\n", modelDir)
	fmt.Printf("Chassis: %dx%dx%d = %d nodes\n\n", layers, bx, by, layers*bx*by)

	dims := pnm.Dims{Layers: layers, Bx: bx, By: by}
	drv, err := pnm.NewDriver(pnm.DriverConfig{ModelDir: modelDir, Dims: dims})
	if err != nil {
		fmt.Fprintf(os.Stderr, "driver init: %v\n", err)
		return 1
	}
	tc := drv.Config.TextConfig
	fmt.Printf("Model: %d layers, hidden=%d, experts=%d, active=%d, kv_heads=%d\n",
		tc.NumHiddenLayers, tc.HiddenSize, tc.NumExperts, tc.TopKExperts, tc.NumKeyValueHeads)
	fmt.Printf("Total weights: %.1f MB (BF16)\n\n", float64(drv.MC.TotalBytes)/1e6)

	fw := drv.FW
	fmt.Println("--- Boot Sequence (host side) ---")
	cmds, err := fw.BootPhase()
	if err != nil {
		fmt.Fprintf(os.Stderr, "boot phase 1: %v\n", err)
		return 1
	}
	fmt.Printf("Phase 1 POST Discovery: %d nodes found\n", fw.NodeCount)
	if _, err = fw.BootPhase(); err != nil {
		fmt.Fprintf(os.Stderr, "boot phase 2: %v\n", err)
		return 1
	}
	fmt.Printf("Phase 2 Routing Table: %d entries\n", len(drv.RouteBitmaps))
	cmds, err = fw.BootPhase()
	if err != nil {
		fmt.Fprintf(os.Stderr, "boot phase 3: %v\n", err)
		return 1
	}
	fmt.Printf("Phase 3 Weight Upload: %d commands (%.1f MB total)\n",
		fw.WeightCount, float64(totalPayloadBytes(cmds))/1e6)
	if err := fw.VerifyWeightUpload(cmds); err != nil {
		fmt.Fprintf(os.Stderr, "weight verification: %v\n", err)
		return 1
	}
	fmt.Println("  Weight upload verification: PASSED")
	if _, err = fw.BootPhase(); err != nil {
		fmt.Fprintf(os.Stderr, "boot phase 4: %v\n", err)
		return 1
	}
	fmt.Printf("Phase 4 MoE Gating: %d expert mappings\n", len(drv.MoeMap))
	if _, err = fw.BootPhase(); err != nil {
		fmt.Fprintf(os.Stderr, "boot phase 5: %v\n", err)
		return 1
	}
	fmt.Println("Phase 5: READY")
	fmt.Println()

	// Run the prompt through the MoE gating network: score the full expert
	// population per model layer and print the top-k decisions with the
	// physical node each winner maps to.
	var promptPayloads [][]byte
	if *prompt != "" {
		promptPayloads = pnm.PromptTokenPayloads(drv, *prompt, tokens)
		fmt.Println("--- MoE Gating Network (prompt) ---")
		fmt.Printf("prompt: %q -> token IDs packed into %d x 32-byte payload(s)\n", *prompt, len(promptPayloads))
		for ml := 0; ml < tc.NumHiddenLayers; ml++ {
			decisions, err := fw.GateToken(promptPayloads[0], ml)
			if err != nil {
				fmt.Fprintf(os.Stderr, "gate token at layer %d: %v\n", ml, err)
				return 1
			}
			fmt.Printf("  layer %d: top-%d of %d experts\n", ml, len(decisions), tc.NumExperts)
			for _, d := range decisions {
				fmt.Printf("    expert %-3d score 0x%016x -> node (%d, %d, %d)\n",
					d.Expert, d.Score, d.Node.L, d.Node.X, d.Node.Y)
			}
		}
		fmt.Println()
	}

	// Build the fabric program from the planned dispatches.
	fmt.Println("--- Fabric Dispatch Plan ---")
	cfg := pnm.ModelFabricConfig{
		Tokens:        tokens,
		Seed:          *seed,
		UploadWeights: *uploadWeights,
		Groups:        groups,
		Replays:       replays,
		Prompt:        *prompt,
	}
	res, err := pnm.BuildModelProgram(drv, fw, cfg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "building fabric program: %v\n", err)
		return 1
	}
	pnm.ModelFabricSummary(res, cfg, fw)

	// Verify the planned dispatch the way run-driver does, then push the
	// whole stream through the Verilog gates.
	if err := fw.VerifyDispatch(res.Records); err != nil {
		fmt.Fprintf(os.Stderr, "dispatch verification: %v\n", err)
		return 1
	}
	fmt.Println("  Dispatch verification: PASSED")

	if *outDir != "." {
		if err := os.MkdirAll(*outDir, 0o755); err != nil {
			fmt.Fprintf(os.Stderr, "creating output dir: %v\n", err)
			return 1
		}
		if err := drv.WriteRoutingTable(filepath.Join(*outDir, "routing_table.json")); err != nil {
			fmt.Fprintf(os.Stderr, "writing routing table: %v\n", err)
			return 1
		}
		if err := drv.WriteMoeMap(filepath.Join(*outDir, "moe_map.json")); err != nil {
			fmt.Fprintf(os.Stderr, "writing MoE map: %v\n", err)
			return 1
		}
	}
	_ = cmds

	fmt.Println()
	fmt.Println("--- Cycle-Exact Verilog Fabric (slower than real time) ---")
	result, ok := pnm.RunModelFabric(res, dims, cfg)
	if !ok {
		return 1
	}
	fmt.Println()
	fmt.Println(result.Summary())
	fmt.Println()
	if !result.Pass {
		fmt.Println("=== FABRIC PROOF FAILED ===")
		return 1
	}
	if *prompt != "" {
		printVerifiedNodeResults(result, res)
	}
	fmt.Println("=== FABRIC PROOF PASSED ===")
	return 0
}

// printVerifiedNodeResults prints each node's verified kernel results (from
// the resident-kernel execution over hardware-delivered data) after a fabric
// run, labeling MoE-expert nodes (which received prompt-gated dispatch
// traffic) versus dense-attention nodes.
func printVerifiedNodeResults(result *pnm.ScenarioResult, res *pnm.ModelFabricResult) {
	denseCount := map[pnm.NodeID]int{}
	moeCount := map[pnm.NodeID]int{}
	// expert identity per node, in injection (= result) order: each record
	// with wire traffic maps 1:1 to one delivered packet on its target node
	expertSeq := map[pnm.NodeID][]int{}
	for _, r := range res.Records {
		expertSeq[r.TargetNode] = append(expertSeq[r.TargetNode], r.ExpertIdx)
		if r.Phase == "moe" {
			moeCount[r.TargetNode]++
		} else {
			denseCount[r.TargetNode]++
		}
	}
	fmt.Println("--- Verified per-node expert outputs (resident kernel over delivered data) ---")
	nodes := make([]string, 0, len(result.NodeResults))
	for n := range result.NodeResults {
		nodes = append(nodes, n)
	}
	sort.Strings(nodes)
	for _, n := range nodes {
		results, _ := result.NodeResults[n].([]interface{})
		if len(results) == 0 {
			continue
		}
		role := "dense-attention"
		id, ok := parseNodeIDString(n)
		if ok {
			d, m := denseCount[id], moeCount[id]
			if m > 0 {
				role = fmt.Sprintf("%d dense + %d MoE expert packet(s)", d, m)
			} else if d > 0 {
				role = "dense-attention"
			}
		}
		distinct := map[interface{}]bool{}
		for _, r := range results {
			distinct[r] = true
		}
		fmt.Printf("  node %s [%s, %d distinct output(s) across %d packet(s)]:\n", n, role, len(distinct), len(results))
		ex := expertSeq[id]
		for i, r := range results {
			label := "dense"
			if i < len(ex) && ex[i] >= 0 {
				label = fmt.Sprintf("expert %d", ex[i])
			}
			fmt.Printf("    packet %d (%s) -> dot-product result %v\n", i, label, r)
		}
	}
	fmt.Println()
}

// parseNodeIDString recovers a NodeID from its String() form "(l, x, y)".
func parseNodeIDString(s string) (pnm.NodeID, bool) {
	var l, x, y int
	if _, err := fmt.Sscanf(s, "(%d, %d, %d)", &l, &x, &y); err != nil {
		return pnm.NodeID{}, false
	}
	return pnm.NodeID{L: l, X: x, Y: y}, true
}

func totalPayloadBytes(cmds []pnm.WeightUploadCommand) int64 {
	var total int64
	for _, c := range cmds {
		total += c.SizeBytes
	}
	return total
}

func runWorkload(argv []string) int {
	if len(argv) < 1 {
		fmt.Fprintln(os.Stderr, "usage: pnmc workload <name> [-l layers] [-x bx] [-y by] [-frag N] [-o path] [-run]")
		fmt.Fprintln(os.Stderr)
		fmt.Fprintln(os.Stderr, "available workloads:")
		registry := pnm.Workloads()
		for _, name := range []string{"jacobi5", "matvec", "reduction", "broadcast", "nbody"} {
			w := registry[name]
			fmt.Fprintf(os.Stderr, "  %-12s  default: %dx%dx%d  frag=%d\n", name, w.Layers, w.Bx, w.By, w.Frag)
		}
		fmt.Fprintln(os.Stderr)
		fmt.Fprintln(os.Stderr, "examples:")
		fmt.Fprintln(os.Stderr, "  pnmc workload jacobi5 -l 1 -x 8 -y 8")
		fmt.Fprintln(os.Stderr, "  pnmc workload matvec -l 4 -x 4 -y 4 -frag 32 -run")
		fmt.Fprintln(os.Stderr, "  pnmc workload reduction -l 4 -x 4 -y 4")
		return 2
	}
	wlName := argv[0]

	fs := flag.NewFlagSet("workload "+wlName, flag.ContinueOnError)
	fs.SetOutput(os.Stderr)

	var layers, bx, by, frag int
	fs.IntVar(&layers, "l", 4, "spine layers / boards")
	fs.IntVar(&layers, "layers", 4, "spine layers / boards")
	fs.IntVar(&bx, "x", 4, "X columns per board")
	fs.IntVar(&bx, "board-x", 4, "X columns per board")
	fs.IntVar(&by, "y", 4, "Y rows per board")
	fs.IntVar(&by, "board-y", 4, "Y rows per board")
	fs.IntVar(&frag, "frag", 0, "extra parameter (vector length, fragment size, payload length)")
	outPath := fs.String("o", "", "output .pnm path (default: /tmp/<name>.pnm)")
	runSim := fs.Bool("run", false, "also run co-simulation after emitting the program")
	if err := fs.Parse(argv[1:]); err != nil {
		return 2
	}

	registry := pnm.Workloads()
	reg, ok := registry[wlName]
	if !ok {
		fmt.Fprintf(os.Stderr, "unknown workload %q (available: jacobi5, matvec, reduction, broadcast, nbody)\n", wlName)
		return 1
	}
	if frag == 0 {
		frag = reg.Frag
	}

	wl, err := reg.Gen(layers, bx, by, frag)
	if err != nil {
		fmt.Fprintf(os.Stderr, "workload %s: %v\n", wlName, err)
		return 1
	}

	fmt.Printf("=== Workload: %s ===\n", wl.Name)
	fmt.Printf("  %s\n", wl.Desc)
	fmt.Printf("  chassis: %dx%dx%d = %d nodes\n", layers, bx, by, layers*bx*by)
	fmt.Printf("  active nodes: %d, tokens: %d\n", wl.Nodes, wl.Tokens)
	fmt.Printf("  routing pattern: %s\n\n", wl.Routing)

	if *outPath == "" {
		*outPath = "/tmp/" + wlName + ".pnm"
	}
	outAbs, err := filepath.Abs(*outPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "output path: %v\n", err)
		return 1
	}
	if err := os.WriteFile(outAbs, []byte(wl.Program), 0o644); err != nil {
		fmt.Fprintf(os.Stderr, "writing %s: %v\n", outAbs, err)
		return 1
	}
	fmt.Printf("Wrote program: %s\n", outAbs)

	if *runSim {
		fmt.Println("\n--- Running co-simulation ---")
		if code := pnm.RunCompiler(outAbs, layers, bx, by, 0, 0xC0FFEE); code != 0 {
			return code
		}
	}
	return 0
}
