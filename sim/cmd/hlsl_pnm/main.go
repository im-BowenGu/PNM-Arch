// Command hlsl_pnm compiles an HLSL source file to PNM dispatch
// instructions and optionally runs it on a simulated chassis.
//
//	go run ./cmd/hlsl_pnm examples/hello.hlsl
//	go run ./cmd/hlsl_pnm examples/hello.hlsl -l 2 -x 2 -y 2 -run
package main

import (
	"flag"
	"fmt"
	"os"
	"strings"

	"pnm/sim/internal/pnm"
)

func main() {
	os.Exit(run(os.Args[1:]))
}

func splitPositional(argv []string) (path string, rest []string) {
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

func run(argv []string) int {
	srcPath, rest := splitPositional(argv)

	fs := flag.NewFlagSet("hlsl_pnm", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)

	var layers, bx, by int
	fs.IntVar(&layers, "l", 2, "spine layers / boards")
	fs.IntVar(&layers, "layers", 2, "spine layers / boards")
	fs.IntVar(&bx, "x", 2, "X columns per board")
	fs.IntVar(&bx, "board-x", 2, "X columns per board")
	fs.IntVar(&by, "y", 2, "Y rows per board")
	fs.IntVar(&by, "board-y", 2, "Y rows per board")
	outPath := fs.String("o", "", "output .pnm path (default: <input>.pnm)")
	runSim := fs.Bool("run", false, "run co-simulation after emitting the program")
	irOnly := fs.Bool("ir", false, "print FP32 ALU IR and exit")
	groups := fs.Int("groups", 0, "parallel vvp slices (default: min(layers, cpu))")

	if err := fs.Parse(rest); err != nil {
		return 2
	}
	if srcPath == "" && fs.NArg() > 0 {
		srcPath = fs.Arg(0)
	}
	if srcPath == "" {
		fmt.Fprintln(os.Stderr, "usage: hlsl_pnm <source.hlsl> [-l L] [-x X] [-y Y] [-run] [-ir] [-o path]")
		fmt.Fprintln(os.Stderr)
		fmt.Fprintln(os.Stderr, "Compiles an HLSL compute shader to PNM dispatch instructions.")
		fmt.Fprintln(os.Stderr)
		fmt.Fprintln(os.Stderr, "examples:")
		fmt.Fprintln(os.Stderr, "  hlsl_pnm examples/hello.hlsl                    # emit .pnm")
		fmt.Fprintln(os.Stderr, "  hlsl_pnm examples/hello.hlsl -run               # emit + simulate")
		fmt.Fprintln(os.Stderr, "  hlsl_pnm examples/hello.hlsl -l 2 -x 2 -y 2    # 2-layer chassis")
		return 2
	}
	src, err := os.ReadFile(srcPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		return 1
	}

	dims := pnm.Dims{Layers: layers, Bx: bx, By: by}
	totalNodes := dims.Layers * dims.Bx * dims.By

	prog, err := pnm.CompileHLSL(string(src))
	if err != nil {
		fmt.Fprintf(os.Stderr, "HLSL compilation error: %v\n", err)
		return 1
	}

	fmt.Printf("=== HLSL -> FP32 ALU IR ===\n")
	fmt.Printf("Source: %s\n", srcPath)
	fmt.Printf("Chassis: %dx%dx%d = %d nodes\n\n", dims.Layers, dims.Bx, dims.By, totalNodes)

	irText := prog.Emit()
	fmt.Println(irText)

	if *irOnly {
		return 0
	}

	pnmProgram := pnm.LowerHLSLToPNM(prog, dims)

	fmt.Printf("=== PNM Dispatch ===\n")
	fmt.Println(pnmProgram)

	if *outPath == "" {
		*outPath = srcPath + ".pnm"
	}
	if err := os.WriteFile(*outPath, []byte(pnmProgram), 0o644); err != nil {
		fmt.Fprintf(os.Stderr, "writing %s: %v\n", *outPath, err)
		return 1
	}
	fmt.Printf("Wrote: %s\n", *outPath)

	if !*runSim {
		fmt.Printf("\nTo run on the chassis:\n  go run ./cmd/pnmc %s -l %d -x %d -y %d\n", *outPath, layers, bx, by)
		return 0
	}

	fmt.Printf("\n=== Running on %dx%dx%d chassis ===\n\n", dims.Layers, dims.Bx, dims.By)
	code := pnm.RunCompiler(*outPath, layers, bx, by, *groups, 0xC0FFEE)
	return code
}
