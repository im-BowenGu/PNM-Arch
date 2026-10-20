// Command r_pnm compiles an R source file to PNM dispatch
// instructions and optionally runs it on a simulated chassis.
//
//	go run ./cmd/r_pnm examples/hello.R
//	go run ./cmd/r_pnm examples/hello.R -l 2 -x 2 -y 2 -run
//	go run ./cmd/r_pnm examples/hello.R -o /tmp/hello.pnm
//
// The tool reads an R source file, compiles it to FP64 IR, lowers
// the IR to PNM kernel/token directives, and writes the .pnm program.
// With -run, it also invokes the co-simulation to execute the program
// on the specified chassis.
//
// This is a thin wrapper over the shared source-language front end
// (pnm.RunSourceCLI); `pnmsrc` is the same front end for all three
// languages.
package main

import (
	"os"

	"pnm/sim/internal/pnm"
)

func main() {
	os.Exit(pnm.RunSourceCLI(pnm.LangR, true, "r_pnm", os.Args[1:]))
}
