package pnm

import (
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
