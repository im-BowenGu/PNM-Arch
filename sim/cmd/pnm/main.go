// Command pnm builds and runs the PNM co-simulation (Go <> Verilog).
//
//	go run ./cmd/pnm                       # 3x4x4 = 48 nodes, all scenarios
//	go run ./cmd/pnm -l 8 -x 8 -y 8        # the 512-node reference chassis
//	go run ./cmd/pnm --scenarios sweep stress --seed 1
//	go run ./cmd/pnm --groups 8            # 8 parallel vvp slices
//
// Pipeline (Paper.MD section 2.1-2.2 routing, section 2.9 doorbell):
//
//	go stimulus ---------> verilog fabric ---------> go virtual units
//	(AOT compiler/scheduler)  (pnm_top.v, real gates)  (doorbell + kernels)
//
// Exits non-zero if any scenario fails.
package main

import (
	"flag"
	"fmt"
	"os"
	"runtime/pprof"
	"strings"

	"pnm/sim/internal/pnm"
)

// extractScenarios pulls the --scenarios list out of argv with Python
// nargs="+" semantics: every token after the flag until the next token
// starting with '-'. The rest of argv is returned for flag.Parse, which
// cannot express this (it stops at the first positional).
func extractScenarios(argv []string) (rest, scenarios []string) {
	for i := 0; i < len(argv); i++ {
		switch {
		case argv[i] == "--scenarios" || argv[i] == "-scenarios":
			i++
			for i < len(argv) && !strings.HasPrefix(argv[i], "-") {
				scenarios = append(scenarios, argv[i])
				i++
			}
			i--
		case strings.HasPrefix(argv[i], "--scenarios="):
			scenarios = append(scenarios, strings.TrimPrefix(argv[i], "--scenarios="))
		default:
			rest = append(rest, argv[i])
		}
	}
	return rest, scenarios
}

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(argv []string) int {
	fs := flag.NewFlagSet("pnm", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)

	var layers, bx, by int
	fs.IntVar(&layers, "l", 3, "spine layers / boards")
	fs.IntVar(&layers, "layers", 3, "spine layers / boards")
	fs.IntVar(&bx, "x", 4, "X columns per board")
	fs.IntVar(&bx, "board-x", 4, "X columns per board")
	fs.IntVar(&by, "y", 4, "Y rows per board")
	seed := fs.Int64("seed", 0xC0FFEE, "RNG seed (default 0xC0FFEE)")
	flits := fs.Int("flits", 0, "override flit count for load/hotspot/stress")
	hotFrac := fs.Float64("hot-frac", 0.35, "hot-expert traffic share for hotspot")
	groups := fs.Int("groups", 0, "partition layers into G slices, one parallel vvp process each (default: min(layers, cpu_count))")
	cpuProf := fs.String("cpuprofile", "", "write CPU profile to file")
	memProf := fs.String("memprofile", "", "write heap profile to file")

	argv, scenarios := extractScenarios(argv)
	if err := fs.Parse(argv); err != nil {
		return 2
	}
	if len(scenarios) == 0 {
		scenarios = []string{"sweep", "vcsweep", "load", "hotspot", "stress", "replay"}
	}
	var flitsPtr *int
	fs.Visit(func(f *flag.Flag) {
		if f.Name == "flits" {
			flitsPtr = flits
		}
	})

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

	code := pnm.RunMain(layers, bx, by, scenarios, *seed, flitsPtr, *hotFrac, *groups)

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
