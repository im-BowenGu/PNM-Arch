package pnm

import (
	"fmt"
	"path/filepath"
	"strings"
)

// srcfront.go — the client-side front end for the three source languages.
//
// R, Haskell and HLSL all follow the same path: source text is compiled to
// an IR program, the IR is lowered to a .pnm dispatch program, and (with
// -run) the chained dataflow is executed on the simulated chassis with the
// real operand values. This file is the single implementation of that path;
// the per-language CLIs (r_pnm, haskell_pnm, hlsl_pnm) and the unified
// pnmsrc front end all call it, so the three languages cannot drift apart.
//
// The language-specific parts are the compiler, the .pnm lowering and the
// dataflow lowering; everything else (flags, IR printout, program emission,
// the fabric run and its report) is shared.

// SourceLang identifies one of the three source-language front ends.
type SourceLang int

const (
	// LangR is the R front end (FP64 IR).
	LangR SourceLang = iota
	// LangHaskell is the Haskell front end (FP64 IR).
	LangHaskell
	// LangHLSL is the HLSL front end (FP32 ALU IR).
	LangHLSL
)

// ParseSourceLang maps a command-line name to a language.
func ParseSourceLang(name string) (SourceLang, bool) {
	switch strings.ToLower(strings.TrimSpace(name)) {
	case "r":
		return LangR, true
	case "haskell", "hs":
		return LangHaskell, true
	case "hlsl":
		return LangHLSL, true
	}
	return LangR, false
}

// String is the language's display name.
func (l SourceLang) String() string {
	switch l {
	case LangR:
		return "R"
	case LangHaskell:
		return "Haskell"
	case LangHLSL:
		return "HLSL"
	}
	return "?"
}

// Ext is the language's canonical source-file extension.
func (l SourceLang) Ext() string {
	switch l {
	case LangR:
		return ".R"
	case LangHaskell:
		return ".hs"
	case LangHLSL:
		return ".hlsl"
	}
	return ""
}

// IRLabel is the heading printed above the emitted IR.
func (l SourceLang) IRLabel() string {
	switch l {
	case LangR:
		return "=== R -> FP64 IR ==="
	case LangHaskell:
		return "=== Haskell -> FP64 IR ==="
	case LangHLSL:
		return "=== HLSL -> FP32 ALU IR ==="
	}
	return "=== IR ==="
}

// LangFromExt infers the language from a source file's extension.
func LangFromExt(path string) (SourceLang, bool) {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".r":
		return LangR, true
	case ".hs":
		return LangHaskell, true
	case ".hlsl":
		return LangHLSL, true
	}
	return LangR, false
}

// SourceProgram is a compiled source-language program: the IR text plus the
// language-specific program the lowerings need.
type SourceProgram struct {
	Lang SourceLang
	IR   string
	prog any
}

// CompileSource compiles source text with the language's front end.
func CompileSource(lang SourceLang, src string) (*SourceProgram, error) {
	sp := &SourceProgram{Lang: lang}
	switch lang {
	case LangR:
		p, err := CompileR(src)
		if err != nil {
			return nil, err
		}
		sp.prog, sp.IR = p, p.Emit()
	case LangHaskell:
		p, err := CompileHaskell(src)
		if err != nil {
			return nil, err
		}
		sp.prog, sp.IR = p, p.Emit()
	case LangHLSL:
		p, err := CompileHLSL(src)
		if err != nil {
			return nil, err
		}
		sp.prog, sp.IR = p, p.Emit()
	default:
		return nil, fmt.Errorf("unknown source language")
	}
	return sp, nil
}

// LowerToPNM lowers the compiled program to the .pnm dispatch program.
func (sp *SourceProgram) LowerToPNM(dims Dims) string {
	switch p := sp.prog.(type) {
	case *FP64Program:
		return LowerToPNM(p, dims)
	case *HaskellProgram:
		return LowerHaskellToPNM(p, dims)
	case *HLSLProgram:
		return LowerHLSLToPNM(p, dims)
	}
	return ""
}

// LowerDataFlow lowers the compiled program to a chained dataflow program
// (real operand values, one cycle-exact fabric run).
func (sp *SourceProgram) LowerDataFlow(dims Dims) (*DataFlowProgram, error) {
	switch p := sp.prog.(type) {
	case *FP64Program:
		return LowerRDataFlow(p, dims)
	case *HaskellProgram:
		return LowerHaskellDataFlow(p, dims)
	case *HLSLProgram:
		return LowerHLSLDataFlow(p, dims)
	}
	return nil, fmt.Errorf("unknown source language")
}

// PlaceFuncs assigns each compiled function to its own node and names the
// entry function (the router-SBC frame). Only the Haskell front end keeps
// the per-function bodies, so the other languages report "not supported".
func (sp *SourceProgram) PlaceFuncs(dims Dims) (*Placement, error) {
	if p, ok := sp.prog.(*HaskellProgram); ok {
		return PlaceHaskellFuncs(p, dims)
	}
	return nil, fmt.Errorf("function placement is not supported for %s", sp.Lang)
}

// FuncNames lists the compiled functions in source order (Haskell only).
func (sp *SourceProgram) FuncNames() []string {
	if p, ok := sp.prog.(*HaskellProgram); ok {
		return p.Order
	}
	return nil
}
