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

			// Run the model compiler
			goBin := goPath()
			if goBin == "" {
				t.Skip("go not found in PATH")
				return
			}

			cmd := exec.Command(goBin, "run", "./cmd/pnmc", "compile-model",
				filepath.Join("examples", ex),
				"-l", "4", "-x", "4", "-y", "4")
			cmd.Dir = simDir
			out, err := cmd.CombinedOutput()
			if err != nil {
				t.Errorf("model compiler failed: %v\nOutput: %s", err, out)
			}

			// Verify output files were generated
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
	fwDir := filepath.Join(SimDir(), "..", "fw")
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
	fwDir := filepath.Join(SimDir(), "..", "fw")
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

// TestIntegration_CMoeGating verifies the C firmware's deterministic top-k
// MoE gating (select_topk in pnm_fw.c) matches the Go reference selectTopExperts
// bit-for-bit for several (token, layer) inputs.
func TestIntegration_CMoeGating(t *testing.T) {
	fwDir := filepath.Join(SimDir(), "..", "fw")
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

	hdlDir := filepath.Join(SimDir(), "..", "HDL")
	type tbCase struct {
		name string
		src  []string
	}

	cases := []tbCase{
		{"bf16_fma", []string{"core/bf16_fma.v", "core/tb_bf16_fma.v"}},
		{"fp64_alu", []string{"core/fp64_alu.v", "core/fp64_fma.v", "core/tb_fp64_alu.v"}},
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
