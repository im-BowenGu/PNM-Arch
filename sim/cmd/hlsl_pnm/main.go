// Command hlsl_pnm compiles an HLSL source file to PNM dispatch
// instructions and optionally runs it on a simulated chassis.
//
//	go run ./cmd/hlsl_pnm examples/hello.hlsl
//	go run ./cmd/hlsl_pnm examples/hello.hlsl -l 2 -x 2 -y 2 -run
//	go run ./cmd/hlsl_pnm examples/hello.hlsl -o /tmp/hello.pnm
//
// The tool reads an HLSL source file, compiles it to FP32 ALU IR, lowers
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
	os.Exit(pnm.RunSourceCLI(pnm.LangHLSL, true, "hlsl_pnm", os.Args[1:]))
}
