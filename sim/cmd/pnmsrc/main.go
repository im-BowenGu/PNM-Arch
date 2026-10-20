// Command pnmsrc is the client-side front end for the source-language
// path: one binary for R, Haskell and HLSL.
//
//	pnmsrc examples/hello.R                    # emit hello.R.pnm
//	pnmsrc examples/hello.R -run               # emit + run on the chassis
//	pnmsrc -lang haskell examples/hello.hs -run -inputs x=4,y=7
//	pnmsrc examples/hello.hlsl -ir             # show the FP32 ALU IR only
//	pnmsrc -lang haskell examples/hello.hs -run -place
//
// The language is taken from -lang or inferred from the source extension.
// The program is compiled to the language's IR, lowered to a .pnm dispatch
// program, and (with -run) executed as a chained dataflow over the
// cycle-exact fabric co-simulation with real operand values.
//
// The per-language CLIs (r_pnm, haskell_pnm, hlsl_pnm) are thin wrappers
// around the same implementation.
package main

import (
	"fmt"
	"os"
	"strings"

	"pnm/sim/internal/pnm"
)

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(argv []string) int {
	// -lang is consumed here; everything else goes to the shared front end.
	langGiven := false
	lang := pnm.LangR
	rest := make([]string, 0, len(argv))
	for i := 0; i < len(argv); i++ {
		a := argv[i]
		if a == "-lang" || a == "--lang" {
			if i+1 >= len(argv) {
				fmt.Fprintln(os.Stderr, "pnmsrc: -lang needs a value (r, haskell or hlsl)")
				return 2
			}
			l, ok := pnm.ParseSourceLang(argv[i+1])
			if !ok {
				fmt.Fprintf(os.Stderr, "pnmsrc: unknown language %q (r, haskell or hlsl)\n", argv[i+1])
				return 2
			}
			lang, langGiven = l, true
			i++
			continue
		}
		if v, ok := strings.CutPrefix(a, "-lang="); ok {
			l, ok := pnm.ParseSourceLang(v)
			if !ok {
				fmt.Fprintf(os.Stderr, "pnmsrc: unknown language %q (r, haskell or hlsl)\n", v)
				return 2
			}
			lang, langGiven = l, true
			continue
		}
		rest = append(rest, a)
	}
	return pnm.RunSourceCLI(lang, langGiven, "pnmsrc", rest)
}
