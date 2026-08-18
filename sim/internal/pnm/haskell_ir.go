// Haskell-to-FP64 IR compiler.
// Parses a subset of Haskell and emits FP64 operations targeting fp64_fma.v.
package pnm

import (
	"fmt"
	"strconv"
	"strings"
)

// HaskellProgram wraps FP64Program with Haskell-specific function tracking.
type HaskellProgram struct {
	*FP64Program
	Funcs map[string]*HaskellFunc
}

// HaskellFunc represents a compiled Haskell function.
type HaskellFunc struct {
	Name string
	Args []string
	Body []FP64IR
}

func newHaskellProgram(name string) *HaskellProgram {
	return &HaskellProgram{
		FP64Program: newFP64Program(name),
		Funcs:       make(map[string]*HaskellFunc),
	}
}

// Emit returns the IR as a string.
func (p *HaskellProgram) Emit() string {
	var b strings.Builder
	fmt.Fprintf(&b, "# Haskell FP64 IR: %s\n", p.FuncName)
	fmt.Fprintf(&b, "# %d functions defined\n\n", len(p.Funcs))
	for _, fn := range p.Funcs {
		fmt.Fprintf(&b, "func %s(%s)\n", fn.Name, strings.Join(fn.Args, ", "))
		for _, inst := range fn.Body {
			emitFP64Inst(&b, inst)
		}
		fmt.Fprintf(&b, "end\n\n")
	}
	if len(p.Regs) > 0 {
		fmt.Fprintf(&b, "# main body\n")
		for _, inst := range p.Regs {
			emitFP64Inst(&b, inst)
		}
	}
	return b.String()
}

func emitFP64Inst(b *strings.Builder, inst FP64IR) {
	switch inst.Op {
	case FP64Const:
		fmt.Fprintf(b, "  %-10s %s, %.17g\n", inst.Op, inst.Dest, inst.Imm)
	case FP64Cmp:
		fmt.Fprintf(b, "  %-10s %s, %s, %s, %s\n", inst.Op, inst.Dest, inst.Src[0], inst.Src[1], inst.Cond)
	case FP64Store:
		fmt.Fprintf(b, "  %-10s [%s], %s\n", inst.Op, inst.Dest, inst.Src[0])
	case FP64Load:
		fmt.Fprintf(b, "  %-10s %s, [%s]\n", inst.Op, inst.Dest, inst.Src[0])
	default:
		parts := []string{inst.Dest}
		parts = append(parts, inst.Src...)
		fmt.Fprintf(b, "  %-10s %s\n", inst.Op, strings.Join(parts, ", "))
	}
}

// CompileHaskell parses Haskell source code and emits FP64 IR.
func CompileHaskell(src string) (*HaskellProgram, error) {
	prog := newHaskellProgram("haskell_main")
	lines := strings.Split(src, "\n")
	i := 0
	for i < len(lines) {
		line := strings.TrimSpace(lines[i])
		if line == "" || strings.HasPrefix(line, "--") {
			i++
			continue
		}
		// Function definition: f x y = expr
		if strings.Contains(line, "=") && !strings.HasPrefix(line, "let") {
			n, err := compileHaskellFunc(prog, lines, i)
			if err != nil {
				return nil, err
			}
			i += n
			continue
		}
		// let binding or expression
		if err := compileHaskellLine(prog, line); err != nil {
			return nil, fmt.Errorf("Haskell compile error at %q: %w", line, err)
		}
		i++
	}
	return prog, nil
}

func compileHaskellFunc(p *HaskellProgram, lines []string, start int) (int, error) {
	line := strings.TrimSpace(lines[start])
	// Parse: f x y = expr  or  f x y = do ... in ...
	parts := strings.SplitN(line, "=", 2)
	if len(parts) != 2 {
		return 0, fmt.Errorf("invalid Haskell function definition: %s", line)
	}
	left := strings.TrimSpace(parts[0])
	right := strings.TrimSpace(parts[1])

	// Extract function name and args
	leftParts := strings.Fields(left)
	if len(leftParts) == 0 {
		return 0, fmt.Errorf("empty left-hand side in: %s", line)
	}
	funcName := leftParts[0]
	args := leftParts[1:]

	// Save parent scope
	savedVars := make(map[string]int)
	for k, v := range p.Vars {
		savedVars[k] = v
	}
	savedRegs := make([]FP64IR, len(p.Regs))
	copy(savedRegs, p.Regs)
	regBase := len(p.Regs)

	p.Vars = make(map[string]int)
	for _, a := range args {
		p.getOrCreateReg(a)
	}

	// Check for multi-line do block
	if right == "do" {
		endIdx := start + 1
		var bodyLines []string
		for endIdx < len(lines) {
			l := strings.TrimSpace(lines[endIdx])
			if l == "" || strings.HasPrefix(l, "--") {
				endIdx++
				continue
			}
			if strings.HasPrefix(l, "in ") || strings.HasPrefix(l, "in\t") {
				break
			}
			bodyLines = append(bodyLines, l)
			endIdx++
		}
		for _, bl := range bodyLines {
			if err := compileHaskellLine(p, bl); err != nil {
				return endIdx - start, err
			}
		}
	} else {
		if err := compileHaskellLine(p, right); err != nil {
			return 1, err
		}
	}

	// Capture generated instructions
	fn := &HaskellFunc{
		Name: funcName,
		Args: args,
		Body: make([]FP64IR, len(p.Regs)-regBase),
	}
	copy(fn.Body, p.Regs[regBase:])
	p.Funcs[funcName] = fn

	// Restore parent scope
	p.Regs = savedRegs
	p.Vars = savedVars
	return 1, nil
}

func compileHaskellLine(p *HaskellProgram, line string) error {
	if strings.HasPrefix(line, "let") {
		line = strings.TrimSpace(strings.TrimPrefix(line, "let"))
	}
	if strings.HasPrefix(line, "in") {
		line = strings.TrimSpace(strings.TrimPrefix(line, "in"))
	}

	if idx := strings.Index(line, "="); idx > 0 && !strings.Contains(line, "==") {
		varName := strings.TrimSpace(line[:idx])
		expr := strings.TrimSpace(line[idx+1:])
		return compileHaskellExpr(p, varName, expr)
	}

	return compileHaskellExpr(p, "_", line)
}

func compileHaskellExpr(p *HaskellProgram, varName, expr string) error {
	dest := p.getOrCreateReg(varName)

	if idx := strings.Index(expr, "|"); idx > 0 {
		expr = strings.TrimSpace(expr[:idx])
	}
	if idx := strings.Index(expr, "`when`"); idx > 0 {
		expr = strings.TrimSpace(expr[:idx])
	}

	if strings.HasPrefix(expr, "if") {
		return compileHaskellIf(p, dest, expr)
	}

	if op, lhs, rhs, ok := parseHaskellBinop(expr); ok {
		l := resolveHaskellAtom(p, lhs)
		r := resolveHaskellAtom(p, rhs)
		p.Regs = append(p.Regs, FP64IR{Op: op, Dest: dest, Src: []string{l, r}})
		return nil
	}

	if idx := findHaskellCmp(expr); idx >= 0 {
		lhs := strings.TrimSpace(expr[:idx])
		rest := strings.TrimSpace(expr[idx:])
		cond, rhs := parseHaskellCond(rest)
		l := resolveHaskellAtom(p, lhs)
		r := resolveHaskellAtom(p, rhs)
		p.Regs = append(p.Regs, FP64IR{Op: FP64Cmp, Dest: dest, Src: []string{l, r}, Cond: cond})
		return nil
	}

	if strings.Contains(expr, " ") || strings.HasSuffix(expr, ")") {
		parts := strings.SplitN(expr, " ", 2)
		funcName := strings.TrimSpace(parts[0])
		args := ""
		if len(parts) > 1 {
			args = strings.TrimSpace(parts[1])
		}
		return compileHaskellCall(p, dest, funcName, args)
	}

	if val, err := strconv.ParseFloat(expr, 64); err == nil {
		p.Regs = append(p.Regs, FP64IR{Op: FP64Const, Dest: dest, Imm: val})
		return nil
	}

	src := p.getOrCreateReg(expr)
	p.Regs = append(p.Regs, FP64IR{Op: FP64Mov, Dest: dest, Src: []string{src}})
	return nil
}

func compileHaskellIf(p *HaskellProgram, dest, expr string) error {
	parts := strings.Fields(expr)
	if len(parts) >= 5 {
		cond := resolveHaskellAtom(p, parts[1])
		thenVal := resolveHaskellAtom(p, parts[3])
		zero := p.allocReg()
		p.Regs = append(p.Regs, FP64IR{Op: FP64Const, Dest: zero, Imm: 0.0})
		cmpResult := p.allocReg()
		p.Regs = append(p.Regs, FP64IR{Op: FP64Cmp, Dest: cmpResult, Src: []string{cond, zero}, Cond: "!="})
		p.Regs = append(p.Regs, FP64IR{Op: FP64Mov, Dest: dest, Src: []string{thenVal}})
	}
	return nil
}

func parseHaskellBinop(expr string) (FP64Op, string, string, bool) {
	depth := 0
	for i := 0; i < len(expr)-1; i++ {
		switch expr[i] {
		case '(':
			depth++
		case ')':
			depth--
		case '+':
			if depth == 0 {
				return FP64Add, expr[:i], expr[i+1:], true
			}
		case '*':
			if depth == 0 {
				return FP64Mul, expr[:i], expr[i+1:], true
			}
		case '/':
			if depth == 0 && i > 0 && expr[i-1] != '*' {
				return FP64Div, expr[:i], expr[i+1:], true
			}
		case '-':
			if depth == 0 && i > 0 {
				return FP64Add, expr[:i], "-" + expr[i+1:], true
			}
		}
	}
	return 0, "", "", false
}

func findHaskellCmp(expr string) int {
	cmps := []string{"==", "/=", "<=", ">=", "<", ">"}
	for _, c := range cmps {
		idx := strings.Index(expr, c)
		if idx > 0 {
			return idx
		}
	}
	return -1
}

func parseHaskellCond(s string) (string, string) {
	s = strings.TrimSpace(s)
	cmps := []string{"==", "/=", "<=", ">=", "<", ">"}
	for _, c := range cmps {
		if idx := strings.Index(s, c); idx > 0 {
			return c, strings.TrimSpace(s[idx+len(c):])
		}
	}
	return "==", s
}

func resolveHaskellAtom(p *HaskellProgram, s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return p.getOrCreateReg("_")
	}
	if val, err := strconv.ParseFloat(s, 64); err == nil {
		r := p.allocReg()
		p.Regs = append(p.Regs, FP64IR{Op: FP64Const, Dest: r, Imm: val})
		return r
	}
	s = strings.Trim(s, "()")
	return p.getOrCreateReg(s)
}

func compileHaskellCall(p *HaskellProgram, dest, funcName, args string) error {
	argList := splitHaskellArgs(args)
	switch funcName {
	case "sum", "product", "minimum", "maximum":
		return compileHaskellAgg(p, dest, funcName, argList)
	case "abs":
		if len(argList) == 1 {
			src := resolveHaskellAtom(p, argList[0])
			zero := p.allocReg()
			p.Regs = append(p.Regs, FP64IR{Op: FP64Const, Dest: zero, Imm: 0.0})
			p.Regs = append(p.Regs, FP64IR{Op: FP64Max, Dest: dest, Src: []string{src, zero}})
			return nil
		}
	case "sqrt":
		if len(argList) == 1 {
			src := resolveHaskellAtom(p, argList[0])
			half := p.allocReg()
			p.Regs = append(p.Regs, FP64IR{Op: FP64Const, Dest: half, Imm: 0.5})
			p.Regs = append(p.Regs, FP64IR{Op: FP64Mul, Dest: dest, Src: []string{src, half}})
			return nil
		}
	case "id":
		if len(argList) == 1 {
			src := resolveHaskellAtom(p, argList[0])
			p.Regs = append(p.Regs, FP64IR{Op: FP64Mov, Dest: dest, Src: []string{src}})
			return nil
		}
	case "const":
		if len(argList) >= 1 {
			src := resolveHaskellAtom(p, argList[0])
			p.Regs = append(p.Regs, FP64IR{Op: FP64Mov, Dest: dest, Src: []string{src}})
			return nil
		}
	}
	if fn, ok := p.Funcs[funcName]; ok {
		for i, arg := range argList {
			if i < len(fn.Args) {
				src := resolveHaskellAtom(p, arg)
				dst := p.getOrCreateReg(fn.Args[i])
				p.Regs = append(p.Regs, FP64IR{Op: FP64Mov, Dest: dst, Src: []string{src}})
			}
		}
		for _, inst := range fn.Body {
			p.Regs = append(p.Regs, inst)
		}
		return nil
	}
	return fmt.Errorf("unsupported Haskell function: %s", funcName)
}

func compileHaskellAgg(p *HaskellProgram, dest, op string, args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("empty argument list for %s", op)
	}
	src := resolveHaskellAtom(p, args[0])
	switch op {
	case "sum", "product":
		acc := p.allocReg()
		initVal := 0.0
		if op == "product" {
			initVal = 1.0
		}
		p.Regs = append(p.Regs, FP64IR{Op: FP64Const, Dest: acc, Imm: initVal})
		binOp := FP64Add
		if op == "product" {
			binOp = FP64Mul
		}
		for _, a := range args {
			v := resolveHaskellAtom(p, a)
			p.Regs = append(p.Regs, FP64IR{Op: binOp, Dest: acc, Src: []string{acc, v}})
		}
		p.Regs = append(p.Regs, FP64IR{Op: FP64Mov, Dest: dest, Src: []string{acc}})
	case "minimum", "maximum":
		aggOp := FP64Min
		if op == "maximum" {
			aggOp = FP64Max
		}
		acc := p.allocReg()
		p.Regs = append(p.Regs, FP64IR{Op: FP64Mov, Dest: acc, Src: []string{src}})
		for i := 1; i < len(args); i++ {
			v := resolveHaskellAtom(p, args[i])
			p.Regs = append(p.Regs, FP64IR{Op: aggOp, Dest: acc, Src: []string{acc, v}})
		}
		p.Regs = append(p.Regs, FP64IR{Op: FP64Mov, Dest: dest, Src: []string{acc}})
	}
	_ = src
	return nil
}

func splitHaskellArgs(s string) []string {
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
		case ' ':
			if depth == 0 && cur.Len() > 0 {
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
