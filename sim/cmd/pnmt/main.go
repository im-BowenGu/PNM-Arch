// Command pnmt is the PNM project test runner.
//
// It discovers toolchains (iverilog, vvp, go, gcc) from PATH or the Nix
// store, then runs test categories in dependency order with structured
// pass/fail/skip reporting.
//
// Usage:
//
//	go run ./cmd/pnmt                    # full suite
//	go run ./cmd/pnmt smoke              # critical path only (~30s)
//	go run ./cmd/pnmt hdl                # all HDL testbenches
//	go run ./cmd/pnmt hdl-core           # core compute units only
//	go run ./cmd/pnmt hdl-fabric         # fabric/routing only
//	go run ./cmd/pnmt hdl-phy            # memory/PHY only
//	go run ./cmd/pnmt go                 # Go unit tests
//	go run ./cmd/pnmt c                  # C firmware compile check
//	go run ./cmd/pnmt integration        # end-to-end simulation
//	go run ./cmd/pnmt lint               # static analysis
//	go run ./cmd/pnmt coverage           # Go coverage report
//	go run ./cmd/pnmt -j 4 hdl           # 4 parallel HDL jobs
//	go run ./cmd/pnmt -v hdl-core        # verbose output
package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

// ── Tool Discovery ──────────────────────────────────────────────────────────

type tools struct {
	iverilog string
	vvp      string
	goBin    string
	gcc      string
	verilator string
}

func discoverTools() tools {
	t := tools{
		goBin: findTool("go"),
		gcc:   findTool("gcc"),
	}
	// HDL tools
	t.iverilog = findTool("iverilog")
	t.vvp = findTool("vvp")
	t.verilator = findTool("verilator")
	return t
}

func findTool(name string) string {
	if p, err := exec.LookPath(name); err == nil {
		return p
	}
	// Search nix store (common paths)
	for _, pattern := range []string{
		"/nix/store/*/bin/" + name,
	} {
		matches, _ := filepath.Glob(pattern)
		if len(matches) > 0 {
			return matches[0]
		}
	}
	return ""
}

// ── Test Results ────────────────────────────────────────────────────────────

type status int

const (
	pass status = iota
	fail
	skip
)

func (s status) String() string {
	switch s {
	case pass:
		return "PASS"
	case fail:
		return "FAIL"
	case skip:
		return "SKIP"
	default:
		return "?"
	}
}

type result struct {
	category string
	name     string
	status   status
	duration time.Duration
	output   string
	reason   string // for skip
}

// ── Test Runner ─────────────────────────────────────────────────────────────

type runner struct {
	t         tools
	results   []result
	verbose   bool
	jobs      int
	failed    bool
	failures  []string
}

func newRunner(t tools, verbose bool, jobs int) *runner {
	return &runner{t: t, verbose: verbose, jobs: jobs}
}

// run executes a command and returns (output, exitCode).
func (r *runner) run(name string, dir string, args ...string) (string, int) {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "PATH="+filepath.Dir(r.t.iverilog)+":"+os.Getenv("PATH"))

	var out []byte
	var err error
	if r.verbose {
		out, err = cmd.CombinedOutput()
	} else {
		out, err = cmd.Output()
	}
	code := 0
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			code = exitErr.ExitCode()
		} else {
			code = -1
		}
	}
	return string(out), code
}

func (r *runner) runTest(cat, name string, fn func() (string, int)) {
	start := time.Now()
	output, code := fn()
	dur := time.Since(start)

	res := result{
		category: cat,
		name:     name,
		duration: dur,
		output:   output,
	}
	if code == 0 {
		res.status = pass
	} else {
		res.status = fail
		r.failed = true
		r.failures = append(r.failures, cat+"/"+name)
	}
	r.results = append(r.results, res)
}

func (r *runner) skipTest(cat, name, reason string) {
	r.results = append(r.results, result{
		category: cat,
		name:     name,
		status:   skip,
		reason:   reason,
	})
}

func (r *runner) compileAndRun(cat, name, dir string, srcFiles []string, bin, desc string) {
	if r.t.iverilog == "" || r.t.vvp == "" {
		r.skipTest(cat, name, "iverilog/vvp not found")
		return
	}
	r.runTest(cat, name, func() (string, int) {
		// Compile
		args := append([]string{"-g2005", "-o", bin}, srcFiles...)
		out, code := r.run(r.t.iverilog, dir, args...)
		if code != 0 {
			return out, code
		}
		// Run
		out, code = r.run(r.t.vvp, dir, bin)
		return out, code
	})
}

// ── Test Categories ─────────────────────────────────────────────────────────

func (r *runner) hdlCore() {
	cat := "hdl/core"
	h := "../HDL"
	ext := ""
	if runtime.GOOS == "windows" {
		ext = ".exe"
	}

	type tbCase struct {
		name string
		src  []string
	}

	cases := []tbCase{
		{"bf16_fma", []string{"core/bf16_fma.v", "core/tb_bf16_fma.v"}},
		{"bf16_fma_edge", []string{"core/bf16_fma.v", "core/tb_bf16_fma_edge.v"}},
		{"fp16_fma", []string{"core/fp16_fma.v", "core/tb_fp16_fma.v"}},
		{"fp16_fma_edge", []string{"core/fp16_fma.v", "core/tb_fp16_fma_edge.v"}},
		{"fp32_fma", []string{"core/fp32_fma.v", "core/tb_fp32_fma.v"}},
		{"fp64_fma", []string{"core/fp64_fma.v", "core/tb_fp64_fma.v"}},
		{"fp32_alu", []string{"core/fp32_alu.v", "core/fp32_fma.v", "core/tb_fp32_alu.v"}},
		{"fp32_alu_edge", []string{"core/fp32_alu.v", "core/fp32_fma.v", "core/tb_fp32_alu_edge.v"}},
		{"fp32_alu_chip", []string{"core/fp32_alu_chip.v", "core/fp32_alu.v", "core/fp32_fma.v", "core/crc16.v", "core/tb_fp32_alu_chip.v"}},
		{"pe_int4", []string{"core/pe_tile_stub.v", "core/crc16.v", "core/bf16_fma.v", "core/weight_dequant.v", "core/int8_mac.v", "core/fp4_mac.v", "core/tb_pe_int4.v"}},
		{"fp64_alu", []string{"core/fp64_alu.v", "core/fp64_fma.v", "core/tb_fp64_alu.v"}},
		{"int8_mac", []string{"core/int8_mac.v", "core/tb_int8_mac.v"}},
		{"int8_alu", []string{"core/int8_alu.v", "core/tb_int8_alu.v"}},
		{"bf16_mac_array", []string{"core/bf16_mac_array.v", "core/bf16_fma.v", "core/tb_bf16_mac_array.v"}},
		{"fp16_mac_array", []string{"core/fp16_mac_array.v", "core/fp16_fma.v", "core/tb_fp16_mac_array.v"}},
		{"fp32_mac_array", []string{"core/fp32_mac_array.v", "core/fp32_fma.v", "core/tb_fp32_mac_array.v"}},
		{"int4_mac_array", []string{"core/int4_mac_array.v", "core/int8_mac.v", "core/tb_int4_mac_array.v"}},
		{"fp4_mac", []string{"core/fp4_mac.v", "core/tb_fp4_mac.v"}},
		{"fp4_mac_array", []string{"core/fp4_mac_array.v", "core/fp4_mac.v", "core/tb_fp4_mac_array.v"}},
		{"mxfp4_mac_array", []string{"core/mxfp4_mac_array.v", "core/fp4_mac.v", "core/tb_mxfp4_mac_array.v"}},
		{"moe_gating", []string{"core/moe_gating.v", "core/bf16_fma.v", "core/tb_moe_gating.v"}},
		{"rotary_engine", []string{"core/rotary_engine.v", "core/tb_rotary_engine.v"}},
		{"weight_dequant", []string{"core/weight_dequant.v", "core/tb_weight_dequant.v"}},
		{"kv_quant", []string{"core/kv_quant.v", "core/tb_kv_quant.v"}},
		{"dyn_act_quant", []string{"core/dyn_act_quant.v", "core/tb_dyn_act_quant.v"}},
		{"crc16", []string{"core/crc16.v", "core/tb_crc16.v"}},
		{"doorbell", []string{"core/pe_tile_stub.v", "core/doorbell.v", "core/crc16.v", "core/bf16_fma.v", "core/weight_dequant.v", "core/int8_mac.v", "core/fp4_mac.v", "core/tb_doorbell.v"}},
	}

	for _, c := range cases {
		bin := filepath.Join("/tmp", "tb_"+c.name+ext)
		r.compileAndRun(cat, c.name, h, c.src, bin, c.name)
	}
}

func (r *runner) hdlFabric() {
	cat := "hdl/fabric"
	h := "../HDL"
	ext := ""
	if runtime.GOOS == "windows" {
		ext = ".exe"
	}

	type tbCase struct {
		name string
		src  []string
	}

	cases := []tbCase{
		{"fabric", []string{"hfr.v", "flit_gate.v", "vc_merge.v", "lxy_repeater.v", "xy_turn.v", "node_eject.v", "tb_fabric.v"}},
		{"load", []string{"hfr.v", "flit_gate.v", "vc_merge.v", "lxy_repeater.v", "xy_turn.v", "node_eject.v", "tb_load.v"}},
		{"orchestrator_chip", []string{"orchestrator_chip.v", "core/moe_gating.v", "core/bf16_fma.v", "tb_orchestrator_chip.v"}},
		{"orchestrator_mcu", []string{"orchestrator_mcu.v", "rv32_core.v", "uart.v", "clint.v", "tb_orchestrator_mcu.v"}},
		{"orchestrator_sbc", []string{"orchestrator_sbc.v", "rv32_core.v", "uart.v", "clint.v", "pcie_phy.v", "nvme_ctrl.v", "tb_orchestrator_sbc.v"}},
		{"orchestrator_sbc_moe", []string{"orchestrator_sbc_moe.v", "rv32_core.v", "uart.v", "clint.v", "core/moe_gating.v", "core/bf16_fma.v", "tb_orchestrator_sbc_moe.v"}},
		{"bmc_orchestrator", []string{"rv32_core.v", "uart.v", "clint.v", "bmc_orchestrator_top.v", "tb_bmc_orchestrator.v"}},
		{"pi_bridge", []string{"pi_bridge.v", "tb_pi_bridge.v"}},
		{"host_bmc", []string{"pi_bridge.v", "pnm_arb.v", "tb_host_bmc.v"}},
	}

	for _, c := range cases {
		bin := filepath.Join("/tmp", "tb_"+c.name+ext)
		r.compileAndRun(cat, c.name, h, c.src, bin, c.name)
	}
}

func (r *runner) hdlPhy() {
	cat := "hdl/phy"
	h := "../HDL"
	ext := ""
	if runtime.GOOS == "windows" {
		ext = ".exe"
	}

	type tbCase struct {
		name string
		src  []string
	}

	cases := []tbCase{
		{"lpddr5_phy", []string{"lpddr5_phy.v", "tb_lpddr5_phy.v"}},
		{"lpddr5x_phy", []string{"lpddr5x_phy.v", "tb_lpddr5x_phy.v"}},
		{"lpddr6_phy", []string{"lpddr6_phy.v", "tb_lpddr6_phy.v"}},
		{"dma_lpddr6", []string{"pi_bridge.v", "pnm_arb.v", "lpddr6_camm.v", "tb_dma_lpddr6.v"}},
		{"sodimm_lpddr", []string{"pi_bridge.v", "pnm_arb.v", "lpddr6_camm.v", "tb_sodimm_lpddr.v"}},
		{"sodimm_ctrl", []string{"sodimm_ctrl.v", "tb_sodimm_ctrl.v"}},
		{"pcb_link", []string{"pcb_link.v", "tb_pcb_link.v"}},
		{"optical_link", []string{"optical_link.v", "tb_optical_link.v"}},
		{"pcie_phy", []string{"pcie_phy.v", "tb_pcie_phy.v"}},
		{"nvme_ctrl", []string{"nvme_ctrl.v", "tb_nvme_ctrl.v"}},
		{"power_rails", []string{"power_rails.v", "tb_power_rails.v"}},
		{"pcb_si_link", []string{"pcb_si_link.v", "tb_pcb_si_link.v"}},
		{"rst_sync", []string{"rst_sync.v", "tb_rst_sync.v"}},
		{"clk_gate", []string{"clk_gate.v", "tb_clk_gate.v"}},
	}

	for _, c := range cases {
		bin := filepath.Join("/tmp", "tb_"+c.name+ext)
		r.compileAndRun(cat, c.name, h, c.src, bin, c.name)
	}
}

func (r *runner) goTests() {
	cat := "go"
	sim := "."

	type testRun struct {
		name  string
		pat   string
	}

	cases := []testRun{
		{"crc", "TestCRC"},
		{"rng", "TestPyRand"},
		{"des_closed_form", "TestDESClosedForm"},
		{"pipe_encode_decode", "TestFlitMessage"},
		{"pipe_named_pipe", "TestNamedPipe"},
		{"pipe_circuit_link", "TestCircuitLink"},
		{"virtual_units", "Test(Consume|KEcho|KSum|KAccum|KDot|NewVirtualUnit|Decode)"},
		{"driver", "Test(DriverFirmware|RouterBitmaps|ComputeUnit)"},
		{"run_flit", "TestFlit_"},
		{"toolchain", "TestToolchain"},
		{"llm_client", "TestLLMClient"},
		{"property_crc", "TestCRC16_(Incremental|Deterministic)"},
	}

	for _, c := range cases {
		name := c.name
		pat := c.pat
		r.runTest(cat, name, func() (string, int) {
			if r.t.goBin == "" {
				return "", 1
			}
			out, code := r.run(r.t.goBin, sim, "test", "./internal/pnm/",
				"-run", pat, "-count=1", "-timeout", "90s")
			return out, code
		})
	}
}

func (r *runner) cTests() {
	cat := "c"

	r.runTest(cat, "fw_compile", func() (string, int) {
		if r.t.gcc == "" {
			return "", 1
		}
		return r.run(r.t.gcc, "../fw", "-Wall", "-Wextra", "-std=c11", "-c", "pnm_fw.c", "-o", "/dev/null")
	})

	r.runTest(cat, "fw_compile_mcu", func() (string, int) {
		if r.t.gcc == "" {
			return "", 1
		}
		return r.run(r.t.gcc, "../fw", "-Wall", "-Wextra", "-std=c11", "-DPNM_MCU", "-c", "pnm_fw.c", "-o", "/dev/null")
	})
}

func (r *runner) integrationTests() {
	cat := "integration"
	sim := "."

	r.runTest(cat, "des_cross_check_rtl", func() (string, int) {
		if r.t.goBin == "" || r.t.iverilog == "" {
			return "", 1
		}
		// Add iverilog dir to PATH so Go subprocess can find it
		env := os.Environ()
		if r.t.iverilog != "" {
			env = append(env, "PATH="+filepath.Dir(r.t.iverilog)+":"+os.Getenv("PATH"))
		}
		cmd := exec.Command(r.t.goBin, "test", "./internal/pnm/",
			"-run", "TestDESCrossCheckRTL", "-count=1", "-timeout", "120s")
		cmd.Dir = sim
		cmd.Env = env
		out, err := cmd.CombinedOutput()
		code := 0
		if err != nil {
			if exitErr, ok := err.(*exec.ExitError); ok {
				code = exitErr.ExitCode()
			} else {
				code = -1
			}
		}
		return string(out), code
	})

	r.runTest(cat, "model_compiler_gemma4", func() (string, int) {
		if r.t.goBin == "" {
			return "", 1
		}
		return r.run(r.t.goBin, sim, "run", "./cmd/pnmc", "compile-model",
			"examples/gemma4_test", "-l", "4", "-x", "4", "-y", "4")
	})

	r.runTest(cat, "model_compiler_mini_moe", func() (string, int) {
		if r.t.goBin == "" {
			return "", 1
		}
		return r.run(r.t.goBin, sim, "run", "./cmd/pnmc", "compile-model",
			"examples/mini_glm_moe", "-l", "4", "-x", "4", "-y", "4")
	})

	r.runTest(cat, "host_driver_gemma4", func() (string, int) {
		if r.t.goBin == "" {
			return "", 1
		}
		return r.run(r.t.goBin, sim, "run", "./cmd/pnmc", "run-driver",
			"examples/gemma4_test", "-l", "4", "-x", "4", "-y", "4")
	})
}

func (r *runner) lintTests() {
	cat := "lint"
	sim := "."

	if r.t.verilator != "" {
		r.runTest(cat, "verilator_fabric", func() (string, int) {
			return r.run(r.t.verilator, "../HDL", "--lint-only",
				"-Wno-MULTITOP", "-Wno-TIMESCALEMOD",
				"hfr.v", "flit_gate.v", "vc_merge.v", "lxy_repeater.v", "xy_turn.v", "node_eject.v")
		})
	} else {
		r.skipTest(cat, "verilator_fabric", "verilator not found")
	}

	if r.t.goBin != "" {
		r.runTest(cat, "go_vet", func() (string, int) {
			return r.run(r.t.goBin, sim, "vet", "./...")
		})
	}
}

func (r *runner) coverageTests() {
	cat := "coverage"
	sim := "."

	if r.t.goBin == "" {
		r.skipTest(cat, "go_coverage", "go not found")
		return
	}

	r.runTest(cat, "go_coverage", func() (string, int) {
		out, code := r.run(r.t.goBin, sim, "test", "./internal/pnm/",
			"-coverprofile=/tmp/pnm_coverage.out", "-covermode=atomic",
			"-count=1", "-timeout", "120s", "-run", "Test[^D]")
		if code != 0 {
			return out, code
		}
		summary, _ := r.run(r.t.goBin, "tool", "cover", "-func=/tmp/pnm_coverage.out")
		return summary, 0
	})
}

// ── Output ──────────────────────────────────────────────────────────────────

func (r *runner) printHeader() {
	fmt.Println("PNM Test Suite")
	fmt.Println(strings.Repeat("=", 60))
}

func (r *runner) printCategory(name string) {
	fmt.Printf("\n\033[1m=== %s ===\033[0m\n", name)
}

func (r *runner) printResult(res result) {
	elapsed := fmt.Sprintf("%dms", res.duration.Milliseconds())
	name := fmt.Sprintf("%-40s", res.name)

	switch res.status {
	case pass:
		fmt.Printf("  %s \033[32mPASS\033[0m (%s)\n", name, elapsed)
	case fail:
		fmt.Printf("  %s \033[31mFAIL\033[0m (%s)\n", name, elapsed)
		if r.verbose && res.output != "" {
			lines := strings.Split(strings.TrimSpace(res.output), "\n")
			start := 0
			if len(lines) > 5 {
				start = len(lines) - 5
			}
			for _, l := range lines[start:] {
				fmt.Printf("        %s\n", l)
			}
		}
	case skip:
		fmt.Printf("  %s \033[33mSKIP\033[0m (%s)\n", name, res.reason)
	}
}

func (r *runner) printSummary() {
	fmt.Println()
	fmt.Println(strings.Repeat("=", 60))

	var passCount, failCount, skipCount int
	for _, res := range r.results {
		switch res.status {
		case pass:
			passCount++
		case fail:
			failCount++
		case skip:
			skipCount++
		}
	}

	total := passCount + failCount + skipCount

	if failCount == 0 {
		fmt.Printf("\033[32mAll %d tests passed\033[0m (%d total, %d skipped)\n",
			passCount, total, skipCount)
	} else {
		fmt.Printf("\033[31m%d/%d tests FAILED\033[0m (%d passed, %d skipped)\n",
			failCount, total, passCount, skipCount)
		fmt.Println()
		fmt.Println("Failed tests:")
		for _, f := range r.failures {
			fmt.Printf("  \033[31m✗\033[0m %s\n", f)
		}
	}
	fmt.Println(strings.Repeat("=", 60))
}

// ── Main ────────────────────────────────────────────────────────────────────

func main() {
	verbose := flag.Bool("v", false, "verbose output (show test stdout/stderr)")
	jobs := flag.Int("j", runtime.NumCPU(), "parallel test jobs (HDl only)")
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: pnmt [flags] [category]\n\n")
		fmt.Fprintf(os.Stderr, "Categories:\n")
		fmt.Fprintf(os.Stderr, "  full         all tests (default)\n")
		fmt.Fprintf(os.Stderr, "  smoke        critical path only (~30s)\n")
		fmt.Fprintf(os.Stderr, "  hdl          all HDL testbenches\n")
		fmt.Fprintf(os.Stderr, "  hdl-core     core compute units only\n")
		fmt.Fprintf(os.Stderr, "  hdl-fabric   fabric/routing only\n")
		fmt.Fprintf(os.Stderr, "  hdl-phy      memory/PHY only\n")
		fmt.Fprintf(os.Stderr, "  go           Go unit tests\n")
		fmt.Fprintf(os.Stderr, "  c            C firmware compile check\n")
		fmt.Fprintf(os.Stderr, "  integration  end-to-end simulation\n")
		fmt.Fprintf(os.Stderr, "  lint         static analysis\n")
		fmt.Fprintf(os.Stderr, "  coverage     Go coverage report\n\n")
		fmt.Fprintf(os.Stderr, "Flags:\n")
		flag.PrintDefaults()
	}
	flag.Parse()

	category := "full"
	if flag.NArg() > 0 {
		category = flag.Arg(0)
	}

	t := discoverTools()
	_ = jobs // used for future parallel HDL compilation
	r := newRunner(t, *verbose, *jobs)

	r.printHeader()
	toolNames := []string{}
	if t.iverilog != "" {
		toolNames = append(toolNames, "iverilog="+filepath.Base(t.iverilog))
	}
	if t.vvp != "" {
		toolNames = append(toolNames, "vvp="+filepath.Base(t.vvp))
	}
	if t.goBin != "" {
		toolNames = append(toolNames, "go="+filepath.Base(t.goBin))
	}
	if t.gcc != "" {
		toolNames = append(toolNames, "gcc="+filepath.Base(t.gcc))
	}
	if t.verilator != "" {
		toolNames = append(toolNames, "verilator="+filepath.Base(t.verilator))
	}
	fmt.Printf("Tools: %s\n", strings.Join(toolNames, " "))

	switch category {
	case "smoke":
		r.printCategory("HDL Core (critical)")
		r.hdlCore()
		r.printCategory("Go Unit Tests")
		r.goTests()
		r.printCategory("C Firmware")
		r.cTests()

	case "hdl":
		r.printCategory("HDL Core Compute Units")
		r.hdlCore()
		r.printCategory("HDL Fabric/Routing")
		r.hdlFabric()
		r.printCategory("HDL Memory/PHY")
		r.hdlPhy()

	case "hdl-core":
		r.printCategory("HDL Core Compute Units")
		r.hdlCore()

	case "hdl-fabric":
		r.printCategory("HDL Fabric/Routing")
		r.hdlFabric()

	case "hdl-phy":
		r.printCategory("HDL Memory/PHY")
		r.hdlPhy()

	case "go":
		r.printCategory("Go Tests")
		r.goTests()

	case "c":
		r.printCategory("C Firmware")
		r.cTests()

	case "integration":
		r.printCategory("Integration Tests")
		r.integrationTests()

	case "lint":
		r.printCategory("Lint / Static Analysis")
		r.lintTests()

	case "coverage":
		r.printCategory("Coverage")
		r.coverageTests()

	case "full":
		r.printCategory("HDL Core Compute Units")
		r.hdlCore()
		r.printCategory("HDL Fabric/Routing")
		r.hdlFabric()
		r.printCategory("HDL Memory/PHY")
		r.hdlPhy()
		r.printCategory("Go Tests")
		r.goTests()
		r.printCategory("C Firmware")
		r.cTests()
		r.printCategory("Integration Tests")
		r.integrationTests()
		r.printCategory("Lint / Static Analysis")
		r.lintTests()

	default:
		fmt.Fprintf(os.Stderr, "Unknown category: %s\n\n", category)
		flag.Usage()
		os.Exit(1)
	}

	r.printSummary()

	if r.failed {
		os.Exit(1)
	}
}
