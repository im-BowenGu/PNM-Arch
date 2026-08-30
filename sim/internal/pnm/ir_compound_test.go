package pnm

import (
	"testing"
)

// TestHaskellEmitAndLowerDeterminism guards against map-iteration-order
// nondeterminism leaking into emitted IR text and the lowered .pnm program.
// HaskellProgram.Funcs is a map, so a naive "for _, fn := range prog.Funcs"
// emission/lowering would vary across runs when more than one function is
// defined.
func TestHaskellEmitAndLowerDeterminism(t *testing.T) {
	prog, err := CompileHaskell("g x = x * 2\nf a b = a + b\nmain = f (g 3) 4")
	if err != nil {
		t.Fatalf("CompileHaskell: %v", err)
	}
	if len(prog.Funcs) < 2 {
		t.Fatalf("expected >=2 functions, got %d", len(prog.Funcs))
	}

	firstEmit := prog.Emit()
	firstLower := LowerHaskellToPNM(prog, Dims{Layers: 1, Bx: 2, By: 2})
	for i := 0; i < 50; i++ {
		if prog.Emit() != firstEmit {
			t.Fatalf("Emit() nondeterministic (iteration %d)", i)
		}
		if LowerHaskellToPNM(prog, Dims{Layers: 1, Bx: 2, By: 2}) != firstLower {
			t.Fatalf("LowerHaskellToPNM() nondeterministic (iteration %d)", i)
		}
	}
}



// fp64IRHasDest reports whether a set of instructions assigns the given dest
// register as the result of the given opcode (not as an uninitialized zero).
func fp64IRHasDest(regs []FP64IR, dest string, op FP64Op) bool {
	for _, ir := range regs {
		if ir.Dest == dest && ir.Op == op {
			return true
		}
	}
	return false
}

// TestRCompoundOperand guards against a composite operand being lowered to an
// uninitialized (value-0) register.  "x <- a - b - c" must first compute a
// sub-expression for "a - b" before subtracting c; it must not read an empty
// register as 0.
func TestRCompoundOperand(t *testing.T) {
	prog, err := CompileR("a <- 3.0\nb <- 2.0\nc <- 1.0\nx <- a - b - c\n")
	if err != nil {
		t.Fatalf("CompileR: %v", err)
	}

	// The composite "a - b" requires the subtraction to be emitted as
	// negate-RHS + add, and the whole expression has two subtractions, so we
	// expect a healthy instruction count.  The old parser collapsed the inner
	// sub-expression to an uninitialized register and produced far fewer.
	// (a=3, b=2, c=1 consts + 2 negs + 2 adds = at least 7 instructions.)
	if len(prog.Regs) < 7 {
		t.Errorf("expected >=7 instructions for a compound expression with 2 subtractions, got %d", len(prog.Regs))
	}
}

// TestRCompoundOperandRecursion produces correct IR topology: the sub-expression
// must be a real register with a defining instruction, so that the final result
// does not depend on an empty (zero) register.
func TestRCompoundOperandNotZero(t *testing.T) {
	// a + b + c with all positive constants is the strongest test: the old
	// parser turned "b + c" into an uninitialized register worth 0, so the
	// result would be just "a".  With recursion the middle register must be a
	// real add.
	prog, err := CompileR("a <- 5.0\nb <- 3.0\nc <- 2.0\nx <- a + b + c\n")
	if err != nil {
		t.Fatalf("CompileR: %v", err)
	}

	defined := map[string]bool{}
	for _, ir := range prog.Regs {
		defined[ir.Dest] = true
	}
	for _, ir := range prog.Regs {
		// Every register referenced as a source must itself be defined.
		for _, src := range ir.Src {
			if src[0] == 'r' && !defined[src] {
				t.Errorf("register %s referenced but never defined (op %d)", src, ir.Op)
			}
		}
	}
}

// TestHaskellCompoundOperand guards against "b - c" inside "a - b - c" being
// lowered to an uninitialized (value-0) register.
func TestHaskellCompoundOperand(t *testing.T) {
	prog, err := CompileHaskell("f a b c = a - b - c")
	if err != nil {
		t.Fatalf("CompileHaskell: %v", err)
	}
	fn, ok := prog.Funcs["f"]
	if !ok || len(fn.Body) == 0 {
		t.Fatal("no body for f")
	}

	// There must be a subtraction whose RHS came from the composite "a - b":
	// "a - b - c" is left-associative and lowers to (a - b) - c, so both a
	// nested sub and a top-level sub are emitted.  With the old parser the
	// nested "a - b" was an uninitialized register and no nested sub existed
	// for it.
	subCount := 0
	for _, ir := range fn.Body {
		if ir.Op == FP64Sub {
			subCount++
		}
	}
	if subCount < 2 {
		t.Errorf("expected 2 subtraction instructions ((a - b) - c), got %d", subCount)
	}
}

// TestHaskellCrossFunctionCall guards against inlined function bodies reading
// stale definition-time registers.  A function body is compiled once in the
// global register space, but at a later call site those register numbers may
// (a) collide with caller-scope registers and (b) never be written by the
// call-site argument MOVs.  f (g 3) 4 = (3*2)+4 = 10 must actually compute 10,
// and the cached g/f definitions must not be corrupted by the inlining remap.
func TestHaskellCrossFunctionCall(t *testing.T) {
	prog, err := CompileHaskell("g x = x * 2\nf a b = a + b\nmain = f (g 3) 4")
	if err != nil {
		t.Fatalf("CompileHaskell: %v", err)
	}
	fn := prog.Funcs["main"]
	if fn == nil || len(fn.Body) == 0 {
		t.Fatal("no main body")
	}
	state, err := EvalFP64(fn.Body, nil)
	if err != nil {
		t.Fatalf("interpret main: %v", err)
	}
	last := fn.Body[len(fn.Body)-1]
	if got := state[last.Dest]; got != 10 {
		t.Errorf("f (g 3) 4 = %v, want 10 (inlined body read stale registers)", got)
	}

	// The cached definitions must be untouched by the remap: f's body must
	// still read its own argument registers.
	fb := prog.Funcs["f"]
	if fb == nil || len(fb.Body) == 0 {
		t.Fatal("no f body")
	}
	if add := fb.Body[0]; add.Op != FP64Add || add.Src[0] == "" || add.Src[1] == "" {
		t.Errorf("f body corrupted by call remap: %+v", add)
	}
}

// TestHaskellCrossFunctionCallMulti covers two call sites of the same
// function (independent register remaps) and a function-of-function
// composition (nested inlining).
func TestHaskellCrossFunctionCallMulti(t *testing.T) {
	prog, err := CompileHaskell("g x = x * 2\nf a b = a + b\nmain = f (g 3) (g 4)")
	if err != nil {
		t.Fatalf("CompileHaskell: %v", err)
	}
	fn := prog.Funcs["main"]
	state, err := EvalFP64(fn.Body, nil)
	if err != nil {
		t.Fatalf("interpret: %v", err)
	}
	last := fn.Body[len(fn.Body)-1]
	if got := state[last.Dest]; got != 14 { // (3*2)+(4*2) = 14
		t.Errorf("f (g 3) (g 4) = %v, want 14", got)
	}

	prog2, err := CompileHaskell("g x = x * 2\nh x = g (g x)\nmain = h 2")
	if err != nil {
		t.Fatalf("CompileHaskell 2: %v", err)
	}
	fn2 := prog2.Funcs["main"]
	state2, err := EvalFP64(fn2.Body, nil)
	if err != nil {
		t.Fatalf("interpret 2: %v", err)
	}
	last2 := fn2.Body[len(fn2.Body)-1]
	if got := state2[last2.Dest]; got != 8 { // g (g 2) = g 4 = 8
		t.Errorf("h 2 = g (g 2) = %v, want 8", got)
	}
}

// TestHaskellDoBlockInResult guards against a multi-line do block dropping its
// `in <expr>` tail: the function must return the in-expression value, not the
// value of the last body statement.
func TestHaskellDoBlockInResult(t *testing.T) {
	prog, err := CompileHaskell("f x = do\n    let y = x + 1.0\n    y * 2.0\n    in y\nmain = f 5.0")
	if err != nil {
		t.Fatalf("CompileHaskell: %v", err)
	}
	fn := prog.Funcs["main"]
	if fn == nil || len(fn.Body) == 0 {
		t.Fatal("no main body")
	}
	state, err := EvalFP64(fn.Body, nil)
	if err != nil {
		t.Fatalf("interpret main: %v", err)
	}
	last := fn.Body[len(fn.Body)-1]
	if got := state[last.Dest]; got != 6.0 { // in y = x+1 with x=5 => 6
		t.Errorf("f 5.0 (do-block, in y) = %v, want 6.0", got)
	}
}

// TestHLSLCompoundOperand guards against "b + c" inside "a.x + b.x + c.x"
// being lowered to an uninitialized (value-0) register.
func TestHLSLCompoundOperand(t *testing.T) {
	src := `
float4 main(float4 a : TEXCOORD0, float4 b : TEXCOORD1, float4 c : TEXCOORD2) : COLOR {
    float4 r;
    r.x = a.x + b.x + c.x;
    return r;
}`
	prog, err := CompileHLSL(src)
	if err != nil {
		t.Fatalf("CompileHLSL: %v", err)
	}

	addCount := 0
	for _, ir := range prog.Regs {
		if ir.Op == ALUAdd {
			addCount++
		}
	}
	// a.x + b.x + c.x needs two adds; the old parser emitted one (a + 0).
	if addCount < 2 {
		t.Errorf("expected 2 add instructions for a.x + b.x + c.x, got %d", addCount)
	}
}

// TestHLSLUnaryMinusOnVariable guards against "-b" inside a compound operand
// (e.g. "2.0 * -b") being lowered to a read of an unwritten register named
// "-b".  The resolver must negate the variable instead.
func TestHLSLUnaryMinusOnVariable(t *testing.T) {
	src := "float b;\nfloat out = 2.0 * -b;"
	prog, err := CompileHLSL(src)
	if err != nil {
		t.Fatalf("CompileHLSL: %v", err)
	}
	regInputs := hlslVarsToInputs(prog.Vars, map[string]float32{"b": 5})
	state, err := EvalHLSL(prog.Regs, regInputs)
	if err != nil {
		t.Fatalf("EvalHLSL: %v", err)
	}
	outReg := prog.getOrCreateReg("out")
	if got := state[outReg]; got != -10.0 {
		t.Fatalf("out = %v, want -10 (2.0 * -5)", got)
	}
}

// TestHaskellUnaryMinusOnVariable guards against "-b" inside a compound body
// (e.g. "f b = 2.0 * -b") being lowered to a read of an unwritten register
// named "-b".  The resolver must negate the variable instead.
func TestHaskellUnaryMinusOnVariable(t *testing.T) {
	prog, err := CompileHaskell("f b = 2.0 * -b")
	if err != nil {
		t.Fatalf("CompileHaskell: %v", err)
	}
	hf, ok := prog.Funcs["f"]
	if !ok {
		t.Fatalf("no function f in compiled program")
	}
	inputs := map[string]float64{}
	for i, r := range hf.ArgRegs {
		inputs[r] = []float64{5}[i]
	}
	state, err := EvalFP64(hf.Body, inputs)
	if err != nil {
		t.Fatalf("EvalFP64: %v", err)
	}
	last := hf.Body[len(hf.Body)-1]
	if got := state[last.Dest]; got != -10.0 {
		t.Fatalf("f 5 = %v, want -10 (2.0 * -5)", got)
	}
}
