package pnm

import (
	"fmt"
	"math"
	"testing"
)

// This file provides a dataflow interpreter used as a test oracle for the
// R / Haskell / HLSL frontends.  It executes compiled IR against concrete
// input values and returns the final register map, so tests can assert the
// numeric result of a compiled expression matches the mathematical reference.
//
// The interpreter is intentionally independent of the compiler internals: it
// reads exactly the FP64IR / HLSLIR instruction streams and nothing else.  A
// register that is read before it is written reports an error, which is what
// turns "compound operand silently becomes an uninitialized zero register"
// into a hard, testable failure.

// EvalFP64 executes FP64 IR in program order.  inputs holds initial register
// values keyed by register name (e.g. "r0").  It returns the final value of
// every register that ended up defined, plus an error if a source register is
// read before it is written (dataflow violation) or an op is unsupported.
func EvalFP64(regs []FP64IR, inputs map[string]float64) (map[string]float64, error) {
	state := make(map[string]float64, len(inputs))
	for k, v := range inputs {
		state[k] = v
	}
	get := func(name string) (float64, error) {
		if v, ok := state[name]; ok {
			return v, nil
		}
		return 0, fmt.Errorf("dataflow: register %s read before it is written", name)
	}
	for _, ir := range regs {
		switch ir.Op {
		case FP64Const:
			state[ir.Dest] = ir.Imm
		case FP64Mov:
			v, err := get(ir.Src[0])
			if err != nil {
				return nil, err
			}
			state[ir.Dest] = v
		case FP64Neg:
			v, err := get(ir.Src[0])
			if err != nil {
				return nil, err
			}
			state[ir.Dest] = -v
		case FP64Add, FP64Sub, FP64Mul, FP64Div, FP64Min, FP64Max:
			a, err := get(ir.Src[0])
			if err != nil {
				return nil, err
			}
			b, err := get(ir.Src[1])
			if err != nil {
				return nil, err
			}
			state[ir.Dest] = fp64Binop(ir.Op, a, b)
		case FP64FMA:
			a, err := get(ir.Src[0])
			if err != nil {
				return nil, err
			}
			b, err := get(ir.Src[1])
			if err != nil {
				return nil, err
			}
			c, err := get(ir.Src[2])
			if err != nil {
				return nil, err
			}
			state[ir.Dest] = a*b + c
		case FP64Cmp:
			a, err := get(ir.Src[0])
			if err != nil {
				return nil, err
			}
			b, err := get(ir.Src[1])
			if err != nil {
				return nil, err
			}
			state[ir.Dest] = fp64Compare(a, b, ir.Cond)
		default:
			return nil, fmt.Errorf("interpreter: unsupported FP64 op %s", ir.Op)
		}
	}
	return state, nil
}

func fp64Binop(op FP64Op, a, b float64) float64 {
	switch op {
	case FP64Add:
		return a + b
	case FP64Sub:
		return a - b
	case FP64Mul:
		return a * b
	case FP64Div:
		return a / b
	case FP64Min:
		if a < b {
			return a
		}
		return b
	case FP64Max:
		if a > b {
			return a
		}
		return b
	}
	panic("unreachable")
}

func fp64Compare(a, b float64, cond string) float64 {
	switch cond {
	case "==":
		if a == b {
			return 1
		}
	case "!=":
		if a != b {
			return 1
		}
	case "<":
		if a < b {
			return 1
		}
	case ">":
		if a > b {
			return 1
		}
	case "<=":
		if a <= b {
			return 1
		}
	case ">=":
		if a >= b {
			return 1
		}
	}
	return 0
}

// EvalHLSL executes HLSL FP32 ALU IR (widened to float64 for comparison
// tolerance).  inputs holds initial register values keyed by name ("r0", ...).
func EvalHLSL(regs []HLSLIR, inputs map[string]float32) (map[string]float32, error) {
	state := make(map[string]float32, len(inputs))
	for k, v := range inputs {
		state[k] = v
	}
	get := func(name string) (float32, error) {
		if v, ok := state[name]; ok {
			return v, nil
		}
		return 0, fmt.Errorf("dataflow: register %s read before it is written", name)
	}
	for _, ir := range regs {
		switch ir.Op {
		case ALUConst:
			state[ir.Dest] = ir.Imm
		case ALUMov:
			v, err := get(ir.Src[0])
			if err != nil {
				return nil, err
			}
			state[ir.Dest] = v
		case ALUAdd, ALUSub, ALUMul, ALUDiv, ALUMin, ALUMax:
			a, err := get(ir.Src[0])
			if err != nil {
				return nil, err
			}
			b, err := get(ir.Src[1])
			if err != nil {
				return nil, err
			}
			state[ir.Dest] = hlslBinop(ir.Op, a, b)
		case ALUCmp:
			a, err := get(ir.Src[0])
			if err != nil {
				return nil, err
			}
			b, err := get(ir.Src[1])
			if err != nil {
				return nil, err
			}
			state[ir.Dest] = hlslCompare(a, b, ir.Cond)
		case ALULerp:
			a, err := get(ir.Src[0])
			if err != nil {
				return nil, err
			}
			b, err := get(ir.Src[1])
			if err != nil {
				return nil, err
			}
			t, err := get(ir.Src[2])
			if err != nil {
				return nil, err
			}
			state[ir.Dest] = a + t*(b-a)
		case ALUClamp:
			x, err := get(ir.Src[0])
			if err != nil {
				return nil, err
			}
			lo, err := get(ir.Src[1])
			if err != nil {
				return nil, err
			}
			hi, err := get(ir.Src[2])
			if err != nil {
				return nil, err
			}
			state[ir.Dest] = float32(math.Max(float64(lo), math.Min(float64(x), float64(hi))))
		case ALURcp:
			x, err := get(ir.Src[0])
			if err != nil {
				return nil, err
			}
			state[ir.Dest] = 1 / x
		case ALUDot:
			a, err := get(ir.Src[0])
			if err != nil {
				return nil, err
			}
			b, err := get(ir.Src[1])
			if err != nil {
				return nil, err
			}
			state[ir.Dest] = a * b
		default:
			return nil, fmt.Errorf("interpreter: unsupported HLSL op %s", ir.Op)
		}
	}
	return state, nil
}

func hlslBinop(op FP32ALUOp, a, b float32) float32 {
	switch op {
	case ALUAdd:
		return a + b
	case ALUSub:
		return a - b
	case ALUMul:
		return a * b
	case ALUDiv:
		return a / b
	case ALUMin:
		return float32(math.Min(float64(a), float64(b)))
	case ALUMax:
		return float32(math.Max(float64(a), float64(b)))
	}
	panic("unreachable")
}

func hlslCompare(a, b float32, cond string) float32 {
	switch cond {
	case "==":
		if a == b {
			return 1
		}
	case "!=":
		if a != b {
			return 1
		}
	case "<":
		if a < b {
			return 1
		}
	case ">":
		if a > b {
			return 1
		}
	case "<=":
		if a <= b {
			return 1
		}
	case ">=":
		if a >= b {
			return 1
		}
	}
	return 0
}

// fp64VarsToInputs converts a program's "var name -> register number" map into
// an interpreter input keyed by register name (r<N>), given a map of variable
// values.
func fp64VarsToInputs(vars map[string]int, vals map[string]float64) map[string]float64 {
	out := make(map[string]float64)
	for name, idx := range vars {
		if v, ok := vals[name]; ok {
			out[fmt.Sprintf("r%d", idx)] = v
		}
	}
	return out
}

// hlslVarsToInputs is the float32 counterpart of fp64VarsToInputs.
func hlslVarsToInputs(vars map[string]int, vals map[string]float32) map[string]float32 {
	out := make(map[string]float32)
	for name, idx := range vars {
		if v, ok := vals[name]; ok {
			out[fmt.Sprintf("r%d", idx)] = v
		}
	}
	return out
}

// assertClose reports a test failure when got and want differ by more than
// relTol * |want| + absTol.  NaN-aware.
func assertClose(t *testing.T, what string, got, want float64) {
	t.Helper()
	if math.IsNaN(want) {
		if !math.IsNaN(got) {
			t.Errorf("%s: got %v, want NaN", what, got)
		}
		return
	}
	absTol, relTol := 1e-9, 1e-9
	diff := math.Abs(got - want)
	if diff > absTol+relTol*math.Abs(want) {
		t.Errorf("%s: got %.17g, want %.17g (diff %g)", what, got, want, diff)
	}
}
