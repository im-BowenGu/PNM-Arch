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
// Exits non-zero if the compiled program fails on the gates.
package main

import (
	"flag"
	"fmt"
	"os"
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
		return 2
	}

	if *cpuProf != "" {
		f, err := os.Create(*cpuProf)
		if err != nil {
			fmt.Fprintf(os.Stderr, "cpuprofile: %v\n", err)
			return 2
		}
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
