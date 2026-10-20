package pnm

// srcfront_test.go — the client-side source front end must behave the same
// for all three languages, and the language must be inferable from the file
// extension.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSourceLangParsing(t *testing.T) {
	cases := map[string]SourceLang{
		"r":       LangR,
		"R":       LangR,
		"haskell": LangHaskell,
		"hs":      LangHaskell,
		"Haskell": LangHaskell,
		"hlsl":    LangHLSL,
		"HLSL":    LangHLSL,
	}
	for name, want := range cases {
		got, ok := ParseSourceLang(name)
		if !ok || got != want {
			t.Fatalf("ParseSourceLang(%q) = %v,%v; want %v,true", name, got, ok, want)
		}
	}
	if _, ok := ParseSourceLang("fortran"); ok {
		t.Fatal("ParseSourceLang(\"fortran\") accepted an unknown language")
	}
}

func TestSourceLangFromExt(t *testing.T) {
	cases := map[string]SourceLang{
		"a.R":      LangR,
		"a.r":      LangR,
		"a.hs":     LangHaskell,
		"a.hlsl":   LangHLSL,
		"dir/a.HS": LangHaskell,
	}
	for path, want := range cases {
		got, ok := LangFromExt(path)
		if !ok || got != want {
			t.Fatalf("LangFromExt(%q) = %v,%v; want %v,true", path, got, ok, want)
		}
	}
	if _, ok := LangFromExt("a.py"); ok {
		t.Fatal("LangFromExt(\"a.py\") accepted an unknown extension")
	}
}

func TestSourceFrontEndAllLanguages(t *testing.T) {
	// The same program in all three languages: x*y + x + y with x=4, y=7 = 39.
	src := map[SourceLang]string{
		LangR:       "x <- 4\ny <- 7\nz <- x * y + x + y\n",
		LangHaskell: "main x y = x * y + x + y\n",
		LangHLSL:    "float result = x * y;\nresult = result + x;\nresult = result + y;\n",
	}
	for lang, text := range src {
		sp, err := CompileSource(lang, text)
		if err != nil {
			t.Fatalf("%s: compile: %v", lang, err)
		}
		if sp.IR == "" {
			t.Fatalf("%s: empty IR", lang)
		}
		if p := sp.LowerToPNM(Dims{Layers: 1, Bx: 2, By: 2}); !strings.Contains(p, "kernel") {
			t.Fatalf("%s: lowering produced no kernels:\n%s", lang, p)
		}
		if _, err := sp.LowerDataFlow(Dims{Layers: 1, Bx: 2, By: 2}); err != nil {
			t.Fatalf("%s: dataflow lowering: %v", lang, err)
		}
	}
}

func TestSourceFrontEndCLIWritesProgram(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "prog.R")
	if err := os.WriteFile(src, []byte("x <- 4\ny <- 7\nz <- x * y + x + y\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(dir, "prog.pnm")
	if code := RunSourceCLI(LangR, false, "pnmsrc", []string{src, "-o", out}); code != 0 {
		t.Fatalf("RunSourceCLI exit %d", code)
	}
	b, err := os.ReadFile(out)
	if err != nil {
		t.Fatalf("program not written: %v", err)
	}
	if !strings.Contains(string(b), "kernel") {
		t.Fatalf("program has no kernels:\n%s", b)
	}
}
