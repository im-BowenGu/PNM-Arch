package pnm

import (
	"fmt"
	"math"
	"testing"
)

// These tests are the semantic oracle for the R / Haskell / HLSL frontends.
// Each case compiles a source expression, seeds the declared inputs through
// the interpreter, and asserts the resulting register value equals the expected
// number.  This is far stronger than the older instruction-count assertions:
// it catches wrong opcodes, dropped operations, compound operands collapsing to
// zero, precedence errors, and branch mishandling — all at once.

type fp64SemCase struct {
	name  string
	src   string
	args  []string   // R variables / Haskell params to seed
	vals  []float64  // corresponding input values
	out   string     // output variable whose register to read ("_", "x", ...)
	want  float64
}

// runFP64Case compiles an R or Haskell source program, seeds inputs by
// variable name, interprets, and returns the value of the output register.
func runFP64Case(t *testing.T, src string, args []string, vals []float64, out string) float64 {
	t.Helper()
	prog, err := CompileR(src)
	if err != nil {
		t.Fatalf("CompileR: %v", err)
	}
	inputs := map[string]float64{}
	for i, a := range args {
		inputs[a] = vals[i]
	}
	// Map variable names to register names.
	regInputs := fp64VarsToInputs(prog.Vars, inputs)
	state, err := EvalFP64(prog.Regs, regInputs)
	if err != nil {
		t.Fatalf("interpret: %v", err)
	}
	regOut := prog.getOrCreateReg(out) // returns the rN for the variable
	return state[regOut]
}

// mapArgIndexes maps Haskell/R argument names to their positional register
// index (arg 0 -> register number 0, etc.), matching how the compiler registers
// parameters in order.
func mapArgIndexes(args []string) map[string]int {
	m := make(map[string]int, len(args))
	for i, a := range args {
		m[a] = i
	}
	return m
}

func TestFP64Semantics(t *testing.T) {
	cases := []fp64SemCase{
		// Single binary ops (base arity)
		{"r-add", "a <- 1.0\nb <- 2.0\nx <- a + b\n", []string{"a", "b"}, []float64{1, 2}, "x", 3},
		{"r-sub", "a <- 5.0\nb <- 3.0\nx <- a - b\n", []string{"a", "b"}, []float64{5, 3}, "x", 2},
		{"r-mul", "a <- 4.0\nb <- 2.5\nx <- a * b\n", []string{"a", "b"}, []float64{4, 2.5}, "x", 10},
		{"r-div", "a <- 9.0\nb <- 4.0\nx <- a / b\n", []string{"a", "b"}, []float64{9, 4}, "x", 2.25},

		// Compound / chained operands (round-5 bug: middle operand became 0)
		{"r-chain-sub", "a <- 10.0\nb <- 3.0\nc <- 2.0\nx <- a - b - c\n", []string{"a", "b", "c"}, []float64{10, 3, 2}, "x", 5},
		{"r-chain-add", "a <- 1.0\nb <- 2.0\nc <- 3.0\nx <- a + b + c\n", []string{"a", "b", "c"}, []float64{1, 2, 3}, "x", 6},
		{"r-paren", "a <- 1.0\nb <- 2.0\nc <- 3.0\nx <- a * (b + c)\n", []string{"a", "b", "c"}, []float64{1, 2, 3}, "x", 5},
		{"r-chain-muldiv", "a <- 6.0\nb <- 4.0\nc <- 2.0\nx <- a * b / c\n", []string{"a", "b", "c"}, []float64{6, 4, 2}, "x", 12},

		// Negation and abs
		{"r-neg-sub", "a <- 1.0\nb <- 5.0\nx <- a - b\n", []string{"a", "b"}, []float64{1, 5}, "x", -4},

		// Comparison
		{"r-cmp-lt", "a <- 1.0\nb <- 2.0\nx <- a < b\n", []string{"a", "b"}, []float64{1, 2}, "x", 1},
		{"r-cmp-gt", "a <- 1.0\nb <- 2.0\nx <- a > b\n", []string{"a", "b"}, []float64{1, 2}, "x", 0},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := runFP64Case(t, c.src, c.args, c.vals, c.out)
			assertClose(t, c.name, got, c.want)
		})
	}
}

// TestHaskellSemantics validates Haskell function bodies against the interpreter.
func TestHaskellSemantics(t *testing.T) {
	type hcase struct {
		name string
		src  string
		vals []float64
		want float64
	}
	cases := []hcase{
		{"h-sub", "f a b = a - b", []float64{7, 2}, 5},
		{"h-chain-sub", "f a b c = a - b - c", []float64{10, 3, 2}, 5},
		{"h-chain-add", "f a b c = a + b + c", []float64{1, 2, 3}, 6},
		{"h-paren", "f a b c = a * (b + c)", []float64{2, 3, 4}, 14},
		{"h-mul-add", "f a b c = a * b + c", []float64{2, 3, 4}, 10},
		{"h-add-mul", "f a b c = a + b * c", []float64{2, 3, 4}, 14},
		{"h-compare-gt", "f a b = if a > b then a else b", []float64{9, 4}, 9},
		{"h-compare-lt", "f a b = if a > b then a else b", []float64{4, 9}, 9},
		{"h-abs", "f a b = abs (a - b)", []float64{1, 5}, 4},
		{"h-sqrt", "f x = sqrt x", []float64{16}, 4},
		{"h-add-cmp", "f a b c = a + b == c", []float64{2, 3, 5}, 1},
		{"h-cmp-mul", "f a b c = a * b == c", []float64{2, 3, 6}, 1},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			prog, err := CompileHaskell(c.src)
			if err != nil {
				t.Fatalf("CompileHaskell: %v", err)
			}
			var fn *HaskellFunc
			for _, f := range prog.Funcs {
				fn = f
			}
			if fn == nil || len(fn.Body) == 0 {
				t.Fatal("no function body")
			}
			inputs := map[string]float64{}
			for i, a := range fn.Args {
				if i < len(c.vals) {
					inputs[a] = c.vals[i]
				}
			}
			regInputs := fp64VarsToInputs(mapArgIndexes(fn.Args), inputs)
			state, err := EvalFP64(fn.Body, regInputs)
			if err != nil {
				t.Fatalf("interpret: %v", err)
			}
			// Result is the last instruction's destination.
			last := fn.Body[len(fn.Body)-1]
			got, ok := state[last.Dest]
			if !ok {
				t.Fatalf("result register %s undefined", last.Dest)
			}
			assertClose(t, c.name, got, c.want)
		})
	}
}

// TestHLSLSemantics validates compiled HLSL expressions against the
// interpreter.  The harness uses newline-separated scalar declarations (which
// the HLSL frontend supports cleanly) and reads the result from a named output
// variable, avoiding the fragile single-line "float4 main(...)" form.
func TestHLSLSemantics(t *testing.T) {
	type hcase struct {
		name   string
		decls  string // newline-separated input declarations, e.g. "float a;\nfloat b;"
		expr   string // expression assigned to the output variable
		inputs map[string]float32
		want   float32
	}
	const out = "r"
	cases := []hcase{
		{"hlsl-sub",
			"float a;\nfloat b;", "a - b",
			map[string]float32{"a": 7, "b": 2}, 5},
		{"hlsl-chain-add",
			"float a;\nfloat b;\nfloat c;", "a + b + c",
			map[string]float32{"a": 1, "b": 2, "c": 3}, 6},
		{"hlsl-paren",
			"float a;\nfloat b;\nfloat c;", "a * (b + c)",
			map[string]float32{"a": 2, "b": 3, "c": 4}, 14},
		{"hlsl-mul-add",
			"float a;\nfloat b;\nfloat c;", "a * b + c",
			map[string]float32{"a": 2, "b": 3, "c": 4}, 10},
		{"hlsl-add-mul",
			"float a;\nfloat b;\nfloat c;", "a + b * c",
			map[string]float32{"a": 2, "b": 3, "c": 4}, 14},
		{"hlsl-lerp",
			"float a;\nfloat b;\nfloat t;", "lerp(a, b, t)",
			map[string]float32{"a": 0, "b": 10, "t": 0.25}, 2.5},
		{"hlsl-clamp",
			"float a;", "clamp(a, 0.0, 1.0)",
			map[string]float32{"a": 5}, 1},
		{"hlsl-clamp-lo",
			"float a;", "clamp(a, 0.0, 1.0)",
			map[string]float32{"a": -5}, 0},
		{"hlsl-rcp",
			"float a;", "rcp(a)",
			map[string]float32{"a": 4}, 0.25},
		{"hlsl-ternary",
			"float a;\nfloat b;\nfloat c;", "a > 0.0 ? b : c",
			map[string]float32{"a": 1, "b": 10, "c": 20}, 10},
		{"hlsl-ternary-false",
			"float a;\nfloat b;\nfloat c;", "a > 0.0 ? b : c",
			map[string]float32{"a": -1, "b": 10, "c": 20}, 20},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			src := c.decls + "\nfloat " + out + " = " + c.expr + ";"
			prog, err := CompileHLSL(src)
			if err != nil {
				t.Fatalf("CompileHLSL: %v", err)
			}
			regInputs := hlslVarsToInputs(prog.Vars, c.inputs)
			state, err := EvalHLSL(prog.Regs, regInputs)
			if err != nil {
				t.Fatalf("interpret: %v", err)
			}
			outReg := prog.getOrCreateReg(out)
			got, ok := state[outReg]
			if !ok {
				t.Fatalf("output register %s undefined", outReg)
			}
			assertClose(t, c.name, float64(got), float64(c.want))
		})
	}
}

// TestFP64SqrtNumerical pins the Newton-Raphson sqrt lowering against a few
// exact inputs, verifying the compiler actually converges to sqrt(x).
func TestFP64SqrtNumerical(t *testing.T) {
	vals := []float64{0.25, 1, 2, 4, 9, 100, 1e4}
	for _, x := range vals {
		src := fmt.Sprintf("x <- sqrt(%v)", x)
		prog, err := CompileR(src)
		if err != nil {
			t.Fatalf("sqrt(%v): %v", x, err)
		}
		state, err := EvalFP64(prog.Regs, nil)
		if err != nil {
			t.Fatalf("sqrt(%v) interpret: %v", x, err)
		}
		outReg := prog.getOrCreateReg("x")
		got := state[outReg]
		want := math.Sqrt(x)
		assertClose(t, fmt.Sprintf("sqrt(%v)", x), got, want)
	}
}
