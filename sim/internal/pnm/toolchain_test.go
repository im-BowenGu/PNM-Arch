package pnm

import (
	"fmt"
	"math"
	"strings"
	"testing"
)

func TestCompileR(t *testing.T) {
	src := `
# Simple R computation
x <- 1.0
y <- 2.0
z <- x + y
w <- z * 3.0
a <- sum(1.0, 2.0, 3.0)
b <- mean(10.0, 20.0, 30.0)
c <- min(5.0, 3.0, 7.0)
d <- max(5.0, 3.0, 7.0)
e <- abs(-42.0)
`
	prog, err := CompileR(src)
	if err != nil {
		t.Fatalf("CompileR failed: %v", err)
	}
	if len(prog.Regs) == 0 {
		t.Fatal("expected non-empty IR")
	}
	out := prog.Emit()
	if !strings.Contains(out, "f64.add") {
		t.Error("expected f64.add in output")
	}
	if !strings.Contains(out, "f64.mul") {
		t.Error("expected f64.mul in output")
	}
	if !strings.Contains(out, "f64.min") {
		t.Error("expected f64.min in output")
	}
	if !strings.Contains(out, "f64.max") {
		t.Error("expected f64.max in output")
	}
	t.Logf("R IR (%d instructions):\n%s", len(prog.Regs), out)
}

func TestCompileRDiv(t *testing.T) {
	src := `
x <- 10.0
y <- 3.0
z <- x / y
`
	prog, err := CompileR(src)
	if err != nil {
		t.Fatalf("CompileR failed: %v", err)
	}
	out := prog.Emit()
	if !strings.Contains(out, "f64.div") {
		t.Error("expected f64.div in output")
	}
	t.Logf("R div IR:\n%s", out)
}

func TestCompileHaskell(t *testing.T) {
	src := `
f x = x * 2.0 + 1.0
g a b = a + b
main = f 5.0
`
	prog, err := CompileHaskell(src)
	if err != nil {
		t.Fatalf("CompileHaskell failed: %v", err)
	}
	if len(prog.Funcs) < 1 {
		t.Fatal("expected at least 1 function")
	}
	out := prog.Emit()
	if !strings.Contains(out, "func f") {
		t.Error("expected func f in output")
	}
	if !strings.Contains(out, "func g") {
		t.Error("expected func g in output")
	}
	t.Logf("Haskell IR:\n%s", out)
}

func TestCompileHaskellAgg(t *testing.T) {
	src := `
sumList a b c = sum a b c
minVal a b = minimum a b
`
	prog, err := CompileHaskell(src)
	if err != nil {
		t.Fatalf("CompileHaskell failed: %v", err)
	}
	out := prog.Emit()
	if !strings.Contains(out, "f64.add") {
		t.Error("expected f64.add for sum")
	}
	t.Logf("Haskell agg IR:\n%s", out)
}

func TestCompileHLSL(t *testing.T) {
	src := `
float4 main(float2 uv : TEXCOORD0) {
    float4 col = float4(1.0, 0.5, 0.2, 1.0);
    float brightness = dot(col.rgb, float3(0.299, 0.587, 0.114));
    float4 result = lerp(col, float4(1.0, 1.0, 1.0, 1.0), brightness);
    return saturate(result);
}
`
	prog, err := CompileHLSL(src)
	if err != nil {
		t.Fatalf("CompileHLSL failed: %v", err)
	}
	if len(prog.Regs) == 0 {
		t.Fatal("expected non-empty IR")
	}
	out := prog.Emit()
	if !strings.Contains(out, "alu.dot") {
		t.Error("expected alu.dot for dot product")
	}
	if !strings.Contains(out, "alu.lerp") {
		t.Error("expected alu.lerp for lerp")
	}
	if !strings.Contains(out, "alu.clamp") {
		t.Error("expected alu.clamp for saturate")
	}
	t.Logf("HLSL IR (%d instructions):\n%s", len(prog.Regs), out)
}

func TestCompileHLSLArith(t *testing.T) {
	src := `
float compute(float a, float b) {
    float x = a + b;
    float y = a * b;
    float z = x / y;
    float w = min(x, y);
    float v = max(x, y);
    return v;
}
`
	prog, err := CompileHLSL(src)
	if err != nil {
		t.Fatalf("CompileHLSL failed: %v", err)
	}
	out := prog.Emit()
	if !strings.Contains(out, "alu.add") {
		t.Error("expected alu.add")
	}
	if !strings.Contains(out, "alu.mul") {
		t.Error("expected alu.mul")
	}
	if !strings.Contains(out, "alu.div") {
		t.Error("expected alu.div")
	}
	if !strings.Contains(out, "alu.min") {
		t.Error("expected alu.min")
	}
	if !strings.Contains(out, "alu.max") {
		t.Error("expected alu.max")
	}
	t.Logf("HLSL arith IR:\n%s", out)
}

func TestCompileHLSLSmoothstep(t *testing.T) {
	src := `
float s(float lo, float hi, float x) {
    return smoothstep(lo, hi, x);
}
`
	prog, err := CompileHLSL(src)
	if err != nil {
		t.Fatalf("CompileHLSL failed: %v", err)
	}
	out := prog.Emit()
	if !strings.Contains(out, "alu.clamp") {
		t.Error("expected alu.clamp in smoothstep expansion")
	}
	t.Logf("HLSL smoothstep IR:\n%s", out)
}

func evalFP64(prog *FP64Program, inputs map[string]float64) map[string]float64 {
	regs := make(map[string]float64)
	for name, idx := range prog.Vars {
		if v, ok := inputs[name]; ok {
			regs[fmt.Sprintf("r%d", idx)] = v
		}
	}
	for _, inst := range prog.Regs {
		switch inst.Op {
		case FP64Const:
			regs[inst.Dest] = inst.Imm
		case FP64Mov:
			regs[inst.Dest] = regs[inst.Src[0]]
		case FP64Neg:
			regs[inst.Dest] = -regs[inst.Src[0]]
		case FP64Add:
			regs[inst.Dest] = regs[inst.Src[0]] + regs[inst.Src[1]]
		case FP64Sub:
			regs[inst.Dest] = regs[inst.Src[0]] - regs[inst.Src[1]]
		case FP64Mul:
			regs[inst.Dest] = regs[inst.Src[0]] * regs[inst.Src[1]]
		case FP64Div:
			regs[inst.Dest] = regs[inst.Src[0]] / regs[inst.Src[1]]
		case FP64Min:
			regs[inst.Dest] = math.Min(regs[inst.Src[0]], regs[inst.Src[1]])
		case FP64Max:
			regs[inst.Dest] = math.Max(regs[inst.Src[0]], regs[inst.Src[1]])
		case FP64Cmp:
			l, r := regs[inst.Src[0]], regs[inst.Src[1]]
			var c bool
			switch inst.Cond {
			case "==":
				c = l == r
			case "!=":
				c = l != r
			case "<":
				c = l < r
			case ">":
				c = l > r
			case "<=":
				c = l <= r
			case ">=":
				c = l >= r
			}
			if c {
				regs[inst.Dest] = 1.0
			} else {
				regs[inst.Dest] = 0.0
			}
		}
	}
	return regs
}

func TestCompileRSqrtNumerical(t *testing.T) {
	src := "y <- sqrt(x)\n"
	for _, x := range []float64{1e6, 1024.0, 2.0, 1.0, 0.25, 1e-10, 0.0, -4.0, 9.9e300} {
		prog, err := CompileR(src)
		if err != nil {
			t.Fatalf("CompileR failed: %v", err)
		}
		regs := evalFP64(prog, map[string]float64{"x": x})
		y := regs[fmt.Sprintf("r%d", prog.Vars["y"])]
		want := math.Sqrt(math.Max(x, 0))
		if want == 0 {
			if y != 0 {
				t.Errorf("sqrt(%g): got %g, want 0", x, y)
			}
			continue
		}
		relErr := math.Abs(y-want) / want
		if relErr > 1e-12 {
			t.Errorf("sqrt(%g): got %.17g, want %.17g (rel err %g)", x, y, want, relErr)
		}
	}
}

func TestCompileRAbs(t *testing.T) {
	prog, err := CompileR("y <- abs(x)\n")
	if err != nil {
		t.Fatalf("CompileR failed: %v", err)
	}
	regs := evalFP64(prog, map[string]float64{"x": -42.5})
	y := regs[fmt.Sprintf("r%d", prog.Vars["y"])]
	if y != 42.5 {
		t.Errorf("abs(-42.5): got %g, want 42.5", y)
	}
	regs = evalFP64(prog, map[string]float64{"x": 7.25})
	y = regs[fmt.Sprintf("r%d", prog.Vars["y"])]
	if y != 7.25 {
		t.Errorf("abs(7.25): got %g, want 7.25", y)
	}
}
