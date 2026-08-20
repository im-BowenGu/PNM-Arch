// R-to-FP64 IR compiler.
// Parses a subset of R and emits FP64 operations targeting fp64_fma.v.
package pnm

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// FP64 opcode (maps to fp64_fma.v + fp32_alu.v operations, widened to 64-bit).
type FP64Op int

const (
	FP64Load FP64Op = iota
	FP64Store
	FP64Add
	FP64Sub
	FP64Mul
	FP64FMA
	FP64Div
	FP64Min
	FP64Max
	FP64Cmp
	FP64Mov
	FP64Const
	FP64Neg
)

func (o FP64Op) String() string {
	switch o {
	case FP64Load:
		return "f64.load"
	case FP64Store:
		return "f64.store"
	case FP64Add:
		return "f64.add"
	case FP64Sub:
		return "f64.sub"
	case FP64Mul:
		return "f64.mul"
	case FP64FMA:
		return "f64.fma"
	case FP64Div:
		return "f64.div"
	case FP64Min:
		return "f64.min"
	case FP64Max:
		return "f64.max"
	case FP64Cmp:
		return "f64.cmp"
	case FP64Mov:
		return "f64.mov"
	case FP64Const:
		return "f64.const"
	case FP64Neg:
		return "f64.neg"
	default:
		return "f64???"
	}
}

// FP64IR is a single IR instruction.
type FP64IR struct {
	Op   FP64Op
	Dest string   // destination register
	Src  []string // source registers or immediates
	Imm  float64  // literal constant (FP64)
	Cond string   // comparison condition for CMP: "==", "!=", "<", ">", "<=", ">="
}

// FP64Program is a sequence of IR instructions.
type FP64Program struct {
	FuncName string
	Regs     []FP64IR
	Vars     map[string]int // variable name -> register number
	nextReg  int
}

func newFP64Program(name string) *FP64Program {
	return &FP64Program{
		FuncName: name,
		Vars:     make(map[string]int),
		nextReg:  0,
	}
}

func (p *FP64Program) allocReg() string {
	r := fmt.Sprintf("r%d", p.nextReg)
	p.nextReg++
	return r
}

func (p *FP64Program) getOrCreateReg(name string) string {
	if r, ok := p.Vars[name]; ok {
		return fmt.Sprintf("r%d", r)
	}
	reg := p.allocReg()
	p.Vars[name] = p.nextReg - 1
	return reg
}

// Emit returns the IR as a string.
func (p *FP64Program) Emit() string {
	var b strings.Builder
	fmt.Fprintf(&b, "# FP64 IR: %s\n", p.FuncName)
	fmt.Fprintf(&b, "# %d registers, %d instructions\n\n", p.nextReg, len(p.Regs))
	for _, inst := range p.Regs {
		switch inst.Op {
		case FP64Const:
			fmt.Fprintf(&b, "%-10s %s, %.17g\n", inst.Op, inst.Dest, inst.Imm)
		case FP64Cmp:
			fmt.Fprintf(&b, "%-10s %s, %s, %s, %s\n", inst.Op, inst.Dest, inst.Src[0], inst.Src[1], inst.Cond)
		case FP64Store:
			fmt.Fprintf(&b, "%-10s [%s], %s\n", inst.Op, inst.Dest, inst.Src[0])
		case FP64Load:
			fmt.Fprintf(&b, "%-10s %s, [%s]\n", inst.Op, inst.Dest, inst.Src[0])
		default:
			parts := []string{inst.Dest}
			parts = append(parts, inst.Src...)
			fmt.Fprintf(&b, "%-10s %s\n", inst.Op, strings.Join(parts, ", "))
		}
	}
	return b.String()
}

// R compiler: parses a subset of R and emits FP64 IR.

var (
	rAssignRe  = regexp.MustCompile(`^\s*(\w+)\s*<-\s*(.+)\s*$`)
	rExprRe    = regexp.MustCompile(`^\s*(.+?)\s*([+\-*/])\s*(.+)\s*$`)
	rFuncRe    = regexp.MustCompile(`^\s*(\w+)\s*\((.+)\)\s*$`)
	rNumRe     = regexp.MustCompile(`^\s*(-?\d+\.?\d*(?:[eE][+-]?\d+)?)\s*$`)
	rVarRe     = regexp.MustCompile(`^\s*(\w+)\s*$`)
	rCompareRe = regexp.MustCompile(`^\s*(.+?)\s*(==|!=|<=|>=|<|>)\s*(.+)\s*$`)
)

// CompileR parses R source code and emits FP64 IR.
func CompileR(src string) (*FP64Program, error) {
	prog := newFP64Program("r_main")
	lines := strings.Split(src, "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if err := compileRLine(prog, line); err != nil {
			return nil, fmt.Errorf("R compile error at %q: %w", line, err)
		}
	}
	return prog, nil
}

func compileRLine(p *FP64Program, line string) error {
	// Assignment: x <- expr
	if m := rAssignRe.FindStringSubmatch(line); m != nil {
		varName := m[1]
		expr := strings.TrimSpace(m[2])
		return compileRAssign(p, varName, expr)
	}
	// Bare expression (side-effect)
	return compileRAssign(p, "_", line)
}

func compileRAssign(p *FP64Program, varName, expr string) error {
	dest := p.getOrCreateReg(varName)

	// Comparison: a == b, a < b, etc.
	if m := rCompareRe.FindStringSubmatch(expr); m != nil {
		lhs := resolveRAtom(p, strings.TrimSpace(m[1]))
		rhs := resolveRAtom(p, strings.TrimSpace(m[3]))
		p.Regs = append(p.Regs, FP64IR{Op: FP64Cmp, Dest: dest, Src: []string{lhs, rhs}, Cond: m[2]})
		return nil
	}

	// Binary arithmetic: a op b
	if m := rExprRe.FindStringSubmatch(expr); m != nil {
		lhs := resolveRAtom(p, strings.TrimSpace(m[1]))
		rhs := resolveRAtom(p, strings.TrimSpace(m[3]))
		op := rArithOp(m[2])
		if op == FP64Neg {
			// subtraction: negate RHS, then add
			negRHS := p.allocReg()
			p.Regs = append(p.Regs, FP64IR{Op: FP64Neg, Dest: negRHS, Src: []string{rhs}})
			p.Regs = append(p.Regs, FP64IR{Op: FP64Add, Dest: dest, Src: []string{lhs, negRHS}})
		} else {
			p.Regs = append(p.Regs, FP64IR{Op: op, Dest: dest, Src: []string{lhs, rhs}})
		}
		return nil
	}

	// Function call: f(args)
	if m := rFuncRe.FindStringSubmatch(expr); m != nil {
		return compileRCall(p, dest, m[1], m[2])
	}

	// Number literal
	if m := rNumRe.FindStringSubmatch(expr); m != nil {
		val, _ := strconv.ParseFloat(m[1], 64)
		p.Regs = append(p.Regs, FP64IR{Op: FP64Const, Dest: dest, Imm: val})
		return nil
	}

	// Variable reference
	if m := rVarRe.FindStringSubmatch(expr); m != nil {
		src := p.getOrCreateReg(m[1])
		p.Regs = append(p.Regs, FP64IR{Op: FP64Mov, Dest: dest, Src: []string{src}})
		return nil
	}

	return fmt.Errorf("unsupported R expression: %s", expr)
}

func resolveRAtom(p *FP64Program, s string) string {
	s = strings.TrimSpace(s)
	if rNumRe.MatchString(s) {
		r := p.allocReg()
		val, _ := strconv.ParseFloat(s, 64)
		p.Regs = append(p.Regs, FP64IR{Op: FP64Const, Dest: r, Imm: val})
		return r
	}
	return p.getOrCreateReg(s)
}

func rArithOp(op string) FP64Op {
	switch op {
	case "+":
		return FP64Add
	case "-":
		return FP64Neg // sentinel: handled specially in compileRAssign
	case "*":
		return FP64Mul
	case "/":
		return FP64Div
	default:
		return FP64Add
	}
}

func compileRCall(p *FP64Program, dest, funcName, args string) error {
	argList := splitRArgs(args)
	switch funcName {
	case "sum", "mean", "min", "max", "prod":
		return compileRAgg(p, dest, funcName, argList)
	case "paste":
		return nil // string op, skip
	case "c":
		return nil // vector literal, skip
	case "sqrt":
		// sqrt(x) via 4 iterations of Newton-Raphson: y = 0.5*(y + x/y)
		if len(argList) == 1 {
			src := resolveRAtom(p, argList[0])
			y := p.allocReg()
			half := p.allocReg()
			xDivY := p.allocReg()
			sum := p.allocReg()
			p.Regs = append(p.Regs, FP64IR{Op: FP64Const, Dest: y, Imm: 1.0})
			p.Regs = append(p.Regs, FP64IR{Op: FP64Const, Dest: half, Imm: 0.5})
			for i := 0; i < 4; i++ {
				p.Regs = append(p.Regs, FP64IR{Op: FP64Div, Dest: xDivY, Src: []string{src, y}})
				p.Regs = append(p.Regs, FP64IR{Op: FP64Add, Dest: sum, Src: []string{y, xDivY}})
				p.Regs = append(p.Regs, FP64IR{Op: FP64Mul, Dest: y, Src: []string{sum, half}})
			}
			p.Regs = append(p.Regs, FP64IR{Op: FP64Mov, Dest: dest, Src: []string{y}})
			return nil
		}
	case "abs":
		if len(argList) == 1 {
			src := resolveRAtom(p, argList[0])
			zero := p.allocReg()
			p.Regs = append(p.Regs, FP64IR{Op: FP64Const, Dest: zero, Imm: 0.0})
			p.Regs = append(p.Regs, FP64IR{Op: FP64Max, Dest: dest, Src: []string{src, zero}})
			return nil
		}
	}
	return fmt.Errorf("unsupported R function: %s", funcName)
}

func compileRAgg(p *FP64Program, dest, op string, args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("empty argument list for %s", op)
	}
	src := resolveRAtom(p, args[0])
	switch op {
	case "sum", "prod":
		acc := p.allocReg()
		initVal := 0.0
		if op == "prod" {
			initVal = 1.0
		}
		p.Regs = append(p.Regs, FP64IR{Op: FP64Const, Dest: acc, Imm: initVal})
		binOp := FP64Add
		if op == "prod" {
			binOp = FP64Mul
		}
		for _, a := range args {
			v := resolveRAtom(p, a)
			p.Regs = append(p.Regs, FP64IR{Op: binOp, Dest: acc, Src: []string{acc, v}})
		}
		p.Regs = append(p.Regs, FP64IR{Op: FP64Mov, Dest: dest, Src: []string{acc}})
	case "min", "max":
		aggOp := FP64Min
		if op == "max" {
			aggOp = FP64Max
		}
		acc := p.allocReg()
		p.Regs = append(p.Regs, FP64IR{Op: FP64Mov, Dest: acc, Src: []string{src}})
		for i := 1; i < len(args); i++ {
			v := resolveRAtom(p, args[i])
			p.Regs = append(p.Regs, FP64IR{Op: aggOp, Dest: acc, Src: []string{acc, v}})
		}
		p.Regs = append(p.Regs, FP64IR{Op: FP64Mov, Dest: dest, Src: []string{acc}})
	case "mean":
		n := float64(len(args))
		sumReg := p.allocReg()
		p.Regs = append(p.Regs, FP64IR{Op: FP64Const, Dest: sumReg, Imm: 0.0})
		for _, a := range args {
			v := resolveRAtom(p, a)
			p.Regs = append(p.Regs, FP64IR{Op: FP64Add, Dest: sumReg, Src: []string{sumReg, v}})
		}
		nReg := p.allocReg()
		p.Regs = append(p.Regs, FP64IR{Op: FP64Const, Dest: nReg, Imm: n})
		p.Regs = append(p.Regs, FP64IR{Op: FP64Div, Dest: dest, Src: []string{sumReg, nReg}})
	}
	return nil
}

func splitRArgs(s string) []string {
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
