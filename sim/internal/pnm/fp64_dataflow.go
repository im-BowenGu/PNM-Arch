// Chained FP64 dataflow execution for the R / Haskell / HLSL frontends.
//
// The static .pnm lowering (lowerFP64ToPNM) serializes operands as
// deterministic name-hash placeholders (packFP64Args), so a .pnm program
// dispatched through pnmc exercises the fabric structure but never threads
// real values between operations.  This file is the value-accurate
// counterpart: it resolves each FP64 IR instruction's operand registers
// against the actual producer results, packs real big-endian FP64 operands
// into each node's dispatch token, and verifies the whole schedule with one
// cycle-exact fabric run (RunOne).  The f64_* kernels execute in the host
// twin (virtual_units.go kernelFunc / run.go Golden) exactly as they do for
// any dispatched token; the fabric verifies byte-exact transport of every
// chained payload.
package pnm

import (
	"fmt"
	"math"
	"sort"
	"strings"
)

// DFStep is one scheduled IR instruction.  Value instructions (const/mov)
// fold into the register file without a fabric dispatch; arithmetic and
// comparison instructions dispatch a token to their assigned node.
type DFStep struct {
	Index    int
	Op       FP64Op
	Kernel   string
	Dest     string
	Src      []string
	Cond     string
	Imm      float64
	Origin   string // defining function (Haskell); "" = main/host frame
	Node     NodeID
	Dispatch bool // needs a fabric token
}

// DataFlowProgram is a register dataflow schedule over a chassis.
type DataFlowProgram struct {
	Dims      Dims
	Steps     []DFStep
	FreeRegs  []string // registers with no writer (program inputs)
	FreeNames []string // source variable names for those registers
	names     map[string]string
	Final     string // register holding the program answer
}

// DFStepTrace records one executed step.
type DFStepTrace struct {
	Node   NodeID
	Kernel string
	Op     FP64Op
	Dest   string
	Args   []float64
	Result float64
	Pass   bool
	Fabric bool
	Host   bool // executed on the router SBC (entry/main frame), not a fabric node
}

// DataFlowResult is the outcome of a chained execution.
type DataFlowResult struct {
	Final      string
	FinalV     float64
	Traces     []DFStepTrace
	Dispatches int
	Nodes      int
	HostSteps  int // instructions folded into the router-SBC frame
}

// LowerFP64DataFlow builds a chained dataflow schedule from an FP64 IR
// stream, using the same round-robin node assignment as the static .pnm
// lowering so both listings agree on placement.  vars maps source variable
// names to register numbers (FP64Program.Vars) for free-input naming.
func LowerFP64DataFlow(insts []FP64IR, dims Dims, vars map[string]int) (*DataFlowProgram, error) {
	total := dims.Layers * dims.Bx * dims.By
	if total == 0 {
		return nil, fmt.Errorf("dataflow: empty chassis %dx%dx%d", dims.Layers, dims.Bx, dims.By)
	}

	// Reverse variable map for free-input naming (first name wins on alias).
	names := make(map[string]string)
	for name, reg := range vars {
		if _, ok := names[fmt.Sprintf("r%d", reg)]; !ok {
			names[fmt.Sprintf("r%d", reg)] = name
		}
	}
	regName := func(reg string) string {
		if n, ok := names[reg]; ok {
			return n
		}
		return reg
	}

	// Single forward pass: curDefs holds each register's latest writer index
	// strictly before the current instruction, so re-assignment (R "result <-
	// result + x") resolves reads against the just-computed producer.
	curDefs := make(map[string]int)
	written := make(map[string]bool)
	df := &DataFlowProgram{Dims: dims, names: names}

	nodeIdx := 0
	for i, inst := range insts {
		for _, src := range inst.Src {
			if _, ok := curDefs[src]; !ok {
				if !written[src] {
					written[src] = true
					df.FreeRegs = append(df.FreeRegs, src)
					df.FreeNames = append(df.FreeNames, regName(src))
				}
			}
		}
		if inst.Dest != "" {
			curDefs[inst.Dest] = i
		}
	}

	sort.Strings(df.FreeNames)
	sort.Strings(df.FreeRegs)

	kernel := irOpToKernel
	nodeIdx = 0
	for i, inst := range insts {
		l := nodeIdx / (dims.Bx * dims.By)
		xy := nodeIdx % (dims.Bx * dims.By)
		x := xy / dims.By
		y := xy % dims.By
		node := NodeID{L: l % dims.Layers, X: x % dims.Bx, Y: y % dims.By}
		nodeIdx++
		step := DFStep{
			Index:  i,
			Op:     inst.Op,
			Dest:   inst.Dest,
			Src:    append([]string(nil), inst.Src...),
			Cond:   inst.Cond,
			Imm:    inst.Imm,
			Origin: inst.Origin,
			Node:   node,
		}
		if inst.Op == FP64Const {
			step.Imm = inst.Imm
		}
		step.Kernel = kernel(inst.Op)
		step.Dispatch = step.Kernel != ""
		df.Steps = append(df.Steps, step)
		if inst.Dest != "" {
			df.Final = inst.Dest
		}
	}
	return df, nil
}

// LowerRDataFlow lowers an R program into a chained schedule.
func LowerRDataFlow(prog *FP64Program, dims Dims) (*DataFlowProgram, error) {
	return LowerFP64DataFlow(prog.Regs, dims, prog.Vars)
}

// haskellEntry picks the program's entry function: "main" when defined,
// otherwise the last function in source order (a Haskell program evaluates
// its main expression / trailing function).
func haskellEntry(prog *HaskellProgram) string {
	if _, ok := prog.Funcs["main"]; ok {
		return "main"
	}
	if len(prog.Order) > 0 {
		return prog.Order[len(prog.Order)-1]
	}
	var names []string
	for name := range prog.Funcs {
		names = append(names, name)
	}
	sort.Strings(names)
	if len(names) > 0 {
		return names[len(names)-1]
	}
	return ""
}

// LowerHaskellDataFlow lowers the *executable* Haskell program (its entry
// function, already fully inlined by the frontend, plus any main body) into a
// chained schedule.  The entry function's own scope maps its parameter
// registers back to source names, so the free inputs are the function
// parameters (e.g. x, y for hello.hs).  The static .pnm lowering instead
// emits every function body as standalone structure; this is the
// value-accurate counterpart.
func LowerHaskellDataFlow(prog *HaskellProgram, dims Dims) (*DataFlowProgram, error) {
	entry := haskellEntry(prog)
	if entry == "" && len(prog.Regs) == 0 {
		return nil, fmt.Errorf("haskell dataflow: no entry function and no main body")
	}
	insts := append([]FP64IR(nil), prog.Regs...)
	vars := make(map[string]int, len(prog.Vars))
	for k, v := range prog.Vars {
		vars[k] = v
	}
	if entry != "" {
		fn := prog.Funcs[entry]
		insts = append(fn.Body, insts...)
		for k, v := range fn.Vars {
			if _, ok := vars[k]; !ok {
				vars[k] = v
			}
		}
	}
	return LowerFP64DataFlow(insts, dims, vars)
}

// LowerHLSLDataFlow lowers an HLSL program (FP32 ALU IR widened to FP64
// dispatch) into a chained schedule.
func LowerHLSLDataFlow(prog *HLSLProgram, dims Dims) (*DataFlowProgram, error) {
	return LowerFP64DataFlow(hlslToFP64IRs(prog), dims, prog.Vars)
}

// Placement maps each compiled function to a dedicated fabric node.  The
// entry function (and any main-frame instruction) is handled on the router
// SBC: the SoC router chip orchestrates, folds the entry's control math on the
// host side, and dispatches each callee function's arithmetic to its node.
type Placement struct {
	Entry     string            // function name executed on the router SBC
	FuncNode  map[string]NodeID // non-entry function -> dedicated node
	RouterSBC bool              // entry/main frame folds on the host
}

// PlaceHaskellFuncs assigns every non-entry function a distinct node
// (round-robin in source order, mirroring the .pnm round-robin formula) and
// marks the entry for execution on the router SBC.
func PlaceHaskellFuncs(prog *HaskellProgram, dims Dims) (*Placement, error) {
	entry := haskellEntry(prog)
	if entry == "" {
		return nil, fmt.Errorf("placement: no entry function")
	}
	total := dims.Layers * dims.Bx * dims.By
	if total == 0 {
		return nil, fmt.Errorf("placement: empty chassis %dx%dx%d", dims.Layers, dims.Bx, dims.By)
	}
	pl := &Placement{Entry: entry, FuncNode: map[string]NodeID{}, RouterSBC: true}
	idx := 0
	for _, name := range prog.Order {
		if name == entry {
			continue
		}
		l := idx / (dims.Bx * dims.By)
		xy := idx % (dims.Bx * dims.By)
		x := xy / dims.By
		y := xy % dims.By
		pl.FuncNode[name] = NodeID{L: l % dims.Layers, X: x % dims.Bx, Y: y % dims.By}
		idx++
	}
	return pl, nil
}

// RunDataFlow executes the schedule: resolves operand values through the
// register file, packs real FP64 payloads, and verifies every dispatch with a
// single cycle-exact fabric run.  inputs binds free input registers, keyed by
// either the source variable name or the register name.
func RunDataFlow(df *DataFlowProgram, inputs map[string]float64, groups int) (*DataFlowResult, error) {
	return runDataFlow(df, inputs, groups, nil)
}

// RunDataFlowPlaced is RunDataFlow under a function placement: callee-function
// instructions dispatch to their dedicated nodes, and the entry/main frame
// folds into the router-SBC host side.
func RunDataFlowPlaced(df *DataFlowProgram, inputs map[string]float64, groups int, pl *Placement) (*DataFlowResult, error) {
	return runDataFlow(df, inputs, groups, pl)
}

func runDataFlow(df *DataFlowProgram, inputs map[string]float64, groups int, pl *Placement) (*DataFlowResult, error) {
	if df == nil || len(df.Steps) == 0 {
		return &DataFlowResult{Final: df.Final}, nil
	}

	values := make(map[string]float64, len(df.FreeRegs)+len(df.Steps))
	for _, reg := range df.FreeRegs {
		if v, ok := inputs[reg]; ok {
			values[reg] = v
			continue
		}
		if name, ok := df.names[reg]; ok {
			if v, ok := inputs[name]; ok {
				values[reg] = v
				continue
			}
		}
		return nil, fmt.Errorf("dataflow: unbound input register %s (provide -inputs %s=...)",
			reg, regNameOr(df, reg))
	}

	prog := NewProgram("f64chain", nil, "bounded")
	nodes := map[NodeID]bool{}
	type disp struct {
		st      *DFStep
		payload []byte
		node    NodeID
	}
	var dispatched []disp
	res := &DataFlowResult{Final: df.Final}

	for i := range df.Steps {
		st := &df.Steps[i]
		trace := DFStepTrace{Node: st.Node, Kernel: st.Kernel, Op: st.Op, Dest: st.Dest}
		switch {
		case st.Op == FP64Const:
			values[st.Dest] = st.Imm
			trace.Result = st.Imm
			trace.Pass = true
			res.Traces = append(res.Traces, trace)
			continue
		case st.Op == FP64Mov:
			if len(st.Src) < 1 {
				return nil, fmt.Errorf("dataflow: malformed mov step %d (%s)", st.Index, st.Dest)
			}
			v, ok := values[st.Src[0]]
			if !ok {
				return nil, fmt.Errorf("dataflow: step %d reads %s before it is written", st.Index, st.Src[0])
			}
			values[st.Dest] = v
			trace.Result = v
			trace.Pass = true
			res.Traces = append(res.Traces, trace)
			continue
		}

		if !st.Dispatch {
			return nil, fmt.Errorf("dataflow: no kernel for op %s at step %d", st.Op, st.Index)
		}

		args := make([]float64, 0, len(st.Src))
		for _, src := range st.Src {
			v, ok := values[src]
			if !ok {
				return nil, fmt.Errorf("dataflow: step %d reads %s before it is written", st.Index, src)
			}
			args = append(args, v)
		}
		out := evalFP64Op(st.Op, args, st.Cond)
		values[st.Dest] = out
		trace.Args = append([]float64(nil), args...)
		trace.Result = out

		node := st.Node
		if pl != nil {
			if fn, ok := pl.FuncNode[st.Origin]; ok {
				node = fn
			}
			// Entry/main-frame arithmetic folds on the router SBC: the SoC
			// orchestrates and only offloads callee-function math to nodes.
			if pl.RouterSBC && (st.Origin == "" || st.Origin == pl.Entry) {
				trace.Host = true
				trace.Pass = true
				res.HostSteps++
				res.Traces = append(res.Traces, trace)
				continue
			}
		}

		nodes[node] = true
		trace.Node = node
		trace.Fabric = true
		res.Traces = append(res.Traces, trace)
		dispatched = append(dispatched, disp{st: st, payload: fp64Payload(st.Op, args, st.Cond), node: node})
	}

	if len(dispatched) == 0 {
		res.FinalV = values[df.Final]
		for i := range res.Traces {
			res.Traces[i].Pass = true
		}
		return res, nil
	}

	nodeList := allChassisNodes(df.Dims)
	prog = NewProgram("f64chain", nodeList, "bounded")
	seen := map[NodeID]bool{}
	for _, d := range dispatched {
		n := d.node
		if !seen[n] {
			seen[n] = true
			prog.ProgramNode(n, d.st.Kernel, nil, 0)
		}
		prog.InjectRouted(n, CTRL_COMPUTE_SPINE|((d.st.Index&0x0F)&^1), d.payload, false)
	}

	_, ok := RunOne(prog, nodeList, df.Dims, groups, 1)
	if !ok {
		return nil, fmt.Errorf("dataflow: chassis verification FAILED (byte-exact transport check)")
	}

	res.Dispatches = len(dispatched)
	res.Nodes = len(nodes)
	for i := range res.Traces {
		res.Traces[i].Pass = true
	}
	res.FinalV = values[df.Final]
	return res, nil
}

// allChassisNodes enumerates every node ID on the chassis, so a dataflow run
// registers the full manifest (RunOne reads Bias for all nodes in a layer
// group; an unregistered node would nil-deref at run.go:1699).
func allChassisNodes(dims Dims) []NodeID {
	var ns []NodeID
	for l := 0; l < dims.Layers; l++ {
		for x := 0; x < dims.Bx; x++ {
			for y := 0; y < dims.By; y++ {
				ns = append(ns, NodeID{L: l, X: x, Y: y})
			}
		}
	}
	return ns
}

func regNameOr(df *DataFlowProgram, reg string) string {
	if n, ok := df.names[reg]; ok {
		return n
	}
	return reg
}

// evalFP64Op computes the numeric result of an FP64 op over resolved operand
// values.  It mirrors kernelFunc/Golden (virtual_units.go / run.go) so the
// chained value is byte-identical to the dispatched token's golden result.
func evalFP64Op(op FP64Op, args []float64, cond string) float64 {
	a := float64(0)
	if len(args) > 0 {
		a = args[0]
	}
	b := float64(0)
	if len(args) > 1 {
		b = args[1]
	}
	switch op {
	case FP64Add:
		return a + b
	case FP64Sub:
		return a - b
	case FP64Mul:
		return a * b
	case FP64FMA:
		if len(args) > 2 {
			return args[0]*args[1] + args[2]
		}
		return a * b
	case FP64Div:
		return a / b
	case FP64Min:
		return math.Min(a, b)
	case FP64Max:
		return math.Max(a, b)
	case FP64Neg:
		return -a
	case FP64Cmp:
		opStr := strings.TrimSpace(cond)
		switch opStr {
		case "==":
			return boolTo1(a == b)
		case "!=", "/=":
			return boolTo1(a != b)
		case "<":
			return boolTo1(a < b)
		case ">":
			return boolTo1(a > b)
		case "<=":
			return boolTo1(a <= b)
		case ">=":
			return boolTo1(a >= b)
		}
		return 0
	}
	return 0
}

func boolTo1(v bool) float64 {
	if v {
		return 1.0
	}
	return 0.0
}

// fp64Payload packs resolved operand values into the dispatch token payload,
// mirroring serializeOperands (big-endian FP64 chunks; cmp carries a 2-byte
// ASCII condition tail).
func fp64Payload(op FP64Op, args []float64, cond string) []byte {
	var payload []byte
	for _, v := range args {
		payload = append(payload, fp64ToBytes(v)...)
	}
	if op == FP64Cmp {
		c := cond
		if len(c) == 1 {
			c = c + " "
		}
		if len(c) > 2 {
			c = c[:2]
		}
		payload = append(payload, []byte(c)...)
	}
	return payload
}
