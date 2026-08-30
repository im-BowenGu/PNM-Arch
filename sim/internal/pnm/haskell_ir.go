// Haskell-to-FP64 IR compiler.
// Parses a subset of Haskell and emits FP64 operations targeting fp64_fma.v.
package pnm

import (
	"fmt"
	"sort"
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
	Name     string
	Args     []string
	ArgRegs  []string // definition-time register holding each argument
	Body     []FP64IR
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
	// Iterate in sorted name order so Emit() output is deterministic
	// regardless of Go's randomized map iteration order.
	names := make([]string, 0, len(p.Funcs))
	for name := range p.Funcs {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		fn := p.Funcs[name]
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
	case FP64Neg:
		fmt.Fprintf(b, "  %-10s %s, %s\n", inst.Op, inst.Dest, inst.Src[0])
	case FP64Sub:
		fmt.Fprintf(b, "  %-10s %s, %s, %s\n", inst.Op, inst.Dest, inst.Src[0], inst.Src[1])
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

	// Record the definition-time register for each argument so an inlining
	// call site can remap the body's reads of those registers to the actual
	// call-time values (otherwise the inlined body reads stale definition-time
	// registers that are never written at the call site).
	argRegs := make([]string, len(args))
	for i, a := range args {
		if r, ok := p.Vars[a]; ok {
			argRegs[i] = fmt.Sprintf("r%d", r)
		}
	}

	// Check for multi-line do block
	if right == "do" {
		endIdx := start + 1
		var bodyLines []string
		inExpr := ""
		for endIdx < len(lines) {
			l := strings.TrimSpace(lines[endIdx])
			if l == "" || strings.HasPrefix(l, "--") {
				endIdx++
				continue
			}
			if strings.HasPrefix(l, "in ") || strings.HasPrefix(l, "in\t") {
				inExpr = strings.TrimSpace(l[len("in"):])
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
		// A do block returns the value of its `in <expr>` tail (the let
		// bindings are scoped to the block).  Compile it so the function
		// body's last instruction computes the do-block result instead of
		// silently discarding the `in` expression.
		if inExpr != "" {
			if err := compileHaskellLine(p, inExpr); err != nil {
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
		Name:    funcName,
		Args:    args,
		ArgRegs: argRegs,
		Body:    make([]FP64IR, len(p.Regs)-regBase),
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
	return compileHaskellExprTo(p, dest, expr)
}

// compileHaskellExprTo compiles a Haskell expression into the given destination
// register.  It is also used recursively by resolveHaskellAtom so that a
// compound operand (e.g. "b - c" in "f a b c = a - b - c") is fully lowered
// instead of being treated as a bare variable name.
func compileHaskellExprTo(p *HaskellProgram, dest, expr string) error {
	if idx := strings.Index(expr, "|"); idx > 0 {
		expr = strings.TrimSpace(expr[:idx])
	}
	if idx := strings.Index(expr, "`when`"); idx > 0 {
		expr = strings.TrimSpace(expr[:idx])
	}
	expr = stripOuterParens(expr)

	if strings.HasPrefix(expr, "if") {
		return compileHaskellIf(p, dest, expr)
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

	if opCh, lhs, rhs, ok := splitArith(expr); ok {
		op := haskellArithOp(opCh)
		l := resolveHaskellAtom(p, lhs)
		r := resolveHaskellAtom(p, rhs)
		p.Regs = append(p.Regs, FP64IR{Op: op, Dest: dest, Src: []string{l, r}})
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

	if strings.TrimSpace(expr) == "" {
		return fmt.Errorf("unsupported Haskell expression: %q", expr)
	}

	src := p.getOrCreateReg(expr)
	p.Regs = append(p.Regs, FP64IR{Op: FP64Mov, Dest: dest, Src: []string{src}})
	return nil
}

func compileHaskellIf(p *HaskellProgram, dest, expr string) error {
	condExpr, thenStr, elseStr, ok := parseHaskellIf(expr)
	if !ok {
		return fmt.Errorf("malformed if-then-else: %s", expr)
	}
	zero := p.allocReg()
	one := p.allocReg()
	p.Regs = append(p.Regs, FP64IR{Op: FP64Const, Dest: zero, Imm: 0.0})
	p.Regs = append(p.Regs, FP64IR{Op: FP64Const, Dest: one, Imm: 1.0})
	// Compile the full condition expression (e.g. "a > b") to a register, then
	// normalize it to a 0.0/1.0 selector so arithmetic and comparison
	// conditions both work.
	condReg := p.allocReg()
	if err := compileHaskellExprTo(p, condReg, condExpr); err != nil {
		return err
	}
	sel := p.allocReg()
	p.Regs = append(p.Regs, FP64IR{Op: FP64Cmp, Dest: sel, Src: []string{condReg, zero}, Cond: "!="})
	// Emulate: dest = thenVal * sel + elseVal * (1 - sel)
	thenVal := resolveHaskellAtom(p, thenStr)
	elseVal := resolveHaskellAtom(p, elseStr)
	notSel := p.allocReg()
	p.Regs = append(p.Regs, FP64IR{Op: FP64Sub, Dest: notSel, Src: []string{one, sel}})
	thenPart := p.allocReg()
	p.Regs = append(p.Regs, FP64IR{Op: FP64Mul, Dest: thenPart, Src: []string{thenVal, sel}})
	elsePart := p.allocReg()
	p.Regs = append(p.Regs, FP64IR{Op: FP64Mul, Dest: elsePart, Src: []string{elseVal, notSel}})
	p.Regs = append(p.Regs, FP64IR{Op: FP64Add, Dest: dest, Src: []string{thenPart, elsePart}})
	return nil
}

// parseHaskellIf splits "if COND then THENVAL else ELSEVAL" into its three
// sub-expressions, treating "then"/"else" as space-delimited keywords.
func parseHaskellIf(expr string) (cond, thenStr, elseStr string, ok bool) {
	rest := strings.TrimSpace(strings.TrimPrefix(expr, "if"))
	thenIdx := findHaskellToken(rest, "then")
	if thenIdx < 0 {
		return "", "", "", false
	}
	cond = strings.TrimSpace(rest[:thenIdx])
	afterThen := strings.TrimSpace(rest[thenIdx+len("then"):])
	elseIdx := findHaskellToken(afterThen, "else")
	if elseIdx < 0 {
		return "", "", "", false
	}
	thenStr = strings.TrimSpace(afterThen[:elseIdx])
	elseStr = strings.TrimSpace(afterThen[elseIdx+len("else"):])
	if cond == "" || thenStr == "" || elseStr == "" {
		return "", "", "", false
	}
	return cond, thenStr, elseStr, true
}

// findHaskellToken locates the keyword kw as a standalone space-delimited token
// in s, returning its starting index or -1.  It does not match inside a larger
// identifier (e.g. it will not match "the" inside "these").
func findHaskellToken(s, kw string) int {
	for i := 0; ; {
		idx := strings.Index(s[i:], kw)
		if idx < 0 {
			return -1
		}
		abs := i + idx
		before := abs == 0 || s[abs-1] == ' ' || s[abs-1] == '('
		after := abs+len(kw) >= len(s) || s[abs+len(kw)] == ' ' || s[abs+len(kw)] == '('
		if before && after {
			return abs
		}
		i = abs + len(kw)
	}
}

// haskellArithOp maps an arithmetic operator character from splitArith to the
// corresponding FP64 opcode.  Haskell subtraction is a native FP64Sub (the R
// frontend lowers it to a negate + add instead).
func haskellArithOp(c byte) FP64Op {
	switch c {
	case '+':
		return FP64Add
	case '-':
		return FP64Sub
	case '*':
		return FP64Mul
	case '/':
		return FP64Div
	}
	return FP64Add
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
		if idx := strings.Index(s, c); idx >= 0 {
			return c, strings.TrimSpace(s[idx+len(c):])
		}
	}
	return "==", s
}

func resolveHaskellAtom(p *HaskellProgram, s string) string {
	s = stripOuterParens(s)
	s = strings.TrimSpace(s)
	if s == "" {
		return p.getOrCreateReg("_")
	}
	if val, err := strconv.ParseFloat(s, 64); err == nil {
		r := p.allocReg()
		p.Regs = append(p.Regs, FP64IR{Op: FP64Const, Dest: r, Imm: val})
		return r
	}
	// Unary minus on a bare variable (e.g. "-b" in "2.0 * -b") is negated
	// here via a native FP64Neg, rather than being passed through to
	// compileHaskellExprTo where the trailing Variable case would emit a
	// read of an unwritten register named "-b".
	if strings.HasPrefix(s, "-") && isSimpleIdent(strings.TrimPrefix(s, "-")) {
		neg := p.allocReg()
		p.Regs = append(p.Regs, FP64IR{Op: FP64Neg, Dest: neg, Src: []string{p.getOrCreateReg(strings.TrimPrefix(s, "-"))}})
		return neg
	}
	// A bare identifier is a register reference; anything else (a parenthesized
	// or arithmetic operand such as "(b + c)") must be compiled as an expression.
	if isSimpleIdent(s) {
		return p.getOrCreateReg(s)
	}
	r := p.allocReg()
	if err := compileHaskellExprTo(p, r, s); err != nil {
		return p.getOrCreateReg(s)
	}
	return r
}

// isSimpleIdent reports whether s is a plain variable/parameter name.
func isSimpleIdent(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_') {
			return false
		}
	}
	return true
}

func compileHaskellCall(p *HaskellProgram, dest, funcName, args string) error {
	argList := splitHaskellArgs(args)
	switch funcName {
	case "sum", "product", "minimum", "maximum":
		return compileHaskellAgg(p, dest, funcName, argList)
	case "abs":
		if len(argList) == 1 {
			src := resolveHaskellAtom(p, argList[0])
			emitFP64Abs(p.FP64Program, dest, src)
			return nil
		}
	case "sqrt":
		if len(argList) == 1 {
			src := resolveHaskellAtom(p, argList[0])
			emitFP64Sqrt(p.FP64Program, dest, src)
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
		// Inline the function body. The body was compiled in the global
		// register space at definition time, so those register numbers are
		// stale (and likely never written) at a later call site. Remap every
		// register the body touches to fresh call-time registers, and bind the
		// argument registers directly to the passed values' registers so the
		// body reads the actual call arguments instead of definition-time
		// (uninitialized) slots.
		remap := make(map[string]string)
		for i, arg := range argList {
			if i >= len(fn.Args) {
				break
			}
			src := resolveHaskellAtom(p, arg)
			argReg := fn.ArgRegs[i]
			remap[argReg] = src
		}
		// Allocate fresh registers (and remap) for every other register the
		// body uses, so a nested call does not alias the enclosing body's
		// registers either.
		for _, inst := range fn.Body {
			regs := append([]string{inst.Dest}, inst.Src...)
			for _, r := range regs {
				if _, ok := remap[r]; !ok {
					remap[r] = p.allocReg()
				}
			}
		}
		// Emit the body with remapped registers; the top-level destination we
		// were called for (dest) receives the body's final result so the call
		// site can consume it.
		var resultReg string
		for _, inst := range fn.Body {
			ni := inst
			ni.Dest = remap[ni.Dest]
			// Deep-copy Src: the body's Src slices share backing arrays with
			// the stored function body, so an in-place remap would corrupt the
			// cached definition (and any earlier caller that captured it).
			ni.Src = append([]string(nil), inst.Src...)
			for j := range ni.Src {
				ni.Src[j] = remap[ni.Src[j]]
			}
			p.Regs = append(p.Regs, ni)
			resultReg = ni.Dest
		}
		if dest != resultReg {
			p.Regs = append(p.Regs, FP64IR{Op: FP64Mov, Dest: dest, Src: []string{resultReg}})
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
