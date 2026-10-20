package pnm

// srccli.go — the shared command-line body of the source-language front end.
//
// The per-language CLIs and the unified pnmsrc front end call
// RunSourceCLI; it owns the flags, the IR printout, the .pnm emission and
// the chained fabric run, so all four binaries behave identically.

import (
	"flag"
	"fmt"
	"os"
	"strings"
)

// SplitPositional extracts the first non-flag argument as the source path,
// supporting both `tool file.ext -flags` and `tool -flags file.ext`.
func SplitPositional(argv []string) (path string, rest []string) {
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

// ParseSourceInputs parses "name=val,name2=val2" into a map.
func ParseSourceInputs(s string) map[string]float64 {
	inputs := make(map[string]float64)
	if s == "" {
		return inputs
	}
	for _, pair := range strings.Split(s, ",") {
		kv := strings.SplitN(strings.TrimSpace(pair), "=", 2)
		if len(kv) != 2 {
			continue
		}
		var v float64
		if _, err := fmt.Sscanf(strings.TrimSpace(kv[1]), "%g", &v); err == nil {
			inputs[strings.TrimSpace(kv[0])] = v
		}
	}
	return inputs
}

// RunSourceCLI is the shared front-end driver. lang may be zero-valued when
// the caller infers the language from the source file's extension.
func RunSourceCLI(lang SourceLang, langGiven bool, progName string, argv []string) int {
	srcPath, rest := SplitPositional(argv)

	fs := flag.NewFlagSet(progName, flag.ContinueOnError)
	fs.SetOutput(os.Stderr)

	var layers, bx, by int
	fs.IntVar(&layers, "l", 2, "spine layers / boards")
	fs.IntVar(&layers, "layers", 2, "spine layers / boards")
	fs.IntVar(&bx, "x", 2, "X columns per board")
	fs.IntVar(&bx, "board-x", 2, "X columns per board")
	fs.IntVar(&by, "y", 2, "Y rows per board")
	fs.IntVar(&by, "board-y", 2, "Y rows per board")
	outPath := fs.String("o", "", "output .pnm path (default: <input>.pnm)")
	runSim := fs.Bool("run", false, "run the chained dataflow on the simulated chassis after emitting the program")
	irOnly := fs.Bool("ir", false, "print FP64 IR and exit (no PNM emission)")
	groups := fs.Int("groups", 0, "parallel vvp slices (default: min(layers, cpu))")
	inputVals := fs.String("inputs", "", "values for free inputs, e.g. x=4,y=7")
	placeFuncs := fs.Bool("place", false, "place each function on a dedicated node; run the entry function on the router SBC")

	if err := fs.Parse(rest); err != nil {
		return 2
	}
	if srcPath == "" && fs.NArg() > 0 {
		srcPath = fs.Arg(0)
	}
	if srcPath == "" {
		printSourceUsage(fs, progName, lang, langGiven)
		return 2
	}
	if !langGiven {
		// infer the language from the extension
		if l, ok := LangFromExt(srcPath); ok {
			lang = l
		} else {
			fmt.Fprintf(os.Stderr, "%s: cannot infer the language from %q (use -lang r|haskell|hlsl)\n",
				progName, srcPath)
			return 2
		}
	}
	src, err := os.ReadFile(srcPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		return 1
	}

	dims := Dims{Layers: layers, Bx: bx, By: by}
	totalNodes := dims.Layers * dims.Bx * dims.By

	sp, err := CompileSource(lang, string(src))
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s compilation error: %v\n", lang, err)
		return 1
	}

	fmt.Printf("%s\n", lang.IRLabel())
	fmt.Printf("Source: %s\n", srcPath)
	fmt.Printf("Chassis: %dx%dx%d = %d nodes\n\n", dims.Layers, dims.Bx, dims.By, totalNodes)
	fmt.Println(sp.IR)

	if *irOnly {
		return 0
	}

	pnmProgram := sp.LowerToPNM(dims)

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

	fmt.Printf("\n=== Chained dataflow on %dx%dx%d chassis ===\n\n", dims.Layers, dims.Bx, dims.By)
	df, err := sp.LowerDataFlow(dims)
	if err != nil {
		fmt.Fprintf(os.Stderr, "dataflow lowering error: %v\n", err)
		return 1
	}
	inputs := ParseSourceInputs(*inputVals)
	if *placeFuncs {
		pl, err := sp.PlaceFuncs(dims)
		if err != nil {
			fmt.Fprintf(os.Stderr, "placement error: %v\n", err)
			return 1
		}
		fmt.Printf("Placement:\n")
		for _, name := range sp.FuncNames() {
			if name == pl.Entry {
				fmt.Printf("  %-8s -> router SBC (entry, orchestration + folding)\n", name)
				continue
			}
			n := pl.FuncNode[name]
			fmt.Printf("  %-8s -> node (%d,%d,%d)\n", name, n.L, n.X, n.Y)
		}
		fmt.Printf("\n")
		res, err := RunDataFlowPlaced(df, inputs, *groups, pl)
		if err != nil {
			fmt.Fprintf(os.Stderr, "dataflow run error: %v\n", err)
			return 1
		}
		PrintDataFlow(df, res)
		return 0
	}
	res, err := RunDataFlow(df, inputs, *groups)
	if err != nil {
		fmt.Fprintf(os.Stderr, "dataflow run error: %v\n", err)
		return 1
	}
	PrintDataFlow(df, res)
	return 0
}

// PrintDataFlow prints each executed step and the program answer.
func PrintDataFlow(df *DataFlowProgram, res *DataFlowResult) {
	for i, t := range res.Traces {
		switch {
		case t.Host:
			fmt.Printf("  [%d] %-7s %s @ router-SBC               ->  %.8g   %s\n",
				i, t.Kernel, t.Dest, t.Result, passMark(t.Pass))
		case t.Fabric:
			fmt.Printf("  [%d] %-7s %s @ (%d,%d,%d)  args=%v  ->  %.8g   %s\n",
				i, t.Kernel, t.Dest, t.Node.L, t.Node.X, t.Node.Y, t.Args, t.Result, passMark(t.Pass))
		default:
			fmt.Printf("  [%d] %-7s %s                            ->  %.8g   %s\n",
				i, t.Op, t.Dest, t.Result, passMark(t.Pass))
		}
	}
	fmt.Printf("\n  result (%s) = %.8g   %d fabric dispatches across %d node(s), %d router-SBC fold(s)\n",
		res.Final, res.FinalV, res.Dispatches, res.Nodes, res.HostSteps)
	if len(df.FreeNames) > 0 {
		fmt.Printf("  inputs bound: %s\n", strings.Join(df.FreeNames, ", "))
	}
	fmt.Printf("\n  Note: chained dispatch verified byte-exact by the fabric; the static\n")
	fmt.Printf("  .pnm token payloads are name-hash placeholders (value-accurate run above).\n")
}

func passMark(pass bool) string {
	if pass {
		return "[PASS]"
	}
	return "[FAIL]"
}

func printSourceUsage(fs *flag.FlagSet, progName string, lang SourceLang, langGiven bool) {
	ext := lang.Ext()
	if !langGiven {
		ext = "source.R|source.hs|source.hlsl"
	}
	fmt.Fprintf(os.Stderr, "usage: %s [-lang r|haskell|hlsl] <%s> [-l L] [-x X] [-y Y] [-run] [-ir] [-o path]\n",
		progName, ext)
	fmt.Fprintln(os.Stderr)
	fmt.Fprintf(os.Stderr, "Compiles a source file to PNM dispatch instructions and, with -run,\n")
	fmt.Fprintf(os.Stderr, "executes the chained dataflow on the simulated chassis.\n")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "examples:")
	fmt.Fprintf(os.Stderr, "  %s examples/hello.R                    # emit .pnm\n", progName)
	fmt.Fprintf(os.Stderr, "  %s examples/hello.R -run               # emit + simulate\n", progName)
	fmt.Fprintf(os.Stderr, "  %s examples/hello.R -l 2 -x 2 -y 2    # 2-layer chassis\n", progName)
	fmt.Fprintf(os.Stderr, "  %s examples/hello.R -ir                # show FP64 IR only\n", progName)
}
