// pnmhost is the unified host driver for the PNM architecture.
//
// It replaces the fragmented cmd/pnm, cmd/pnmc, and language CLI toolchains
// with a single entry point that handles scenarios, HPC workloads, .pnm
// programs, model compilation, and LLM inference — all with structured
// logging and result export.
//
// Usage:
//
//	pnmhost scenario sweep load stress          # run fabric verification scenarios
//	pnmhost workload matvec -l 4 -x 4 -y 4      # run an HPC workload
//	pnmhost program examples/bias_add.pnm       # compile and run a .pnm program
//	pnmhost model examples/gemma4_test_synthetic           # compile a model onto the chassis
//	pnmhost inference examples/gemma4_test_synthetic "Hi"  # run LLM inference
//	pnmhost run examples/bias_add.pnm            # shorthand: auto-detect and run
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"pnm/sim/internal/pnm"
)

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(argv []string) int {
	if len(argv) < 1 {
		printUsage()
		return 2
	}

	// First argument is the subcommand
	sub := argv[0]
	rest := argv[1:]

	switch sub {
	case "scenario", "scenarios":
		return runScenario(rest)
	case "workload", "wl":
		return runWorkload(rest)
	case "program", "prog":
		return runProgram(rest)
	case "model":
		return runModel(rest)
	case "inference", "infer":
		return runInference(rest)
	case "run":
		return runAuto(rest)
	case "help", "-h", "--help":
		printUsage()
		return 0
	default:
		// If it looks like a .pnm file, treat as "program"
		if strings.HasSuffix(sub, ".pnm") {
			return runProgram(argv)
		}
		fmt.Fprintf(os.Stderr, "unknown command: %s\n\n", sub)
		printUsage()
		return 2
	}
}

func printUsage() {
	fmt.Fprintln(os.Stderr, "pnmhost — unified PNM host driver")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "Usage: pnmhost <command> [options]")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "Commands:")
	fmt.Fprintln(os.Stderr, "  scenario <name> [...]   Run fabric verification scenarios")
	fmt.Fprintln(os.Stderr, "  workload <name>         Run an HPC workload (jacobi5, matvec, reduction, broadcast, nbody)")
	fmt.Fprintln(os.Stderr, "  program <path.pnm>      Compile and run a .pnm program")
	fmt.Fprintln(os.Stderr, "  model <dir>             Compile a HuggingFace model onto the chassis")
	fmt.Fprintln(os.Stderr, "  inference <dir> <prompt> Run LLM inference")
	fmt.Fprintln(os.Stderr, "  run <path.pnm>          Auto-detect and run a program")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "Global options (apply to all commands):")
	fmt.Fprintln(os.Stderr, "  -l, -layers <N>         Spine layers / boards (default 3)")
	fmt.Fprintln(os.Stderr, "  -x, -board-x <N>        X columns per board (default 4)")
	fmt.Fprintln(os.Stderr, "  -y, -board-y <N>        Y rows per board (default 4)")
	fmt.Fprintln(os.Stderr, "  -seed <N>               RNG seed (default 0xC0FFEE)")
	fmt.Fprintln(os.Stderr, "  -groups <N>             Parallel vvp slices (default: min(layers, CPUs))")
	fmt.Fprintln(os.Stderr, "  -output <dir>           Write structured results (CSV/JSON) to directory")
	fmt.Fprintln(os.Stderr, "  -log <file>             Write timestamped log to file")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "Scenario options:")
	fmt.Fprintln(os.Stderr, "  -flits <N>              Override flit count")
	fmt.Fprintln(os.Stderr, "  -hot-frac <F>           Hot-expert traffic share (default 0.35)")
	fmt.Fprintln(os.Stderr, "  -replay <N>             Replay count for determinism checks (default 1)")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "Workload options:")
	fmt.Fprintln(os.Stderr, "  -frag <N>               Extra parameter (vector length, fragment size)")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "Inference options:")
	fmt.Fprintln(os.Stderr, "  -max-tokens <N>         Max tokens to generate (default 32)")
	fmt.Fprintln(os.Stderr, "  -temperature <F>        Sampling temperature, 0=greedy (default 0)")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "Examples:")
	fmt.Fprintln(os.Stderr, "  pnmhost scenario sweep load stress --output results/")
	fmt.Fprintln(os.Stderr, "  pnmhost workload matvec -l 4 -x 4 -y 4 -frag 32")
	fmt.Fprintln(os.Stderr, "  pnmhost model examples/gemma4_test_synthetic -o results/")
	fmt.Fprintln(os.Stderr, "  pnmhost inference examples/gemma4_test_synthetic \"Hello\" -max-tokens 16")
}

// parseGlobal extracts global flags and returns remaining args.
func parseGlobal(argv []string) ([]string, *pnm.HostConfig) {
	cfg := &pnm.HostConfig{
		Layers: 3, Bx: 4, By: 4, Seed: 0xC0FFEE,
		HotFrac: 0.35, MaxTokens: 32, Replay: 1,
	}

	// Scan argv: flags start with '-', their values follow.
	// Everything else is positional.
	var positional []string
	for i := 0; i < len(argv); i++ {
		a := argv[i]
		if !strings.HasPrefix(a, "-") {
			positional = append(positional, a)
			continue
		}
		// It's a flag — find its value (next arg, unless it's another flag)
		val := ""
		if i+1 < len(argv) && !strings.HasPrefix(argv[i+1], "-") {
			val = argv[i+1]
			i++
		}
		switch a {
		case "-l", "-layers":
			fmt.Sscanf(val, "%d", &cfg.Layers)
		case "-x", "-board-x":
			fmt.Sscanf(val, "%d", &cfg.Bx)
		case "-y", "-board-y":
			fmt.Sscanf(val, "%d", &cfg.By)
		case "-seed":
			fmt.Sscanf(val, "%d", &cfg.Seed)
		case "-groups":
			fmt.Sscanf(val, "%d", &cfg.Groups)
		case "-output", "-o":
			cfg.OutputDir = val
		case "-log":
			cfg.LogFile = val
		case "-hot-frac":
			fmt.Sscanf(val, "%f", &cfg.HotFrac)
		case "-replay":
			fmt.Sscanf(val, "%d", &cfg.Replay)
		case "-max-tokens":
			fmt.Sscanf(val, "%d", &cfg.MaxTokens)
		case "-temperature":
			var t float64
			fmt.Sscanf(val, "%f", &t)
			cfg.Temperature = float32(t)
		case "-flits":
			if val != "" {
				var f int
				fmt.Sscanf(val, "%d", &f)
				cfg.Flits = &f
			}
		case "-frag":
			// Pass through to the subcommand: keep the flag and its value in
			// the positional list so runWorkload/runAuto can consume them.
			positional = append(positional, a)
			if val != "" {
				positional = append(positional, val)
			}
		}
	}

	return positional, cfg
}

func runScenario(argv []string) int {
	remaining, cfg := parseGlobal(argv)
	if len(remaining) == 0 {
		fmt.Fprintln(os.Stderr, "usage: pnmhost scenario <name> [...] [options]")
		fmt.Fprintln(os.Stderr, "  names: sweep, vcsweep, load, hotspot, stress, replay")
		return 2
	}

	hd := pnm.NewHostDriver(*cfg)
	defer hd.WriteResults()

	allPass := hd.RunScenarios(remaining...)
	hd.Log.Println(hd.Summary())

	if !allPass {
		return 1
	}
	return 0
}

func runWorkload(argv []string) int {
	remaining, cfg := parseGlobal(argv)
	if len(remaining) == 0 {
		fmt.Fprintln(os.Stderr, "usage: pnmhost workload <name> [options]")
		fmt.Fprintln(os.Stderr, "  names: jacobi5, matvec, reduction, broadcast, nbody")
		return 2
	}

	hd := pnm.NewHostDriver(*cfg)
	defer hd.WriteResults()

	frag := 0
	for i, a := range remaining {
		if a == "-frag" && i+1 < len(remaining) {
			fmt.Sscanf(remaining[i+1], "%d", &frag)
			remaining = append(remaining[:i], remaining[i+2:]...)
			break
		}
	}

	wlName := remaining[0]
	hd.Log.Printf("--- workload '%s' ---\n", wlName)
	ok := hd.RunWorkload(wlName, frag)
	hd.Log.Println(hd.Summary())

	if !ok {
		return 1
	}
	return 0
}

func runProgram(argv []string) int {
	remaining, cfg := parseGlobal(argv)
	if len(remaining) == 0 {
		fmt.Fprintln(os.Stderr, "usage: pnmhost program <path.pnm> [options]")
		return 2
	}

	hd := pnm.NewHostDriver(*cfg)
	defer hd.WriteResults()

	path := remaining[0]
	absPath, err := filepath.Abs(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "path: %v\n", err)
		return 1
	}

	hd.Log.Printf("--- program '%s' ---\n", filepath.Base(absPath))
	ok := hd.RunProgram(absPath)
	hd.Log.Println(hd.Summary())

	if !ok {
		return 1
	}
	return 0
}

func runModel(argv []string) int {
	remaining, cfg := parseGlobal(argv)
	if len(remaining) == 0 {
		fmt.Fprintln(os.Stderr, "usage: pnmhost model <model_dir> [options]")
		return 2
	}

	hd := pnm.NewHostDriver(*cfg)
	defer hd.WriteResults()

	modelDir := remaining[0]
	hd.Log.Printf("--- model '%s' ---\n", modelDir)
	ok := hd.RunModel(modelDir)
	hd.Log.Println(hd.Summary())

	if !ok {
		return 1
	}
	return 0
}

func runInference(argv []string) int {
	remaining, cfg := parseGlobal(argv)
	if len(remaining) < 2 {
		fmt.Fprintln(os.Stderr, "usage: pnmhost inference <model_dir> <prompt> [options]")
		return 2
	}

	hd := pnm.NewHostDriver(*cfg)
	defer hd.WriteResults()

	modelDir := remaining[0]
	prompt := remaining[1]
	hd.Log.Printf("--- inference '%s' ---\n", modelDir)
	ok := hd.RunInference(modelDir, prompt)
	hd.Log.Println(hd.Summary())

	if !ok {
		return 1
	}
	return 0
}

func runAuto(argv []string) int {
	remaining, cfg := parseGlobal(argv)
	if len(remaining) == 0 {
		fmt.Fprintln(os.Stderr, "usage: pnmhost run <path.pnm> [options]")
		return 2
	}

	// Auto-detect: if it's a .pnm file, run as program
	path := remaining[0]
	if strings.HasSuffix(path, ".pnm") {
		return runProgram(argv)
	}

	// Otherwise treat as a scenario or workload name
	registry := pnm.Workloads()
	if _, ok := registry[path]; ok {
		frag := 0
		for i, a := range remaining[1:] {
			if a == "-frag" && i+2 < len(remaining) {
				fmt.Sscanf(remaining[i+2], "%d", &frag)
				break
			}
		}
		hd := pnm.NewHostDriver(*cfg)
		defer hd.WriteResults()
		ok := hd.RunWorkload(path, frag)
		hd.Log.Println(hd.Summary())
		if !ok {
			return 1
		}
		return 0
	}

	// Try as scenario
	scenarios := map[string]bool{
		"sweep": true, "vcsweep": true, "load": true,
		"hotspot": true, "stress": true, "replay": true,
	}
	if scenarios[path] {
		hd := pnm.NewHostDriver(*cfg)
		defer hd.WriteResults()
		ok := hd.RunScenario(path)
		hd.Log.Println(hd.Summary())
		if !ok {
			return 1
		}
		return 0
	}

	fmt.Fprintf(os.Stderr, "cannot auto-detect type of '%s'\n", path)
	fmt.Fprintln(os.Stderr, "use: pnmhost program <path> | pnmhost workload <name> | pnmhost scenario <name>")
	return 2
}
