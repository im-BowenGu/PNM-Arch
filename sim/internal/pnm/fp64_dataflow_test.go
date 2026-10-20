// Chained FP64 dataflow tests: structural lowering checks plus cycle-exact
// fabric runs for the R / Haskell / HLSL frontends.  These assert VALUE
// correctness (operand results actually thread between operations), which the
// static .pnm lowering (name-hash placeholder operands) cannot.
package pnm

import (
	"strings"
	"testing"
)

func TestFP64DataFlowLoweringR(t *testing.T) {
	prog, err := CompileR("result <- x * y\nresult <- result + x\nresult <- result + y\n")
	if err != nil {
		t.Fatal(err)
	}
	df, err := LowerRDataFlow(prog, Dims{Layers: 1, Bx: 2, By: 2})
	if err != nil {
		t.Fatal(err)
	}

	var ops []FP64Op
	for _, st := range df.Steps {
		if st.Dispatch {
			ops = append(ops, st.Op)
		}
	}
	if len(ops) != 3 || ops[0] != FP64Mul || ops[1] != FP64Add || ops[2] != FP64Add {
		t.Fatalf("expected [mul add add], got %v", ops)
	}
	if len(df.FreeNames) != 2 || df.FreeNames[0] != "x" || df.FreeNames[1] != "y" {
		t.Fatalf("expected free inputs [x y], got %v", df.FreeNames)
	}
	if df.Final != "r0" {
		t.Fatalf("expected final register r0, got %q", df.Final)
	}

	// Respect re-assignment: step 2's first operand must be the accumulator,
	// whose producer is step 1 (the mul), not the later add (step 2's dest).
	addSteps := 0
	for _, st := range df.Steps {
		if st.Op == FP64Add && st.Dest == "r0" {
			addSteps++
			if st.Src[0] != "r0" {
				t.Fatalf("add reads %s, expected accumulator r0", st.Src[0])
			}
		}
	}
	if addSteps != 2 {
		t.Fatalf("expected 2 adds on r0, got %d", addSteps)
	}
}

func TestFP64DataFlowConstAndMovFold(t *testing.T) {
	prog, err := CompileR("two <- 2.5\nthree <- two\nr <- three * x\n")
	if err != nil {
		t.Fatal(err)
	}
	df, err := LowerRDataFlow(prog, Dims{Layers: 1, Bx: 1, By: 2})
	if err != nil {
		t.Fatal(err)
	}
	constSeen, movSeen := false, false
	dispatchCount := 0
	var mulStep *DFStep
	for i := range df.Steps {
		st := &df.Steps[i]
		switch {
		case st.Op == FP64Const:
			constSeen = true
			if st.Imm != 2.5 {
				t.Fatalf("const step Imm = %v, want 2.5", st.Imm)
			}
			if st.Dispatch {
				t.Fatal("const step must not dispatch")
			}
		case st.Op == FP64Mov:
			movSeen = true
			if st.Dispatch {
				t.Fatal("mov step must not dispatch")
			}
		case st.Dispatch:
			dispatchCount++
			if st.Op == FP64Mul {
				mulStep = st
			}
		}
	}
	if !constSeen || !movSeen || dispatchCount != 1 {
		t.Fatalf("const=%v mov=%v dispatches=%d, want const=true mov=true dispatches=1",
			constSeen, movSeen, dispatchCount)
	}
	if mulStep == nil || len(mulStep.Src) != 2 {
		t.Fatalf("expected a mul step with 2 operands, got %+v", mulStep)
	}
	if len(df.FreeNames) != 1 || df.FreeNames[0] != "x" {
		t.Fatalf("expected single free input x, got %v", df.FreeNames)
	}
}

func TestFP64DataFlowLoweringHaskell(t *testing.T) {
	prog, err := CompileHaskell("mul x y = x * y\nadd a b = a + b\nf x y = add (add (mul x y) x) y\n")
	if err != nil {
		t.Fatal(err)
	}
	df, err := LowerHaskellDataFlow(prog, Dims{Layers: 1, Bx: 2, By: 2})
	if err != nil {
		t.Fatal(err)
	}
	// The entry function is f (last in source order); its body is fully
	// inlined (mul + add + add), bound to f's own parameters x, y.
	var ops []FP64Op
	for _, st := range df.Steps {
		if st.Dispatch {
			ops = append(ops, st.Op)
		}
	}
	if len(ops) != 3 || ops[0] != FP64Mul || ops[1] != FP64Add || ops[2] != FP64Add {
		t.Fatalf("expected [mul add add] (inlined f), got %v", ops)
	}
	if len(df.FreeNames) != 2 || df.FreeNames[0] != "x" || df.FreeNames[1] != "y" {
		t.Fatalf("expected free inputs [x y], got %v", df.FreeNames)
	}
	if df.Final == "" {
		t.Fatal("expected a final register")
	}
	// Value correctness for the inlined entry body is exercised end-to-end by
	// TestFP64DataFlowEndToEndHaskell (cycle-exact fabric run).
}

func TestFP64DataFlowEndToEndR(t *testing.T) {
	prog, err := CompileR("result <- x * y\nresult <- result + x\nresult <- result + y\n")
	if err != nil {
		t.Fatal(err)
	}
	df, err := LowerRDataFlow(prog, Dims{Layers: 1, Bx: 2, By: 2})
	if err != nil {
		t.Fatal(err)
	}
	res, err := RunDataFlow(df, map[string]float64{"x": 4, "y": 7}, 1)
	if err != nil {
		t.Fatal(err)
	}
	if res.FinalV != 39 {
		t.Fatalf("result = %v, want 39", res.FinalV)
	}
	if res.Dispatches != 3 {
		t.Fatalf("dispatches = %d, want 3", res.Dispatches)
	}
	for i, tr := range res.Traces {
		if !tr.Pass {
			t.Fatalf("trace %d not verified (PASS): %+v", i, tr)
		}
	}
}

func TestFP64DataFlowEndToEndHaskell(t *testing.T) {
	prog, err := CompileHaskell("mul x y = x * y\nadd a b = a + b\nf x y = add (add (mul x y) x) y\n")
	if err != nil {
		t.Fatal(err)
	}
	df, err := LowerHaskellDataFlow(prog, Dims{Layers: 1, Bx: 2, By: 2})
	if err != nil {
		t.Fatal(err)
	}
	res, err := RunDataFlow(df, map[string]float64{"x": 4, "y": 7}, 1)
	if err != nil {
		t.Fatal(err)
	}
	if res.FinalV != 39 {
		t.Fatalf("result = %v, want 39", res.FinalV)
	}
	if res.Dispatches != 3 {
		t.Fatalf("dispatches = %d, want 3", res.Dispatches)
	}
}

func TestFP64DataFlowEndToEndHLSL(t *testing.T) {
	prog, err := CompileHLSL("float result = x * y;\nresult = result + x;\nresult = result + y;\n")
	if err != nil {
		t.Fatal(err)
	}
	df, err := LowerHLSLDataFlow(prog, Dims{Layers: 1, Bx: 2, By: 2})
	if err != nil {
		t.Fatal(err)
	}
	res, err := RunDataFlow(df, map[string]float64{"x": 4, "y": 7}, 1)
	if err != nil {
		t.Fatal(err)
	}
	if res.FinalV != 39 {
		t.Fatalf("result = %v, want 39", res.FinalV)
	}
	if res.Dispatches != 3 {
		t.Fatalf("dispatches = %d, want 3", res.Dispatches)
	}
}

func TestFP64DataFlowConstFoldNoFabric(t *testing.T) {
	prog, err := CompileR("two <- 2.5\nr <- two * x\n")
	if err != nil {
		t.Fatal(err)
	}
	df, err := LowerRDataFlow(prog, Dims{Layers: 1, Bx: 1, By: 2})
	if err != nil {
		t.Fatal(err)
	}
	res, err := RunDataFlow(df, map[string]float64{"x": 4}, 1)
	if err != nil {
		t.Fatal(err)
	}
	if res.FinalV != 10 {
		t.Fatalf("result = %v, want 10", res.FinalV)
	}
	if res.Dispatches != 1 {
		t.Fatalf("dispatches = %d, want 1 (const/mov folded)", res.Dispatches)
	}
}

func TestFP64DataFlowUnboundInput(t *testing.T) {
	prog, err := CompileR("result <- x * y\n")
	if err != nil {
		t.Fatal(err)
	}
	df, err := LowerRDataFlow(prog, Dims{Layers: 1, Bx: 1, By: 1})
	if err != nil {
		t.Fatal(err)
	}
	_, err = RunDataFlow(df, map[string]float64{}, 1)
	if err == nil || !strings.Contains(err.Error(), "x") {
		t.Fatalf("expected an unbound-input error mentioning x, got %v", err)
	}
}

func TestFP64DataFlowPlacement(t *testing.T) {
	// mul and add are callee functions (placed on dedicated nodes); main is the
	// entry and performs one arithmetic op of its own (folded on the router
	// SBC) plus two callee calls.  main(4) = 4 + add(mul(4,7),7) = 4 + 35 = 39.
	src := "mul x y = x * y\n" +
		"add a b = a + b\n" +
		"main x = x + add (mul 4 7) 7\n"
	dims := Dims{Layers: 1, Bx: 2, By: 2}
	prog, err := CompileHaskell(src)
	if err != nil {
		t.Fatal(err)
	}
	df, err := LowerHaskellDataFlow(prog, dims)
	if err != nil {
		t.Fatal(err)
	}
	pl, err := PlaceHaskellFuncs(prog, dims)
	if err != nil {
		t.Fatal(err)
	}
	// Placement shape: entry main runs on the router SBC; mul/add get
	// distinct dedicated nodes (source order: mul, add).
	if pl.Entry != "main" || !pl.RouterSBC {
		t.Fatalf("placement entry=%q routerSBC=%v, want main/true", pl.Entry, pl.RouterSBC)
	}
	if len(pl.FuncNode) != 2 {
		t.Fatalf("expected 2 placed funcs, got %d", len(pl.FuncNode))
	}
	if pl.FuncNode["mul"] != (NodeID{L: 0, X: 0, Y: 0}) {
		t.Fatalf("mul placed at %v, want (0,0,0)", pl.FuncNode["mul"])
	}
	if pl.FuncNode["add"] != (NodeID{L: 0, X: 0, Y: 1}) {
		t.Fatalf("add placed at %v, want (0,0,1)", pl.FuncNode["add"])
	}
	// In the schedule, callee arithmetic carries the callee's origin; the
	// entry frame's own op is untagged.
	mulNodes, addNodes, entryOps := 0, 0, 0
	for _, st := range df.Steps {
		if !st.Dispatch {
			continue
		}
		switch st.Origin {
		case "mul":
			mulNodes++
		case "add":
			addNodes++
		case "":
			entryOps++
		}
	}
	if mulNodes < 1 || addNodes < 1 || entryOps < 1 {
		t.Fatalf("origins mul=%d add=%d entry=%d, want all >= 1", mulNodes, addNodes, entryOps)
	}

	// Cycle-exact placed run: callee math dispatches to its node, the entry's
	// own op folds on the router SBC, and the result threads end to end.
	res, err := RunDataFlowPlaced(df, map[string]float64{"x": 4}, 1, pl)
	if err != nil {
		t.Fatal(err)
	}
	if res.FinalV != 39 {
		t.Fatalf("result = %v, want 39", res.FinalV)
	}
	if res.Dispatches != mulNodes+addNodes {
		t.Fatalf("dispatches = %d, want %d (callee arithmetic only)", res.Dispatches, mulNodes+addNodes)
	}
	if res.HostSteps != entryOps {
		t.Fatalf("router-SBC folds = %d, want %d (entry-frame ops)", res.HostSteps, entryOps)
	}
	hit := map[NodeID]bool{}
	for _, tr := range res.Traces {
		if !tr.Pass {
			t.Fatalf("trace not verified: %+v", tr)
		}
		if tr.Fabric && !tr.Host {
			hit[tr.Node] = true
		}
	}
	if !hit[pl.FuncNode["mul"]] || !hit[pl.FuncNode["add"]] {
		t.Fatalf("dispatch did not reach placed nodes: %v", hit)
	}
}

func TestFP64DataFlowCmpChain(t *testing.T) {
	// cmp produces a 0.0/1.0 selector consumed by a later arithmetic step,
	// proving comparison results chain into the register file.
	prog, err := CompileR("c <- x > y\nr <- c * 10\n")
	if err != nil {
		t.Fatal(err)
	}
	df, err := LowerRDataFlow(prog, Dims{Layers: 1, Bx: 2, By: 2})
	if err != nil {
		t.Fatal(err)
	}
	res, err := RunDataFlow(df, map[string]float64{"x": 5, "y": 2}, 1)
	if err != nil {
		t.Fatal(err)
	}
	if res.FinalV != 10 {
		t.Fatalf("result = %v, want 10 (5 > 2 ⇒ cmp=1 ⇒ 1*10)", res.FinalV)
	}
	if res.Dispatches < 2 {
		t.Fatalf("dispatches = %d, want >= 2 (cmp + mul + const)", res.Dispatches)
	}
}
