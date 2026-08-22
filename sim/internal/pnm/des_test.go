package pnm

// des_test.go — validation of the discrete-event fabric model (des.go):
//
//  1. TestDESClosedForm: on the idle-fabric sweep every packet's latency
//     must equal the paper's closed form exactly
//     (wire_len-1 + l spine hops + x X-lane hops + the MAC pipe), every
//     stimulus byte must be injected, and byte conservation must hold.
//     Pure Go — no iverilog required.
//
//  2. TestDESCrossCheckRTL: the same model must reproduce the gate-level
//     fabric (iverilog + vvp) byte-for-byte and cycle-for-cycle on a mixed
//     program — routed requests, return-flag echoes (the egress merge
//     trees, paper §2.9), and pass-through traffic on classes 2 and 3
//     (the VC-isolation check, paper §4.3) — as asserted by CrossCheckDES.

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// runRTLSlice compiles and simulates one gate-level slice (a single vvp
// process owning the whole chassis, tail and root egress included) and
// returns the parsed delivery log.  des_* file names keep the test's
// artifacts apart from the scenario harness's gitignored outputs.
func runRTLSlice(t *testing.T, prog *Program, lids []int, bx, by int) *Delivery {
	t.Helper()
	simDir := SimDir()
	hdlDir, err := filepath.Abs(filepath.Join(simDir, "..", "HDL"))
	if err != nil {
		t.Fatalf("HDL path: %v", err)
	}
	nm := GroupNames{Top: "des_pnm_top.v", TB: "des_tb_pnm.v",
		Stim: "des_stimulus.hex", Log: "des_delivery.log", Out: "des_tb_pnm.out"}

	var stream []StreamByte
	for _, oe := range prog.Order {
		if oe.IsPT || containsInt(lids, oe.Key) {
			stream = append(stream, oe.WF...)
		}
	}
	nbytes := WriteStimulus(stream, filepath.Join(simDir, nm.Stim))
	gnodes := AllNodesIn(lids, bx, by)
	biases := map[NodeID]int{}
	for _, n := range gnodes {
		biases[n] = prog.Manifest[n].Bias
	}
	os.WriteFile(filepath.Join(simDir, nm.Top), []byte(GenTopology(lids, bx, by, biases, false)), 0o644)
	os.WriteFile(filepath.Join(simDir, nm.TB), []byte(GenTB(lids, bx, by, prog.BP, nbytes, nm.Stim, nm.Log)), 0o644)
	for _, f := range []string{nm.Top, nm.TB, nm.Stim, nm.Log, nm.Out} {
		t.Cleanup(func() { os.Remove(filepath.Join(simDir, f)) })
	}

	srcs := []string{nm.TB, nm.Top}
	for _, f := range FABRIC {
		srcs = append(srcs, filepath.Join(hdlDir, f))
	}
	args := []string{"-g2005", "-I" + hdlDir, "-s", "tb_pnm", "-o", nm.Out}
	args = append(args, srcs...)
	cmd := exec.Command("iverilog", args...)
	cmd.Dir = simDir
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("iverilog: %v\n%s", err, stderr.String())
	}
	cmd = exec.Command("vvp", nm.Out)
	cmd.Dir = simDir
	if err := cmd.Run(); err != nil {
		t.Fatalf("vvp: %v", err)
	}
	return ParseDelivery(filepath.Join(simDir, nm.Log))
}

func TestDESClosedForm(t *testing.T) {
	layers, bx, by := 3, 4, 4
	prog := ScenarioSweep(layers, bx, by, 1)
	lids := make([]int, layers)
	for i := range lids {
		lids[i] = i
	}
	des := RunDES(prog, lids, bx, by, true)

	if len(des.Inject) != len(prog.Stream) {
		t.Fatalf("DES injected %d/%d wire bytes", len(des.Inject), len(prog.Stream))
	}
	// sweep: no pass-through, no echoes, no misroutes
	if len(des.Tail) != 0 {
		t.Errorf("DES: %d spine-tail bytes, sweep has no pass-through", len(des.Tail))
	}
	if len(des.TailUp) != 0 {
		t.Errorf("DES: %d root-egress bytes, sweep requests no echoes", len(des.TailUp))
	}
	for k, v := range des.XRes {
		t.Errorf("DES: xres_%d carried %d misrouted bytes", k, len(v))
	}
	for k, v := range des.YRes {
		t.Errorf("DES: yres_(%d,%d) carried %d misrouted bytes", k.L, k.X, len(v))
	}

	inj := InjectTable(des.Inject)
	nodes := AllNodes(layers, bx, by)
	for i, n := range nodes {
		w := prog.Manifest[n].Packets[0]
		got := Packetize(des.Nodes[n])
		if len(got) != 1 {
			t.Errorf("%s: %d packets delivered, expected 1", n, len(got))
			continue
		}
		if want := StubOutput(w.DMA, prog.Manifest[n].Bias); !bytes.Equal(got[0].Bytes, want) {
			t.Errorf("%s: DMA stream mismatch", n)
		}
		lat := got[0].EopCyc - inj[i].SopCyc
		expect := w.WireLen - 1 + n.L + n.X + PE_PIPE_DELAY
		if lat != expect {
			t.Errorf("%s: latency %d != closed form %d", n, lat, expect)
		}
	}

	// byte conservation: injected == delivered + 1 stripped LAYER per packet
	delivered := len(des.Tail) + len(des.TailUp)
	for _, v := range des.Nodes {
		delivered += len(v)
	}
	for _, v := range des.XRes {
		delivered += len(v)
	}
	for _, v := range des.YRes {
		delivered += len(v)
	}
	if len(des.Inject) != delivered+len(nodes) {
		t.Errorf("byte conservation: %d injected, %d delivered + %d stripped",
			len(des.Inject), delivered, len(nodes))
	}
}

func TestDESCrossCheckRTL(t *testing.T) {
	layers, bx, by := 2, 3, 3
	nodes := AllNodes(layers, bx, by)
	prog := NewProgram("desmix", nodes, "bounded")
	for _, n := range nodes {
		prog.ProgramNode(n, "echo", nil, 3)
		prog.BP[n] = 1 // no backpressure: the DES duty timeline aligns with RTL cycles
	}
	for i, n := range nodes {
		payload := make([]byte, 8)
		for k := range payload {
			payload[k] = byte(n.L*16 + n.X*4 + n.Y + k)
		}
		if i%4 == 0 {
			prog.InjectEcho(n, payload) // return flag: egress merges + root egress
		} else {
			// mask rsvd[0]: CTRL|1 == CTRL_ECHO_SPINE would make the RTL
			// (pe_tile_stub tx_ret_q) echo on these "plain" requests too
			prog.InjectRouted(n, CTRL_COMPUTE_SPINE|((i&0x0F)&^1), payload, false)
		}
	}
	prog.InjectPassthrough([]byte{0xDE, 0xAD})                       // class 2
	prog.InjectPassthroughVC([]byte{0xBA, 0xBE}, VC_ONBOARD_DELIVER) // class 3

	lids := []int{0, 1}
	rtl := runRTLSlice(t, prog, lids, bx, by)
	des := RunDES(prog, lids, bx, by, true)
	off := 9
	if len(rtl.Inject) > 0 && len(des.Inject) > 0 {
		off = rtl.Inject[0].Cyc - des.Inject[0].Cyc
	}
	for i := 0; i < len(des.Inject) && i < len(rtl.Inject); i++ {
		d, r := des.Inject[i], rtl.Inject[i]
		r.Cyc -= off
		if d != r {
			t.Logf("inject[%d] des=(%d,%02x,s%d,e%d,v%d) rtl=(%d,%02x,s%d,e%d,v%d)", i, d.Cyc, d.D, d.S, d.E, d.Vc, r.Cyc, r.D, r.S, r.E, r.Vc)
			break
		}
	}
	if errs := CrossCheckDES(rtl, des, nil); len(errs) > 0 {
		for _, e := range errs {
			t.Error(e)
		}
	}
}
