package pnm

// node_harness.go — compute-node (node.v) ASIC service for the composition
// path.  pnmgate/tests boot one persistent vvp process that runs
// HDL/core/tb_node_server.v (node.v + the numeric FMA units), which:
//
//   1. BOOT  : loads one real expert's gate_up / down BF16 slice (wu.hex,
//              wd.hex) into node.v's weight SRAMs ("load weights into ram").
//   2. SERVE : per request n the harness writes the N-word BF16 hidden vector
//              to x_<n>.hex and drops req_<n>.go; the server streams it into
//              node.v, runs the expert pass (gate -> swiglu -> down), and
//              returns the N-wide expert output in res_<n>.txt + res_<n>.done.
//
// This is the compute complement of the gating service (gating_harness.go):
// the router decides on the gating ASIC, the token/hidden travels the node
// network (gated_fabric.go, RunOne byte-exact), and node.v loads the hidden
// vector and runs the expert.  The host twin (expertTwin in bf16_oracle.go)
// cross-checks every output word bit-exactly.

import (
	"bufio"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// NodeConfig configures a compute-node service.
type NodeConfig struct {
	RunDir    string // scratch directory for weight/hidden/result files
	Layer     int    // model layer
	Expert    int    // expert index
	EffFull   int    // full expert intermediate size (gate+up rows each)
	HiddenDim int    // full hidden size
	GU        int    // slice weight rows = 2*EFF (BF16)
	N         int    // slice hidden width
	EFF       int    // slice intermediate width
	CU        int    // CU_TYPE (0 = BF16 fused-FMA expert)
	Width     int    // external element width (16 for BF16)
	Verbose   bool
	KeepFiles bool
}

// nodeClient serves one (layer, expert) slice from a persistent vvp process.
type nodeClient struct {
	cfg       NodeConfig
	hdlDir    string
	serverBin string
	dir       string
	proc      *asicProc
	n         int
}

func newNodeClient(cfg NodeConfig) (*nodeClient, error) {
	if _, err := exec.LookPath("iverilog"); err != nil {
		return nil, fmt.Errorf("iverilog not found (enter `nix develop`): %w", err)
	}
	if _, err := exec.LookPath("vvp"); err != nil {
		return nil, fmt.Errorf("vvp not found (enter `nix develop`): %w", err)
	}
	hdl, err := findHDLDir()
	if err != nil {
		return nil, err
	}
	if cfg.RunDir == "" {
		cfg.RunDir = "/tmp/pnmgate"
	}
	c := &nodeClient{cfg: cfg, hdlDir: hdl}
	if cfg.GU <= 0 {
		cfg.GU = 2 * cfg.EFF
	}
	if cfg.Width <= 0 {
		cfg.Width = 16
	}

	// Compile the persistent server once.
	c.serverBin = filepath.Join(cfg.RunDir, "node_server.vvp")
	iverilog := []string{
		"-g2005", "-s", "tb_node_server", "-o", c.serverBin,
		filepath.Join(hdl, "tb_node_server.v"),
		filepath.Join(hdl, "node.v"),
		filepath.Join(hdl, "arith_unit.v"),
		filepath.Join(hdl, "bf16_fma.v"),
		filepath.Join(hdl, "fp16_fma.v"),
		filepath.Join(hdl, "fp32_fma.v"),
		filepath.Join(hdl, "fp64_fma.v"),
		filepath.Join(hdl, "fma_core.v"),
		filepath.Join(hdl, "int8_mac.v"),
		filepath.Join(hdl, "int4_mac.v"),
		filepath.Join(hdl, "fp4_mac.v"),
		"-I", hdl, // node.v `includes bf16_fp.vh
		"-P", fmt.Sprintf("tb_node_server.N=%d", cfg.N),
		"-P", fmt.Sprintf("tb_node_server.EFF=%d", cfg.EFF),
		"-P", fmt.Sprintf("tb_node_server.CU_TYPE=%d", cfg.CU),
		"-P", fmt.Sprintf("tb_node_server.WIDTH=%d", cfg.Width),
		"-P", fmt.Sprintf("tb_node_server.GU_ROWS=%d", cfg.GU),
		"-P", "tb_node_server.MAXREQ=0",
	}
	if out, err := exec.Command("iverilog", iverilog...).CombinedOutput(); err != nil {
		return nil, fmt.Errorf("iverilog failed: %v\n%s", err, out)
	}

	if err := c.boot(); err != nil {
		return nil, err
	}
	if cfg.Verbose {
		fmt.Fprintf(os.Stderr, "[node] ASIC ready: L%d E%d N=%d EFF=%d CU=%d\n",
			cfg.Layer, cfg.Expert, cfg.N, cfg.EFF, cfg.CU)
	}
	return c, nil
}

// bootTwins loads the weight slices and starts the server process.
func (c *nodeClient) boot() error {
	cfg := c.cfg
	dir := filepath.Join(cfg.RunDir, fmt.Sprintf("N%d_E%d", cfg.Layer, cfg.Expert))
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}
	// Clear stale request/response markers from a previous run.
	for _, pat := range []string{"req_*.go", "res_*.done", "res_*.txt"} {
		if old, _ := filepath.Glob(filepath.Join(dir, pat)); old != nil {
			for _, f := range old {
				_ = os.Remove(f)
			}
		}
	}
	c.dir = dir
	return nil
}

// BuildWeightHex renders one expert's gate_up / down BF16 slice as wu.hex /
// wd.hex words in the server directory.  Feed it real payloads from the
// checkpoint via g.m.tensorBytes.
func (c *nodeClient) BuildWeightHex(rawGateUp, rawDown []byte) error {
	cfg := c.cfg
	gu, dw := expertB16Slice(rawGateUp, rawDown, cfg.Expert, cfg.EffFull, cfg.HiddenDim,
		cfg.GU, cfg.N, cfg.EFF)
	var wu, wd strings.Builder
	for r := 0; r < cfg.GU; r++ {
		for cc := 0; cc < cfg.N; cc++ {
			fmt.Fprintf(&wu, "%04x\n", gu[r][cc])
		}
	}
	for r := 0; r < cfg.N; r++ {
		for cc := 0; cc < cfg.EFF; cc++ {
			fmt.Fprintf(&wd, "%04x\n", dw[r][cc])
		}
	}
	if err := os.WriteFile(filepath.Join(c.dir, "wu.hex"), []byte(wu.String()), 0644); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(c.dir, "wd.hex"), []byte(wd.String()), 0644); err != nil {
		return err
	}
	return nil
}

// Start launches the vvp server and waits for status.txt.
func (c *nodeClient) Start() error {
	_ = os.Remove(filepath.Join(c.dir, "status.txt"))
	logf, err := os.Create(filepath.Join(c.dir, "server.log"))
	if err != nil {
		return err
	}
	cmd := exec.Command("vvp", c.serverBin)
	cmd.Dir = c.dir
	cmd.Stdout = logf
	cmd.Stderr = logf
	if err := cmd.Start(); err != nil {
		logf.Close()
		return err
	}
	c.proc = &asicProc{layer: c.cfg.Layer, dir: c.dir, cmd: cmd, log: logf, done: make(chan struct{})}
	go func() {
		cmd.Wait()
		close(c.proc.done)
	}()
	if err := waitFile(filepath.Join(c.dir, "status.txt"), 10*time.Minute, c.proc.done); err != nil {
		return fmt.Errorf("node L%d E%d boot: %w", c.cfg.Layer, c.cfg.Expert, err)
	}
	return nil
}

// Close kills the server process.
func (c *nodeClient) Close() {
	if c.proc != nil && c.proc.cmd != nil && c.proc.cmd.Process != nil {
		_ = c.proc.cmd.Process.Kill()
		<-c.proc.done
		c.proc.log.Close()
	}
}

// Expert runs the node.v ASIC expert pass over the given hidden vector
// (float32, BF16-rounded at the wire by the harness) and returns the N-wide
// expert output as BF16 words, bit-exact vs the software twin.
func (c *nodeClient) Expert(hidden []float32) ([]uint16, error) {
	var sb strings.Builder
	for cc := 0; cc < c.cfg.N; cc++ {
		v := float32(0)
		if cc < len(hidden) {
			v = roundBF16(hidden[cc])
		}
		fmt.Fprintf(&sb, "%04x\n", uint16(math.Float32bits(v)>>16))
	}
	xName := fmt.Sprintf("x_%d.hex", c.n)
	if err := os.WriteFile(filepath.Join(c.dir, xName), []byte(sb.String()), 0644); err != nil {
		return nil, err
	}
	goName := fmt.Sprintf("req_%d.go", c.n)
	doneName := fmt.Sprintf("res_%d.done", c.n)
	resName := fmt.Sprintf("res_%d.txt", c.n)
	_ = os.Remove(filepath.Join(c.dir, doneName))
	_ = os.Remove(filepath.Join(c.dir, resName))
	if err := os.WriteFile(filepath.Join(c.dir, goName), nil, 0644); err != nil {
		return nil, err
	}
	if err := waitFile(filepath.Join(c.dir, doneName), 10*time.Minute, nil); err != nil {
		return nil, fmt.Errorf("node L%d E%d req %d: %w", c.cfg.Layer, c.cfg.Expert, c.n, err)
	}
	words, err := parseHexLines(filepath.Join(c.dir, resName), c.cfg.N)
	if err != nil {
		return nil, err
	}
	c.n++
	if !c.cfg.KeepFiles {
		for _, f := range []string{xName, goName, resName, doneName} {
			_ = os.Remove(filepath.Join(c.dir, f))
		}
	}
	return words, nil
}

// ternaryCodeRow quantizes one BF16 weight row to BitNet b1.58 2-bit codes
// (1 = +1, 2 = -1, 0 = zero) with per-row absmean scaling, matching
// node_reference_test.py's quantize_ternary_real and the reference_ternary
// select-add oracle.
func ternaryCodeRow(row []uint16) []uint8 {
	var sum float64
	for _, w := range row {
		sum += math.Abs(b16Val(w))
	}
	scale := sum / float64(len(row))
	if scale == 0 {
		scale = 1
	}
	out := make([]uint8, len(row))
	for i, w := range row {
		r := math.Round(b16Val(w) / scale)
		switch {
		case r >= 1:
			out[i] = 1
		case r <= -1:
			out[i] = 2
		}
	}
	return out
}

// BuildWeightHexTernary quantizes the expert slice to BitNet b1.58 codes,
// writes wu.hex / wd.hex as 8-bit words for a CU_TYPE=8 node, and returns the
// code slices for the host twin.
func (c *nodeClient) BuildWeightHexTernary(rawGateUp, rawDown []byte) ([][]uint8, [][]uint8, error) {
	cfg := c.cfg
	gu, dw := expertB16Slice(rawGateUp, rawDown, cfg.Expert, cfg.EffFull, cfg.HiddenDim,
		cfg.GU, cfg.N, cfg.EFF)
	guC := make([][]uint8, len(gu))
	for r := range gu {
		guC[r] = ternaryCodeRow(gu[r])
	}
	dwC := make([][]uint8, len(dw))
	for r := range dw {
		dwC[r] = ternaryCodeRow(dw[r])
	}
	var wu, wd strings.Builder
	for r := 0; r < cfg.GU; r++ {
		for cc := 0; cc < cfg.N; cc++ {
			fmt.Fprintf(&wu, "%02x\n", guC[r][cc])
		}
	}
	for r := 0; r < cfg.N; r++ {
		for cc := 0; cc < cfg.EFF; cc++ {
			fmt.Fprintf(&wd, "%02x\n", dwC[r][cc])
		}
	}
	if err := os.WriteFile(filepath.Join(c.dir, "wu.hex"), []byte(wu.String()), 0644); err != nil {
		return nil, nil, err
	}
	if err := os.WriteFile(filepath.Join(c.dir, "wd.hex"), []byte(wd.String()), 0644); err != nil {
		return nil, nil, err
	}
	return guC, dwC, nil
}

// ExpertInt8 runs the CU=8 ternary node over an INT8 hidden stream.
func (c *nodeClient) ExpertInt8(hidden []uint8) ([]uint16, error) {
	var sb strings.Builder
	for cc := 0; cc < c.cfg.N; cc++ {
		v := uint8(0)
		if cc < len(hidden) {
			v = hidden[cc]
		}
		fmt.Fprintf(&sb, "%02x\n", v)
	}
	xName := fmt.Sprintf("x_%d.hex", c.n)
	if err := os.WriteFile(filepath.Join(c.dir, xName), []byte(sb.String()), 0644); err != nil {
		return nil, err
	}
	goName := fmt.Sprintf("req_%d.go", c.n)
	doneName := fmt.Sprintf("res_%d.done", c.n)
	resName := fmt.Sprintf("res_%d.txt", c.n)
	_ = os.Remove(filepath.Join(c.dir, doneName))
	_ = os.Remove(filepath.Join(c.dir, resName))
	if err := os.WriteFile(filepath.Join(c.dir, goName), nil, 0644); err != nil {
		return nil, err
	}
	if err := waitFile(filepath.Join(c.dir, doneName), 10*time.Minute, nil); err != nil {
		return nil, fmt.Errorf("node L%d E%d req %d: %w", c.cfg.Layer, c.cfg.Expert, c.n, err)
	}
	words, err := parseHexLines(filepath.Join(c.dir, resName), c.cfg.N)
	if err != nil {
		return nil, err
	}
	c.n++
	if !c.cfg.KeepFiles {
		for _, f := range []string{xName, goName, resName, doneName} {
			_ = os.Remove(filepath.Join(c.dir, f))
		}
	}
	return words, nil
}

// ternaryQuantHidden quantizes a float hidden vector per-tensor to INT8
// (symmetric, max-abs scaling), matching quantize_ternary_real.
func ternaryQuantizeHidden(hidden []float32) []uint8 {
	var mx float64
	for _, v := range hidden {
		if a := math.Abs(float64(v)); a > mx {
			mx = a
		}
	}
	if mx == 0 {
		mx = 1
	}
	out := make([]uint8, len(hidden))
	for i, v := range hidden {
		out[i] = uint8(int(math.Round(float64(v)/mx*127)) & 0xFF)
	}
	return out
}

// nodeTernaryTwin is the exact INT32 select-add oracle for the CU=8 node:
// gate -> identity activation (low byte) -> down, matching reference_ternary.
func nodeTernaryTwin(guC, dwC [][]uint8, hidden []uint8) []uint16 {
	s8 := func(b uint8) int { return int(int8(b)) }
	code := func(c uint8) int {
		switch c & 0x3 {
		case 1:
			return 1
		case 2:
			return -1
		}
		return 0
	}
	eff := len(dwC[0])
	act := make([]uint8, eff)
	for j := 0; j < eff; j++ {
		var acc int
		for cc := 0; cc < len(hidden); cc++ {
			acc += code(guC[j][cc]) * s8(hidden[cc])
		}
		act[j] = uint8(acc & 0xFF)
	}
	out := make([]uint16, len(dwC))
	for r := range dwC {
		var acc int
		for j := 0; j < eff; j++ {
			acc += code(dwC[r][j]) * s8(act[j])
		}
		out[r] = uint16(uint8(acc & 0xFF))
	}
	return out
}

// parseHexLines reads count whitespace-separated hex words from a file.
func parseHexLines(path string, count int) ([]uint16, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 1<<16), 1<<20)
	var out []uint16
	for sc.Scan() && len(out) < count {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		v, err := strconv.ParseUint(line, 16, 16)
		if err != nil {
			return nil, fmt.Errorf("bad word %q in %s: %w", line, path, err)
		}
		out = append(out, uint16(v))
	}
	if len(out) != count {
		return nil, fmt.Errorf("%s: %d words, want %d", path, len(out), count)
	}
	return out, nil
}
