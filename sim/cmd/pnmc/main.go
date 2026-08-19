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
	if err := fs.Parse(argv); err != nil {
		return 2
	}
	if fs.NArg() < 1 {
		fmt.Fprintln(os.Stderr, "usage: pnmc compile-model <model_dir> [-l layers] [-x bx] [-y by] [-o output]")
		fmt.Fprintln(os.Stderr, "  model_dir must contain config.json and model.safetensors.index.json")
		return 2
	}
	modelDir := fs.Arg(0)

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

	// Compile
	dims := pnm.Dims{Layers: layers, Bx: bx, By: by}
	fmt.Printf("  chassis: %dx%dx%d = %d nodes\n", dims.Layers, dims.Bx, dims.By, dims.Layers*dims.Bx*dims.By)

	mc, err := pnm.CompileModel(cfg, idx, dims)
	if err != nil {
		fmt.Fprintf(os.Stderr, "compilation error: %v\n", err)
		return 1
	}

	// Print listing
	fmt.Println()
	fmt.Println(mc.EmitListing())

	// Write output files
	if err := os.MkdirAll(*outDir, 0o755); err != nil {
		fmt.Fprintf(os.Stderr, "creating output dir: %v\n", err)
		return 1
	}

	schemaPath := filepath.Join(*outDir, "gemma4_schema.txt")
	if err := os.WriteFile(schemaPath, []byte(mc.EmitSchema()), 0o644); err != nil {
		fmt.Fprintf(os.Stderr, "writing schema: %v\n", err)
		return 1
	}
	fmt.Printf("Wrote schema: %s\n", schemaPath)

	programPath := filepath.Join(*outDir, "gemma4.pnm")
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
	if err := fs.Parse(argv); err != nil {
		return 2
	}
	if fs.NArg() < 1 {
		fmt.Fprintln(os.Stderr, "usage: pnmc run-driver <model_dir> [-l layers] [-x bx] [-y by] [-o output]")
		fmt.Fprintln(os.Stderr, "  Runs the full driver + firmware boot sequence and generates")
		fmt.Fprintln(os.Stderr, "  routing_table.json, moe_map.json, and dispatch_plan.txt")
		return 2
	}
	modelDir := fs.Arg(0)

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

	// Plan inference
	fmt.Println("--- Inference Dispatch Plan ---")
	token := make([]byte, 32)
	for i := range token {
		token[i] = byte(i)
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

	fmt.Println()
	fmt.Println(fw.Summary())
	fmt.Println()
	fmt.Println("=== ALL CHECKS PASSED ===")

	return 0
}

func totalPayloadBytes(cmds []pnm.WeightUploadCommand) int64 {
	var total int64
	for _, c := range cmds {
		total += int64(len(c.Payload))
	}
	return total
}
