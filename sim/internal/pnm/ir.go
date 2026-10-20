// Shared FP64 IR core for the R and Haskell frontends.
//
// The R, Haskell and HLSL frontends were three near-parallel compilers.  This
// file holds the pieces they genuinely share: the FP64 opcode set, the IR
// instruction and program (with its register allocator), the textual emitter,
// the paren-aware top-level argument splitter, and the FP64 aggregation
// (sum/prod/min/max/mean) lowering.  HLSL keeps its own FP32 opcode set but
// reuses the argument splitter; R and Haskell share the whole FP64 core.
package pnm

import (
	"fmt"
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
	Op     FP64Op
	Dest   string   // destination register
	Src    []string // source registers or immediates
	Imm    float64  // literal constant (FP64)
	Cond   string   // comparison condition for CMP: "==", "!=", "<", ">", "<=", ">="
	Origin string   // defining function name (Haskell); empty = main/host frame
}

// FP64Program is a sequence of IR instructions.
type FP64Program struct {
	FuncName string
	Regs     []FP64IR
	Vars     map[string]int
	nextReg  int
}

func newFP64Program(name string) *FP64Program {
	return &FP64Program{
		FuncName: name,
		Vars:     make(map[string]int),
	}
}

func (p *FP64Program) allocReg() string {
	reg := fmt.Sprintf("r%d", p.nextReg)
	p.nextReg++
	return reg
}

func (p *FP64Program) getOrCreateReg(name string) string {
	if reg, ok := p.Vars[name]; ok && reg < p.nextReg {
		return fmt.Sprintf("r%d", reg)
	}
	reg := p.allocReg()
	p.Vars[name] = p.nextReg - 1
	return reg
}

// emitFP64Inst writes one instruction, indented by indent ("" for the flat R
// listing, "  " inside Haskell function bodies).  Neg/Sub fall through to the
// default arm, which concatenates Dest and every Src — identical output to the
// per-op cases the two frontends used to carry separately.
func emitFP64Inst(b *strings.Builder, inst FP64IR, indent string) {
	switch inst.Op {
	case FP64Const:
		fmt.Fprintf(b, "%s%-10s %s, %.17g\n", indent, inst.Op, inst.Dest, inst.Imm)
	case FP64Cmp:
		fmt.Fprintf(b, "%s%-10s %s, %s, %s, %s\n", indent, inst.Op, inst.Dest,
			inst.Src[0], inst.Src[1], inst.Cond)
	case FP64Store:
		fmt.Fprintf(b, "%s%-10s [%s], %s\n", indent, inst.Op, inst.Dest, inst.Src[0])
	case FP64Load:
		fmt.Fprintf(b, "%s%-10s %s, [%s]\n", indent, inst.Op, inst.Dest, inst.Src[0])
	default:
		fmt.Fprintf(b, "%s%-10s %s\n", indent, inst.Op, strings.Join(
			append([]string{inst.Dest}, inst.Src...), ", "))
	}
}

// Emit returns the flat FP64 IR listing (R frontend / host frame).
func (p *FP64Program) Emit() string {
	var b strings.Builder
	fmt.Fprintf(&b, "# FP64 IR: %s\n", p.FuncName)
	fmt.Fprintf(&b, "# %d registers, %d instructions\n\n", p.nextReg, len(p.Regs))
	for _, inst := range p.Regs {
		emitFP64Inst(&b, inst, "")
	}
	return b.String()
}

// splitTopLevelArgs splits a comma-separated argument list, ignoring commas
// nested inside parentheses.  Shared by the R and HLSL frontends.
func splitTopLevelArgs(s string) []string {
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

type aggKind int

const (
	aggSum aggKind = iota
	aggProd
	aggMin
	aggMax
	aggMean
)

// emitFP64Agg emits the reduction for sum/prod/min/max/mean over args.  Each
// operand is materialized through resolve (which maps a source token to a
// register/constant).  Shared by the R and Haskell frontends.
func emitFP64Agg(p *FP64Program, dest string, kind aggKind, args []string,
	resolve func(string) (string, error)) error {
	if len(args) == 0 {
		return fmt.Errorf("empty argument list")
	}
	switch kind {
	case aggSum, aggProd:
		acc := p.allocReg()
		initVal := 0.0
		if kind == aggProd {
			initVal = 1.0
		}
		p.Regs = append(p.Regs, FP64IR{Op: FP64Const, Dest: acc, Imm: initVal})
		binOp := FP64Add
		if kind == aggProd {
			binOp = FP64Mul
		}
		for _, a := range args {
			v, err := resolve(a)
			if err != nil {
				return err
			}
			p.Regs = append(p.Regs, FP64IR{Op: binOp, Dest: acc, Src: []string{acc, v}})
		}
		p.Regs = append(p.Regs, FP64IR{Op: FP64Mov, Dest: dest, Src: []string{acc}})
	case aggMin, aggMax:
		aggOp := FP64Min
		if kind == aggMax {
			aggOp = FP64Max
		}
		src, err := resolve(args[0])
		if err != nil {
			return err
		}
		acc := p.allocReg()
		p.Regs = append(p.Regs, FP64IR{Op: FP64Mov, Dest: acc, Src: []string{src}})
		for i := 1; i < len(args); i++ {
			v, err := resolve(args[i])
			if err != nil {
				return err
			}
			p.Regs = append(p.Regs, FP64IR{Op: aggOp, Dest: acc, Src: []string{acc, v}})
		}
		p.Regs = append(p.Regs, FP64IR{Op: FP64Mov, Dest: dest, Src: []string{acc}})
	case aggMean:
		sumReg := p.allocReg()
		p.Regs = append(p.Regs, FP64IR{Op: FP64Const, Dest: sumReg, Imm: 0.0})
		for _, a := range args {
			v, err := resolve(a)
			if err != nil {
				return err
			}
			p.Regs = append(p.Regs, FP64IR{Op: FP64Add, Dest: sumReg, Src: []string{sumReg, v}})
		}
		nReg := p.allocReg()
		p.Regs = append(p.Regs, FP64IR{Op: FP64Const, Dest: nReg, Imm: float64(len(args))})
		p.Regs = append(p.Regs, FP64IR{Op: FP64Div, Dest: dest, Src: []string{sumReg, nReg}})
	}
	return nil
}
