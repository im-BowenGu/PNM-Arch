// HLSL-to-FP32 ALU IR compiler.
// Parses a subset of HLSL and emits FP32 ALU operations targeting fp32_alu.v.
package pnm

import (
	"fmt"
	"math"
	"strconv"
	"strings"
)

// FP32ALUOp maps to fp32_alu.v op[2:0] encoding.
type FP32ALUOp int

const (
	ALULoad FP32ALUOp = iota
	ALUStore
	ALUAdd
	ALUSub
	ALUMul
	ALUDiv
	ALUMin
	ALUMax
	ALUCmp
	ALUMov
	ALUConst
	ALUDot  // dot product (expanded to mul+add chain)
	ALULerp // lerp(a,b,t) = a + t*(b-a)
	ALUClamp // clamp(x,lo,hi)
	ALURcp  // reciprocal (1/x)
)

func (o FP32ALUOp) String() string {
	switch o {
	case ALULoad:
		return "alu.load"
	case ALUStore:
		return "alu.store"
	case ALUAdd:
		return "alu.add"
	case ALUSub:
		return "alu.sub"
	case ALUMul:
		return "alu.mul"
	case ALUDiv:
		return "alu.div"
	case ALUMin:
		return "alu.min"
	case ALUMax:
		return "alu.max"
	case ALUCmp:
		return "alu.cmp"
	case ALUMov:
		return "alu.mov"
	case ALUConst:
		return "alu.const"
	case ALUDot:
		return "alu.dot"
	case ALULerp:
		return "alu.lerp"
	case ALUClamp:
		return "alu.clamp"
	case ALURcp:
		return "alu.rcp"
	default:
		return "alu???"
	}
}

// HLSLIR is a single IR instruction.
type HLSLIR struct {
	Op   FP32ALUOp
	Dest string
	Src  []string
	Imm  float32
	Cond string
}

// HLSLProgram is a sequence of FP32 ALU IR instructions.
type HLSLProgram struct {
	FuncName string
	Regs     []HLSLIR
	Vars     map[string]int
	Uniforms map[string]bool // uniform (constant) declarations
	nextReg  int
}

func newHLSLProgram(name string) *HLSLProgram {
	return &HLSLProgram{
		FuncName: name,
		Vars:     make(map[string]int),
		Uniforms: make(map[string]bool),
		nextReg:  0,
	}
}

func (p *HLSLProgram) allocReg() string {
	r := fmt.Sprintf("r%d", p.nextReg)
	p.nextReg++
	return r
}

func (p *HLSLProgram) getOrCreateReg(name string) string {
	if r, ok := p.Vars[name]; ok {
		return fmt.Sprintf("r%d", r)
	}
	reg := p.allocReg()
	p.Vars[name] = p.nextReg - 1
	return reg
}

// Emit returns the IR as a string.
func (p *HLSLProgram) Emit() string {
	var b strings.Builder
	fmt.Fprintf(&b, "# HLSL FP32 ALU IR: %s\n", p.FuncName)
	fmt.Fprintf(&b, "# %d registers, %d instructions\n\n", p.nextReg, len(p.Regs))
	for _, inst := range p.Regs {
		switch inst.Op {
		case ALUConst:
			fmt.Fprintf(&b, "%-12s %s, %.9g\n", inst.Op, inst.Dest, inst.Imm)
		case ALUCmp:
			fmt.Fprintf(&b, "%-12s %s, %s, %s, %s\n", inst.Op, inst.Dest, inst.Src[0], inst.Src[1], inst.Cond)
		case ALUStore:
			fmt.Fprintf(&b, "%-12s [%s], %s\n", inst.Op, inst.Dest, inst.Src[0])
		case ALULoad:
			fmt.Fprintf(&b, "%-12s %s, [%s]\n", inst.Op, inst.Dest, inst.Src[0])
		default:
			parts := []string{inst.Dest}
			parts = append(parts, inst.Src...)
			fmt.Fprintf(&b, "%-12s %s\n", inst.Op, strings.Join(parts, ", "))
		}
	}
	return b.String()
}

// CompileHLSL parses HLSL source code and emits FP32 ALU IR.
func CompileHLSL(src string) (*HLSLProgram, error) {
	prog := newHLSLProgram("hlsl_main")
	lines := strings.Split(src, "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		line = strings.TrimSuffix(line, ";")
		if line == "" || strings.HasPrefix(line, "//") {
			continue
		}
		// Skip preprocessor
		if strings.HasPrefix(line, "#") {
			continue
		}
		if err := compileHLSLLine(prog, line); err != nil {
			return nil, fmt.Errorf("HLSL compile error at %q: %w", line, err)
		}
	}
	return prog, nil
}

func compileHLSLLine(p *HLSLProgram, line string) error {
	// return expr
	if strings.HasPrefix(line, "return") {
		expr := strings.TrimSpace(strings.TrimPrefix(line, "return"))
		if expr != "" {
			return compileHLSLExpr(p, "_", expr)
		}
		return nil
	}
	// Type declarations: float x = expr; int y; uniform float4 light;
	if strings.HasPrefix(line, "float") || strings.HasPrefix(line, "int") || strings.HasPrefix(line, "half") {
		return compileHLSLDecl(p, line)
	}

	// Assignment: x = expr
	if idx := strings.Index(line, "="); idx > 0 && !strings.Contains(line, "==") {
		varName := strings.TrimSpace(line[:idx])
		expr := strings.TrimSpace(line[idx+1:])
		return compileHLSLExpr(p, varName, expr)
	}

	// Bare expression
	return compileHLSLExpr(p, "_", line)
}

func compileHLSLDecl(p *HLSLProgram, line string) error {
	isUniform := strings.HasPrefix(line, "uniform ")
	line = strings.TrimSpace(strings.TrimPrefix(line, "uniform "))

	// Strip type prefix
	for _, prefix := range []string{"float4x4", "float4x3", "float3x3", "float2x2", "float4", "float3", "float2", "float1", "float", "int4", "int3", "int2", "int1", "int", "half4", "half3", "half2", "half"} {
		if strings.HasPrefix(line, prefix+" ") {
			line = strings.TrimSpace(line[len(prefix):])
			break
		}
	}

	// Handle array: float a[16] = {...}
	if idx := strings.Index(line, "["); idx > 0 {
		endIdx := strings.Index(line[idx:], "]")
		if endIdx > 0 {
			line = strings.TrimSpace(line[:idx])
		}
	}

	if idx := strings.Index(line, "="); idx > 0 {
		varName := strings.TrimSpace(line[:idx])
		expr := strings.TrimSpace(line[idx+1:])
		if isUniform {
			p.Uniforms[varName] = true
		}
		return compileHLSLExpr(p, varName, expr)
	}

	varName := strings.TrimSpace(line)
	if varName != "" {
		p.getOrCreateReg(varName)
	}
	return nil
}

func compileHLSLExpr(p *HLSLProgram, varName, expr string) error {
	dest := p.getOrCreateReg(varName)

	// Vector/Type constructors: float4(...), float3(...), float2(...), int(...)
	if idx := strings.Index(expr, "("); idx > 0 {
		funcName := strings.TrimSpace(expr[:idx])
		argsStr := expr[idx+1:]
		if endIdx := strings.LastIndex(argsStr, ")"); endIdx >= 0 {
			argsStr = argsStr[:endIdx]
		}
		// Vector constructors: just use the first component as scalar
		for _, vt := range []string{"float4", "float3", "float2", "float1", "int4", "int3", "int2", "int1", "half4", "half3", "half2", "half1"} {
			if funcName == vt {
				args := splitHLSLArgs(argsStr)
				if len(args) > 0 {
					return compileHLSLExpr(p, varName, args[0])
				}
				return nil
			}
		}
		return compileHLSLCall(p, dest, funcName, argsStr)
	}

	// Ternary: cond ? a : b
	if idx := strings.Index(expr, "?"); idx > 0 {
		parts := strings.SplitN(expr[idx+1:], ":", 2)
		if len(parts) == 2 {
			cond := strings.TrimSpace(expr[:idx])
			thenExpr := strings.TrimSpace(parts[0])
			elseExpr := strings.TrimSpace(parts[1])
			// Emulate: dest = cond ? thenVal : elseVal
			// via: dest = thenVal * cmp + elseVal * (1 - cmp)
			cmpResult := p.allocReg()
			c := resolveHLSLAtom(p, cond)
			zero := p.allocReg()
			p.Regs = append(p.Regs, HLSLIR{Op: ALUConst, Dest: zero, Imm: 0.0})
			p.Regs = append(p.Regs, HLSLIR{Op: ALUCmp, Dest: cmpResult, Src: []string{c, zero}, Cond: "!="})
			one := p.allocReg()
			p.Regs = append(p.Regs, HLSLIR{Op: ALUConst, Dest: one, Imm: 1.0})
			notCmp := p.allocReg()
			p.Regs = append(p.Regs, HLSLIR{Op: ALUSub, Dest: notCmp, Src: []string{one, cmpResult}})
			thenVal := resolveHLSLAtom(p, thenExpr)
			elseVal := resolveHLSLAtom(p, elseExpr)
			thenPart := p.allocReg()
			p.Regs = append(p.Regs, HLSLIR{Op: ALUMul, Dest: thenPart, Src: []string{thenVal, cmpResult}})
			elsePart := p.allocReg()
			p.Regs = append(p.Regs, HLSLIR{Op: ALUMul, Dest: elsePart, Src: []string{elseVal, notCmp}})
			p.Regs = append(p.Regs, HLSLIR{Op: ALUAdd, Dest: dest, Src: []string{thenPart, elsePart}})
			return nil
		}
	}

	// Binary arithmetic
	if op, lhs, rhs, ok := parseHLSLBinop(expr); ok {
		l := resolveHLSLAtom(p, lhs)
		r := resolveHLSLAtom(p, rhs)
		p.Regs = append(p.Regs, HLSLIR{Op: op, Dest: dest, Src: []string{l, r}})
		return nil
	}

	// Number literal
	if val, err := strconv.ParseFloat(expr, 64); err == nil {
		p.Regs = append(p.Regs, HLSLIR{Op: ALUConst, Dest: dest, Imm: float32(val)})
		return nil
	}

	// Variable
	src := p.getOrCreateReg(strings.TrimSpace(expr))
	p.Regs = append(p.Regs, HLSLIR{Op: ALUMov, Dest: dest, Src: []string{src}})
	return nil
}

func parseHLSLBinop(expr string) (FP32ALUOp, string, string, bool) {
	// Find operator at nesting depth 0, right-to-left for precedence
	depth := 0
	for i := len(expr) - 1; i >= 0; i-- {
		switch expr[i] {
		case ')':
			depth++
		case '(':
			depth--
		case '+':
			if depth == 0 && i > 0 {
				return ALUAdd, expr[:i], expr[i+1:], true
			}
		case '-':
			if depth == 0 && i > 0 {
				return ALUSub, expr[:i], expr[i+1:], true
			}
		case '*':
			if depth == 0 {
				return ALUMul, expr[:i], expr[i+1:], true
			}
		case '/':
			if depth == 0 {
				return ALUDiv, expr[:i], expr[i+1:], true
			}
		}
	}
	return 0, "", "", false
}

func resolveHLSLAtom(p *HLSLProgram, s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return p.getOrCreateReg("_")
	}
	if val, err := strconv.ParseFloat(s, 64); err == nil {
		r := p.allocReg()
		p.Regs = append(p.Regs, HLSLIR{Op: ALUConst, Dest: r, Imm: float32(val)})
		return r
	}
	s = strings.Trim(s, "()")
	return p.getOrCreateReg(s)
}

func compileHLSLCall(p *HLSLProgram, dest, funcName, argsStr string) error {
	args := splitHLSLArgs(argsStr)
	switch funcName {
	case "dot":
		if len(args) == 2 {
			a := resolveHLSLAtom(p, args[0])
			b := resolveHLSLAtom(p, args[1])
			p.Regs = append(p.Regs, HLSLIR{Op: ALUDot, Dest: dest, Src: []string{a, b}})
			return nil
		}
	case "lerp", "mix":
		if len(args) == 3 {
			a := resolveHLSLAtom(p, args[0])
			b := resolveHLSLAtom(p, args[1])
			t := resolveHLSLAtom(p, args[2])
			p.Regs = append(p.Regs, HLSLIR{Op: ALULerp, Dest: dest, Src: []string{a, b, t}})
			return nil
		}
	case "clamp", "saturate":
		if funcName == "saturate" && len(args) == 1 {
			x := resolveHLSLAtom(p, args[0])
			lo := p.allocReg()
			hi := p.allocReg()
			p.Regs = append(p.Regs, HLSLIR{Op: ALUConst, Dest: lo, Imm: 0.0})
			p.Regs = append(p.Regs, HLSLIR{Op: ALUConst, Dest: hi, Imm: 1.0})
			p.Regs = append(p.Regs, HLSLIR{Op: ALUClamp, Dest: dest, Src: []string{x, lo, hi}})
			return nil
		}
		if len(args) == 3 {
			x := resolveHLSLAtom(p, args[0])
			lo := resolveHLSLAtom(p, args[1])
			hi := resolveHLSLAtom(p, args[2])
			p.Regs = append(p.Regs, HLSLIR{Op: ALUClamp, Dest: dest, Src: []string{x, lo, hi}})
			return nil
		}
	case "abs":
		if len(args) == 1 {
			x := resolveHLSLAtom(p, args[0])
			emitALUAbs(p, dest, x)
			return nil
		}
	case "min":
		if len(args) == 2 {
			a := resolveHLSLAtom(p, args[0])
			b := resolveHLSLAtom(p, args[1])
			p.Regs = append(p.Regs, HLSLIR{Op: ALUMin, Dest: dest, Src: []string{a, b}})
			return nil
		}
	case "max":
		if len(args) == 2 {
			a := resolveHLSLAtom(p, args[0])
			b := resolveHLSLAtom(p, args[1])
			p.Regs = append(p.Regs, HLSLIR{Op: ALUMax, Dest: dest, Src: []string{a, b}})
			return nil
		}
	case "rcp":
		if len(args) == 1 {
			x := resolveHLSLAtom(p, args[0])
			p.Regs = append(p.Regs, HLSLIR{Op: ALURcp, Dest: dest, Src: []string{x}})
			return nil
		}
	case "sqrt":
		if len(args) == 1 {
			x := resolveHLSLAtom(p, args[0])
			emitALUSqrt(p, dest, x)
			return nil
		}
	case "step":
		if len(args) == 2 {
			edge := resolveHLSLAtom(p, args[0])
			x := resolveHLSLAtom(p, args[1])
			cmpResult := p.allocReg()
			p.Regs = append(p.Regs, HLSLIR{Op: ALUCmp, Dest: cmpResult, Src: []string{x, edge}, Cond: ">="})
			p.Regs = append(p.Regs, HLSLIR{Op: ALUMov, Dest: dest, Src: []string{cmpResult}})
			return nil
		}
	case "smoothstep":
		if len(args) == 3 {
			// smoothstep(lo,hi,x) = t*t*(3-2*t) where t = clamp((x-lo)/(hi-lo), 0, 1)
			lo := resolveHLSLAtom(p, args[0])
			hi := resolveHLSLAtom(p, args[1])
			x := resolveHLSLAtom(p, args[2])
			diff := p.allocReg()
			p.Regs = append(p.Regs, HLSLIR{Op: ALUSub, Dest: diff, Src: []string{hi, lo}})
			subX := p.allocReg()
			p.Regs = append(p.Regs, HLSLIR{Op: ALUSub, Dest: subX, Src: []string{x, lo}})
			t := p.allocReg()
			p.Regs = append(p.Regs, HLSLIR{Op: ALUDiv, Dest: t, Src: []string{subX, diff}})
			zero := p.allocReg()
			one := p.allocReg()
			p.Regs = append(p.Regs, HLSLIR{Op: ALUConst, Dest: zero, Imm: 0.0})
			p.Regs = append(p.Regs, HLSLIR{Op: ALUConst, Dest: one, Imm: 1.0})
			clamped := p.allocReg()
			p.Regs = append(p.Regs, HLSLIR{Op: ALUClamp, Dest: clamped, Src: []string{t, zero, one}})
			// t*t*(3-2*t)
			tt := p.allocReg()
			p.Regs = append(p.Regs, HLSLIR{Op: ALUMul, Dest: tt, Src: []string{clamped, clamped}})
			two := p.allocReg()
			three := p.allocReg()
			p.Regs = append(p.Regs, HLSLIR{Op: ALUConst, Dest: two, Imm: 2.0})
			p.Regs = append(p.Regs, HLSLIR{Op: ALUConst, Dest: three, Imm: 3.0})
			twoT := p.allocReg()
			p.Regs = append(p.Regs, HLSLIR{Op: ALUMul, Dest: twoT, Src: []string{two, clamped}})
			paren := p.allocReg()
			p.Regs = append(p.Regs, HLSLIR{Op: ALUSub, Dest: paren, Src: []string{three, twoT}})
			p.Regs = append(p.Regs, HLSLIR{Op: ALUMul, Dest: dest, Src: []string{tt, paren}})
			return nil
		}
	case "mul":
		if len(args) == 2 {
			a := resolveHLSLAtom(p, args[0])
			b := resolveHLSLAtom(p, args[1])
			p.Regs = append(p.Regs, HLSLIR{Op: ALUMul, Dest: dest, Src: []string{a, b}})
			return nil
		}
	}
	return fmt.Errorf("unsupported HLSL intrinsic: %s", funcName)
}

func splitHLSLArgs(s string) []string {
	var args []string
	depth := 0
	cur := strings.Builder{}
	for _, c := range s {
		switch c {
		case '(':
			depth++
			cur.WriteRune(c)
		case ')':
			depth--
			cur.WriteRune(c)
		case ',':
			if depth == 0 {
				args = append(args, strings.TrimSpace(cur.String()))
				cur.Reset()
			} else {
				cur.WriteRune(c)
			}
		default:
			cur.WriteRune(c)
		}
	}
	if cur.Len() > 0 {
		args = append(args, strings.TrimSpace(cur.String()))
	}
	return args
}

func emitALUAbs(p *HLSLProgram, dest, src string) {
	neg := p.allocReg()
	zero := p.allocReg()
	p.Regs = append(p.Regs, HLSLIR{Op: ALUConst, Dest: zero, Imm: 0.0})
	p.Regs = append(p.Regs, HLSLIR{Op: ALUSub, Dest: neg, Src: []string{zero, src}})
	p.Regs = append(p.Regs, HLSLIR{Op: ALUMax, Dest: dest, Src: []string{src, neg}})
}

// emitALUSqrt lowers sqrt(x) branchlessly: a binary ladder of compare-select
// steps rescales x by 2^64 into [1,4) (tracking sqrt of the scale factor),
// then 5 Newton-Raphson iterations refine y = 0.5*(y + r/y), which converges
// to full precision for any normalized input. A final select forces exact 0
// for zero/negative inputs.
func emitALUSqrt(p *HLSLProgram, dest, src string) {
	zero := p.allocReg()
	one := p.allocReg()
	half := p.allocReg()
	p.Regs = append(p.Regs, HLSLIR{Op: ALUConst, Dest: zero, Imm: 0.0})
	p.Regs = append(p.Regs, HLSLIR{Op: ALUConst, Dest: one, Imm: 1.0})
	p.Regs = append(p.Regs, HLSLIR{Op: ALUConst, Dest: half, Imm: 0.5})
	x := p.allocReg()
	p.Regs = append(p.Regs, HLSLIR{Op: ALUMax, Dest: x, Src: []string{src, zero}})
	k := p.allocReg()
	p.Regs = append(p.Regs, HLSLIR{Op: ALUConst, Dest: k, Imm: 1.8446744073709552e+19})
	z := p.allocReg()
	p.Regs = append(p.Regs, HLSLIR{Op: ALUMul, Dest: z, Src: []string{x, k}})
	s := p.allocReg()
	g := p.allocReg()
	p.Regs = append(p.Regs, HLSLIR{Op: ALUConst, Dest: s, Imm: 1.0})
	p.Regs = append(p.Regs, HLSLIR{Op: ALUConst, Dest: g, Imm: 1.0})
	for j := 5; j >= 0; j-- {
		a := p.allocReg()
		b := p.allocReg()
		candS := p.allocReg()
		f := p.allocReg()
		inv := p.allocReg()
		sa := p.allocReg()
		sb := p.allocReg()
		candG := p.allocReg()
		ga := p.allocReg()
		gb := p.allocReg()
		p.Regs = append(p.Regs, HLSLIR{Op: ALUConst, Dest: a, Imm: float32(math.Exp2(float64(uint64(1) << uint(j+1))))})
		p.Regs = append(p.Regs, HLSLIR{Op: ALUConst, Dest: b, Imm: float32(math.Exp2(float64(uint64(1) << uint(j))))})
		p.Regs = append(p.Regs, HLSLIR{Op: ALUMul, Dest: candS, Src: []string{s, a}})
		p.Regs = append(p.Regs, HLSLIR{Op: ALUCmp, Dest: f, Src: []string{z, candS}, Cond: ">="})
		p.Regs = append(p.Regs, HLSLIR{Op: ALUSub, Dest: inv, Src: []string{one, f}})
		p.Regs = append(p.Regs, HLSLIR{Op: ALUMul, Dest: sa, Src: []string{candS, f}})
		p.Regs = append(p.Regs, HLSLIR{Op: ALUMul, Dest: sb, Src: []string{s, inv}})
		p.Regs = append(p.Regs, HLSLIR{Op: ALUAdd, Dest: s, Src: []string{sa, sb}})
		p.Regs = append(p.Regs, HLSLIR{Op: ALUMul, Dest: candG, Src: []string{g, b}})
		p.Regs = append(p.Regs, HLSLIR{Op: ALUMul, Dest: ga, Src: []string{candG, f}})
		p.Regs = append(p.Regs, HLSLIR{Op: ALUMul, Dest: gb, Src: []string{g, inv}})
		p.Regs = append(p.Regs, HLSLIR{Op: ALUAdd, Dest: g, Src: []string{ga, gb}})
	}
	invGK := p.allocReg()
	gf := p.allocReg()
	p.Regs = append(p.Regs, HLSLIR{Op: ALUConst, Dest: invGK, Imm: 2.3283064365386963e-10})
	p.Regs = append(p.Regs, HLSLIR{Op: ALUMul, Dest: gf, Src: []string{g, invGK}})
	r := p.allocReg()
	y := p.allocReg()
	q := p.allocReg()
	t := p.allocReg()
	p.Regs = append(p.Regs, HLSLIR{Op: ALUDiv, Dest: r, Src: []string{z, s}})
	p.Regs = append(p.Regs, HLSLIR{Op: ALUConst, Dest: y, Imm: 1.0})
	for i := 0; i < 5; i++ {
		p.Regs = append(p.Regs, HLSLIR{Op: ALUDiv, Dest: q, Src: []string{r, y}})
		p.Regs = append(p.Regs, HLSLIR{Op: ALUAdd, Dest: t, Src: []string{y, q}})
		p.Regs = append(p.Regs, HLSLIR{Op: ALUMul, Dest: y, Src: []string{t, half}})
	}
	out := p.allocReg()
	zf := p.allocReg()
	nz := p.allocReg()
	p.Regs = append(p.Regs, HLSLIR{Op: ALUMul, Dest: out, Src: []string{y, gf}})
	p.Regs = append(p.Regs, HLSLIR{Op: ALUCmp, Dest: zf, Src: []string{x, zero}, Cond: "=="})
	p.Regs = append(p.Regs, HLSLIR{Op: ALUSub, Dest: nz, Src: []string{one, zf}})
	p.Regs = append(p.Regs, HLSLIR{Op: ALUMul, Dest: dest, Src: []string{out, nz}})
}
