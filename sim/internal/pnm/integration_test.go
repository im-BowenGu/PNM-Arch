package pnm

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// TestIntegration_CompileAndRunModelCompiler verifies the full pipeline:
// HuggingFace config → AOT compilation → PNM program + chassis schema.
func TestIntegration_CompileAndRunModelCompiler(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}

	simDir := SimDir()
	examples := []string{"gemma4_test_synthetic", "mini_glm_moe"}

	for _, ex := range examples {
		t.Run(ex, func(t *testing.T) {
			modelDir := filepath.Join(simDir, "examples", ex)
			if _, err := os.Stat(modelDir); os.IsNotExist(err) {
				t.Skipf("example %s not found", ex)
				return
			}

			goBin := goPath()
			if goBin == "" {
				t.Skip("go not found in PATH")
				return
			}

			// Run the model compiler: emits schema, program, and (when the
			// model carries one) the BPE vocab listing.
			cmd := exec.Command(goBin, "run", "./cmd/pnmc", "compile-model",
				filepath.Join("examples", ex),
				"-l", "4", "-x", "4", "-y", "4")
			cmd.Dir = simDir
			out, err := cmd.CombinedOutput()
			if err != nil {
				t.Errorf("model compiler failed: %v\nOutput: %s", err, out)
			}

			// Verify outputs the compiler itself generates
			for _, name := range []string{
				ex + "_schema.txt", ex + ".pnm",
			} {
				path := filepath.Join(simDir, name)
				if _, err := os.Stat(path); os.IsNotExist(err) {
					t.Errorf("expected output file %s not generated", name)
				}
			}

			// Run the driver: emits the dispatch plan, routing table, and
			// MoE map that the load path verifies.
			cmd = exec.Command(goBin, "run", "./cmd/pnmc", "run-driver",
				filepath.Join("examples", ex),
				"-l", "4", "-x", "4", "-y", "4")
			cmd.Dir = simDir
			out, err = cmd.CombinedOutput()
			if err != nil {
				t.Errorf("driver failed: %v\nOutput: %s", err, out)
			}

			// Verify driver output files were generated
			for _, name := range []string{"dispatch_plan.txt", "routing_table.json", "moe_map.json"} {
				path := filepath.Join(simDir, name)
				if _, err := os.Stat(path); os.IsNotExist(err) {
					t.Errorf("expected output file %s not generated", name)
				}
			}
		})
	}
}

// TestIntegration_DriverBootAndDispatch verifies the host driver can
// complete weight upload and dispatch planning.
func TestIntegration_DriverBootAndDispatch(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}

	simDir := SimDir()
	goBin := goPath()
	if goBin == "" {
		t.Skip("go not found in PATH")
		return
	}

	cmd := exec.Command(goBin, "run", "./cmd/pnmc", "run-driver",
		"examples/gemma4_test_synthetic",
		"-l", "4", "-x", "4", "-y", "4")
	cmd.Dir = simDir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Errorf("driver failed: %v\nOutput: %s", err, out)
	}
	_ = out
}

// TestIntegration_FirmwareCompile verifies the C firmware compiles
// for both SoC and MCU targets.
func TestIntegration_FirmwareCompile(t *testing.T) {
	fwDir := SiblingRepo("fw")
	if _, err := os.Stat(fwDir); os.IsNotExist(err) {
		t.Skip("fw/ directory not found")
	}

	gcc := gccPath()
	if gcc == "" {
		t.Skip("gcc not found in PATH")
	}

	// SoC target
	t.Run("soc", func(t *testing.T) {
		cmd := exec.Command(gcc, "-Wall", "-Wextra", "-std=c11", "-c", "pnm_fw.c", "-o", "/dev/null")
		cmd.Dir = fwDir
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Errorf("SoC firmware compile failed: %v\nOutput: %s", err, out)
		}
	})

	// MCU target
	t.Run("mcu", func(t *testing.T) {
		cmd := exec.Command(gcc, "-Wall", "-Wextra", "-std=c11", "-DPNM_MCU", "-c", "pnm_fw.c", "-o", "/dev/null")
		cmd.Dir = fwDir
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Errorf("MCU firmware compile failed: %v\nOutput: %s", err, out)
		}
	})
}

// TestIntegration_CKVLoadNonDestructive verifies that the C firmware's
// kv_load is a non-destructive positional read (regression for the
// destructive-read bug where every load advanced read_ptr and decremented
// occupancy, evicting entries on read). Compiles and runs fw/test_kv_load.c.
func TestIntegration_CKVLoadNonDestructive(t *testing.T) {
	fwDir := SiblingRepo("fw")
	if _, err := os.Stat(filepath.Join(fwDir, "test_kv_load.c")); os.IsNotExist(err) {
		t.Skip("fw/test_kv_load.c not found")
	}

	gcc := gccPath()
	if gcc == "" {
		t.Skip("gcc not found in PATH")
	}

	bin := filepath.Join(os.TempDir(), "test_kv_load_c")
	if runtime.GOOS == "windows" {
		bin += ".exe"
	}

	cmd := exec.Command(gcc, "-Wall", "-Wextra", "-std=c11",
		"-o", bin, "test_kv_load.c", "pnm_fw.c")
	cmd.Dir = fwDir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("test_kv_load.c compile failed: %v\nOutput: %s", err, out)
	}

	cmd = exec.Command(bin)
	cmd.Dir = fwDir
	out, err = cmd.CombinedOutput()
	if err != nil {
		t.Errorf("kv_load regression test failed: %v\nOutput: %s", err, out)
	}
	if !strings.Contains(string(out), "RESULT: ALL PASS") {
		t.Errorf("kv_load regression test did not pass:\n%s", out)
	}
}

// TestIntegration_CSourceFirmware exercises the R, Haskell and HLSL
// dispatch ports.  They were three copies of the same planner that had
// drifted from the canonical firmware, and nothing ran them -- they were
// only compile-checked.  They are now one shared implementation
// (fw/src_fw.c) with three thin wrappers, and this test runs all three:
// the plan's shape, the verifier, the FLOP estimate, and the fact that the
// three agree on which experts a token selects.
func TestIntegration_CSourceFirmware(t *testing.T) {
	fwDir := SiblingRepo("fw")
	if _, err := os.Stat(filepath.Join(fwDir, "test_src_fw.c")); os.IsNotExist(err) {
		t.Skip("fw/test_src_fw.c not found")
	}
	gcc := gccPath()
	if gcc == "" {
		t.Skip("gcc not found in PATH")
	}

	bin := filepath.Join(os.TempDir(), "test_src_fw_c")
	if runtime.GOOS == "windows" {
		bin += ".exe"
	}

	cmd := exec.Command(gcc, "-Wall", "-Wextra", "-std=c11",
		"-o", bin, "test_src_fw.c", "src_fw.c", "pnm_fw.c",
		"pnm_fw_r.c", "pnm_fw_haskell.c", "pnm_fw_hlsl.c")
	cmd.Dir = fwDir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("test_src_fw.c compile failed: %v\nOutput: %s", err, out)
	}

	cmd = exec.Command(bin)
	cmd.Dir = fwDir
	out, err = cmd.CombinedOutput()
	if err != nil {
		t.Errorf("source firmware test failed: %v\nOutput: %s", err, out)
	}
	if !strings.Contains(string(out), "SOURCE FIRMWARE TEST PASSED") {
		t.Errorf("source firmware test did not pass:\n%s", out)
	}
}

// TestIntegration_CMgmtGating exercises the embedded management node's
// firmware: the mode-A manager of the gating ASIC.  It programs the router
// weights, gates a token, reads the decision back through the rank window,
// and emits the dispatch flits -- which are checked byte for byte, CRC-16
// included, against an independent reference.
func TestIntegration_CMgmtGating(t *testing.T) {
	fwDir := SiblingRepo("fw")
	if _, err := os.Stat(filepath.Join(fwDir, "test_mgmt_gating.c")); os.IsNotExist(err) {
		t.Skip("fw/test_mgmt_gating.c not found")
	}
	gcc := gccPath()
	if gcc == "" {
		t.Skip("gcc not found in PATH")
	}

	bin := filepath.Join(os.TempDir(), "test_mgmt_gating_c")
	if runtime.GOOS == "windows" {
		bin += ".exe"
	}

	cmd := exec.Command(gcc, "-Wall", "-Wextra", "-std=c11",
		"-o", bin, "test_mgmt_gating.c", "pnm_mgmt.c", "pnm_fw.c")
	cmd.Dir = fwDir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("test_mgmt_gating.c compile failed: %v\nOutput: %s", err, out)
	}

	// The firmware records its bus transactions, so the RTL can replay them.
	trace := "/tmp/pnm_mgmt_trace.txt"

	cmd = exec.Command(bin)
	cmd.Dir = fwDir
	cmd.Env = append(os.Environ(), "PNM_MGMT_TRACE="+trace)
	out, err = cmd.CombinedOutput()
	if err != nil {
		t.Errorf("management node gating test failed: %v\nOutput: %s", err, out)
	}
	if !strings.Contains(string(out), "MGMT GATING TEST PASSED") {
		t.Errorf("management node gating test did not pass:\n%s", out)
	}

	// Now replay the firmware's exact sequence against the *real* gating
	// ASIC, so the firmware and the silicon are checked against each other
	// rather than each against its own model.
	iverilog := iverilogPath()
	if iverilog == "" {
		t.Skip("iverilog not found in PATH")
	}
	vvpBin := vvpPath()
	if vvpBin == "" {
		t.Skip("vvp not found in PATH")
	}
	hdlDir := SiblingRepo("HDL")

	simBin := filepath.Join(os.TempDir(), "tb_mgmt_trace")
	args := []string{"-g2005", "-o", simBin,
		filepath.Join(hdlDir, "core", "tb_mgmt_trace.v"),
		filepath.Join(hdlDir, "core", "gating_asic.v"),
		filepath.Join(hdlDir, "core", "moe_gating.v"),
		filepath.Join(hdlDir, "core", "arith_unit.v"),
		filepath.Join(hdlDir, "core", "bf16_fma.v"),
		filepath.Join(hdlDir, "core", "fma_core.v"),
	}
	cmd = exec.Command(iverilog, args...)
	out, err = cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("tb_mgmt_trace.v compile failed: %v\nOutput: %s", err, out)
	}

	cmd = exec.Command(vvpBin, simBin)
	out, err = cmd.CombinedOutput()
	if err != nil {
		t.Errorf("the firmware's trace did not replay against the gating ASIC: %v\nOutput: %s", err, out)
	}
	if !strings.Contains(string(out), "MGMT TRACE TEST PASSED") {
		t.Errorf("the firmware's trace did not replay against the gating ASIC:\n%s", out)
	}
}

// TestIntegration_CBootPhases checks the two boot phases that used to be
// no-ops in both twins -- the routing-table load and the MoE gating load --
// against each other.  The C firmware programs the 11-bit routing bitmaps
// and counts the gating engines; the Go twin emits one command per node
// carrying the same bitmap.  They must agree.
func TestIntegration_CBootPhases(t *testing.T) {
	fwDir := SiblingRepo("fw")
	if _, err := os.Stat(filepath.Join(fwDir, "test_boot_phases.c")); os.IsNotExist(err) {
		t.Skip("fw/test_boot_phases.c not found")
	}
	gcc := gccPath()
	if gcc == "" {
		t.Skip("gcc not found in PATH")
	}

	bin := filepath.Join(os.TempDir(), "test_boot_phases_c")
	if runtime.GOOS == "windows" {
		bin += ".exe"
	}

	cmd := exec.Command(gcc, "-Wall", "-Wextra", "-std=c11",
		"-o", bin, "test_boot_phases.c", "pnm_fw.c")
	cmd.Dir = fwDir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("test_boot_phases.c compile failed: %v\nOutput: %s", err, out)
	}

	cmd = exec.Command(bin)
	cmd.Dir = fwDir
	out, err = cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("test_boot_phases run failed: %v\nOutput: %s", err, out)
	}
	if !strings.Contains(string(out), "BOOT PHASES TEST PASSED") {
		t.Fatalf("test_boot_phases did not self-pass:\n%s", out)
	}

	// The C's routing table, as (layer, x, y, bitmap).
	cRoutes := map[NodeID]uint16{}
	cCount, cGating := -1, -1
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		switch fields[0] {
		case "ROUTING_COUNT":
			fmt.Sscanf(line, "ROUTING_COUNT %d", &cCount)
		case "GATING_COUNT":
			fmt.Sscanf(line, "GATING_COUNT %d", &cGating)
		case "ROUTE":
			var l, x, y int
			var bits uint16
			fmt.Sscanf(line, "ROUTE %d %d %d %04X", &l, &x, &y, &bits)
			cRoutes[NodeID{L: l, X: x, Y: y}] = bits
		}
	}
	if cCount < 0 || len(cRoutes) != cCount {
		t.Fatalf("the C reported %d routing entries but printed %d", cCount, len(cRoutes))
	}

	// The Go twin's routing table, from the same chassis shape.
	drv := &Driver{
		Dims: Dims{Layers: 2, Bx: 4, By: 4},
	}
	drv.MC = &ModelCompiler{NodeAssignments: map[NodeID]*NodeAssignment{}}
	for l := 0; l < drv.Dims.Layers; l++ {
		for x := 0; x < drv.Dims.Bx; x++ {
			for y := 0; y < drv.Dims.By; y++ {
				nid := NodeID{L: l, X: x, Y: y}
				drv.MC.NodeAssignments[nid] = &NodeAssignment{Node: nid}
			}
		}
	}
	drv.RouteBitmaps = drv.computeRouteBitmaps()
	fw := &Firmware{Driver: drv}
	cmds, err := fw.bootRoutingTable()
	if err != nil {
		t.Fatalf("the Go twin's routing phase failed: %v", err)
	}
	if len(cmds) != cCount {
		t.Errorf("the Go twin produced %d routing commands, the C %d", len(cmds), cCount)
	}
	for _, c := range cmds {
		nid := NodeID{L: c.TargetLayer, X: int(c.TargetModule >> 4), Y: int(c.TargetModule & 0x0F)}
		want := cRoutes[nid]
		got := uint16(c.Payload[0])<<8 | uint16(c.Payload[1])
		if got != want {
			t.Errorf("node %v: the Go twin's bitmap is %04X, the C's %04X", nid, got, want)
		}
	}
	if fw.RoutingCount != cCount {
		t.Errorf("the Go twin counted %d routing commands, the C %d", fw.RoutingCount, cCount)
	}

	// The gating phase: the C counts the layers that hold a router.
	if cGating != 3 {
		t.Errorf("the C counted %d gating programs, expected 3", cGating)
	}
}

// TestIntegration_CMoeGating verifies the C firmware's deterministic top-k
// MoE gating (select_topk in pnm_fw.c) matches the Go reference selectTopExperts
// bit-for-bit for several (token, layer) inputs.
func TestIntegration_CMoeGating(t *testing.T) {
	fwDir := SiblingRepo("fw")
	if _, err := os.Stat(filepath.Join(fwDir, "test_moe_gating.c")); os.IsNotExist(err) {
		t.Skip("fw/test_moe_gating.c not found")
	}
	gcc := gccPath()
	if gcc == "" {
		t.Skip("gcc not found in PATH")
	}

	bin := filepath.Join(os.TempDir(), "test_moe_gating_c")
	if runtime.GOOS == "windows" {
		bin += ".exe"
	}

	cmd := exec.Command(gcc, "-Wall", "-Wextra", "-std=c11",
		"-o", bin, "test_moe_gating.c", "pnm_fw.c")
	cmd.Dir = fwDir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("test_moe_gating.c compile failed: %v\nOutput: %s", err, out)
	}

	cmd = exec.Command(bin)
	cmd.Dir = fwDir
	out, err = cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("test_moe_gating run failed: %v\nOutput: %s", err, out)
	}
	if !strings.Contains(string(out), "RESULT: ALL PASS") {
		t.Fatalf("test_moe_gating did not self-pass:\n%s", out)
	}

	const numExperts = 16
	const topK = 16
	lines := strings.Split(string(out), "\n")
	for _, line := range lines {
		if !strings.HasPrefix(line, "TOKEN") {
			continue
		}
		parts := strings.Fields(line)
		if len(parts) < 4 || parts[0] != "TOKEN" || parts[2] != "SEL" {
			t.Errorf("malformed moe gating line %q", line)
			continue
		}
		tok := parts[1]
		got := make([]int, 0, topK)
		for _, s := range parts[3:] {
			var e int
			if _, err := fmt.Sscanf(s, "%d", &e); err != nil {
				t.Errorf("bad expert token %q: %v", s, err)
				continue
			}
			got = append(got, e)
		}

		// The C test builds a contiguous 0..numExperts-1 population, so the
		// expected Go result must score the same population by its global indices.
		population := make([]int, numExperts)
		for i := range population {
			population[i] = i
		}
		expected := selectTopExperts([]byte(tok), 0, population, topK)
		if len(got) != len(expected) {
			t.Errorf("token %q: got %d experts, expected %d", tok, len(got), len(expected))
			continue
		}
		for i := range expected {
			if got[i] != expected[i] {
				t.Errorf("token %q: C[%d]=%d, Go=%d (C ranks %v, Go ranks %v)",
					tok, i, got[i], expected[i], got, expected)
				break
			}
		}
	}
}

// TestIntegration_HDLTestbench verifies HDL testbenches compile and pass.
// This requires iverilog in PATH.
func TestIntegration_HDLTestbench(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}

	iverilog := iverilogPath()
	vvp := vvpPath()
	if iverilog == "" || vvp == "" {
		t.Skip("iverilog/vvp not found in PATH")
	}

	hdlDir := SiblingRepo("HDL")
	type tbCase struct {
		name string
		src  []string
	}

	cases := []tbCase{
		{"bf16_fma", []string{"core/arith_unit.v", "core/bf16_fma.v", "core/fma_core.v", "core/tb_bf16_fma.v"}},
		{"fp64_alu", []string{"core/arith_unit.v", "core/fp64_alu.v", "core/fp64_fma.v", "core/fma_core.v", "core/tb_fp64_alu.v"}},
		{"fabric", []string{"hfr.v", "flit_gate.v", "vc_merge.v", "lxy_repeater.v", "xy_turn.v", "node_eject.v", "tb_fabric.v"}},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			bin := filepath.Join(os.TempDir(), "tb_"+c.name)
			if runtime.GOOS == "windows" {
				bin += ".exe"
			}

			// Compile
			args := append([]string{"-g2005", "-o", bin}, c.src...)
			cmd := exec.Command(iverilog, args...)
			cmd.Dir = hdlDir
			out, err := cmd.CombinedOutput()
			if err != nil {
				t.Fatalf("iverilog compile failed: %v\nOutput: %s", err, out)
			}

			// Run
			cmd = exec.Command(vvp, bin)
			cmd.Dir = hdlDir
			out, err = cmd.CombinedOutput()
			if err != nil {
				t.Errorf("vvp execution failed: %v\nOutput: %s", err, out)
			}
		})
	}
}

// TestIntegration_GoBuildAll verifies all Go packages build.
func TestIntegration_GoBuildAll(t *testing.T) {
	goBin := goPath()
	if goBin == "" {
		t.Skip("go not found in PATH")
	}

	cmd := exec.Command(goBin, "build", "./...")
	cmd.Dir = SimDir()
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Errorf("go build failed: %v\nOutput: %s", err, out)
	}
}

// TestIntegration_DesClosedForm verifies the DES model matches the closed-form latency.
func TestIntegration_DesClosedForm(t *testing.T) {
	// This is already covered by unit tests, but included here as an
	// integration checkpoint
	t.Run("des_closed_form", func(t *testing.T) {
		TestDESClosedForm(t)
	})
}

// ── Helpers ─────────────────────────────────────────────────────────────────

func goPath() string {
	if p, err := exec.LookPath("go"); err == nil {
		return p
	}
	matches, _ := filepath.Glob("/nix/store/*/bin/go")
	if len(matches) > 0 {
		return matches[0]
	}
	return ""
}

func gccPath() string {
	if p, err := exec.LookPath("gcc"); err == nil {
		return p
	}
	matches, _ := filepath.Glob("/nix/store/*/bin/gcc")
	if len(matches) > 0 {
		return matches[0]
	}
	return ""
}

func iverilogPath() string {
	if p, err := exec.LookPath("iverilog"); err == nil {
		return p
	}
	matches, _ := filepath.Glob("/nix/store/*/bin/iverilog")
	if len(matches) > 0 {
		return matches[0]
	}
	return ""
}

func vvpPath() string {
	if p, err := exec.LookPath("vvp"); err == nil {
		return p
	}
	matches, _ := filepath.Glob("/nix/store/*/bin/vvp")
	if len(matches) > 0 {
		return matches[0]
	}
	return ""
}
