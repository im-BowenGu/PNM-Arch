package pnm

// gating_harness.go — Gating-ASIC harness support.
//
// pnmgate boots one persistent vvp "server" process per gated layer.  Each
// server runs HDL/core/tb_gating_server.v (gating_asic.v + moe_gating.v +
// bf16_fma.v/fma_core.v):
//
//   1. "load gating network into ram": the real router.proj.weight rows of the
//      layer are streamed over the ASIC register bus into moe_gating's on-chip
//      weight SRAM (bus auto-increment; see gating_asic.v REG_WGHT_*).
//   2. per request the harness writes the BF16 router input to h_<n>.hex and
//      drops req_<n>.go; the server loads it into the hidden SRAM, runs the
//      gating FSM, and writes res_<n>.txt (top-k ids + all NUM_EXPERTS logits)
//      plus res_<n>.done.
//   3. the logits are fed back into the software engine (softmax -> top-k ->
//      normalized expert weights -> MoE), i.e. the rest of the layer/inference
//      runs on the CPU with the ASIC's routing decision.

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// GatingConfig configures the hardware-gating harness.
type GatingConfig struct {
	RunDir      string // scratch directory for weight/hidden/result files
	Layers      []int  // transformer layers routed by the ASIC
	Width       int    // projection width (0 = full hidden size)
	PrefillLast bool   // gate only the final prefill position (speed)
	Think       bool   // enable the reasoning datapath (prefill <|channel>thought)
	Verbose     bool
	KeepFiles   bool
	// OnRoute, if set, is called after each ASIC routing decision.
	OnRoute func(layer int, topk []int)
}

// gatingClient implements routerGate on top of per-layer vvp servers.
type gatingClient struct {
	cfg       GatingConfig
	hidden    int
	exps      int
	topk      int
	width     int
	hdlDir    string
	serverBin string
	procs     map[int]*asicProc
	// routed records the ASIC's top-k decision for each gated layer (last request).
	routed map[int][]int
}

type asicProc struct {
	layer int
	dir   string
	cmd   *exec.Cmd
	log   *os.File
	n     int
	done  chan struct{}
}

func (c *gatingClient) Has(layer int) bool {
	_, ok := c.procs[layer]
	return ok
}

// findHDLDir locates HDL/core (env PNM_HDL_DIR, else search upward from cwd).
func findHDLDir() (string, error) {
	if d := os.Getenv("PNM_HDL_DIR"); d != "" {
		return d, nil
	}
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		cand := filepath.Join(dir, "HDL", "core", "tb_gating_server.v")
		if _, err := os.Stat(cand); err == nil {
			return filepath.Join(dir, "HDL", "core"), nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return "", fmt.Errorf("HDL/ not found; run from the PNM-Arch-Paper tree or set PNM_HDL_DIR")
}

// newGatingClient boots a hardware gating server for every requested layer.
func newGatingClient(cfg GatingConfig, g *gemmaModel) (*gatingClient, error) {
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
	if err := os.MkdirAll(cfg.RunDir, 0755); err != nil {
		return nil, err
	}
	hidden := g.cfg.TextConfig.HiddenSize
	exps := g.cfg.TextConfig.NumExperts
	topk := g.cfg.TextConfig.TopKExperts
	width := cfg.Width
	if width <= 0 || width > hidden {
		width = hidden
	}
	ab := 12
	if bl := bitsFor(exps*width - 1); bl > ab {
		ab = bl
	}
	c := &gatingClient{
		cfg: cfg, hidden: hidden, exps: exps, topk: topk, width: width,
		hdlDir: hdl, procs: map[int]*asicProc{}, routed: map[int][]int{},
	}

	// Compile the persistent server once (same parameters for every layer).
	c.serverBin = filepath.Join(cfg.RunDir, "gating_server.vvp")
	iverilog := []string{
		"-g2005", "-s", "tb_gating_server", "-o", c.serverBin,
		filepath.Join(hdl, "tb_gating_server.v"),
		filepath.Join(hdl, "gating_asic.v"),
		filepath.Join(hdl, "moe_gating.v"),
		filepath.Join(hdl, "arith_unit.v"),
		filepath.Join(hdl, "bf16_fma.v"),
		filepath.Join(hdl, "fma_core.v"),
		"-P", fmt.Sprintf("tb_gating_server.NUM_EXPERTS=%d", exps),
		"-P", fmt.Sprintf("tb_gating_server.HIDDEN_DIM=%d", width),
		"-P", fmt.Sprintf("tb_gating_server.TOP_K=%d", topk),
		"-P", fmt.Sprintf("tb_gating_server.ADDR_BITS=%d", ab),
		"-P", "tb_gating_server.MAXREQ=0",
	}
	if out, err := exec.Command("iverilog", iverilog...).CombinedOutput(); err != nil {
		return nil, fmt.Errorf("iverilog failed: %v\n%s", err, out)
	}

	// Boot one server per gated layer.
	for _, l := range cfg.Layers {
		p, err := c.bootLayer(g, l)
		if err != nil {
			c.Close()
			return nil, err
		}
		c.procs[l] = p
	}
	if cfg.Verbose {
		fmt.Fprintf(os.Stderr, "[gating] ASIC ready: layers=%v exps=%d width=%d topk=%d\n",
			cfg.Layers, exps, width, topk)
	}
	return c, nil
}

func bitsFor(n int) int {
	b := 0
	for n > 0 {
		b++
		n >>= 1
	}
	return b
}

func (c *gatingClient) bootLayer(g *gemmaModel, layer int) (*asicProc, error) {
	dir := filepath.Join(c.cfg.RunDir, fmt.Sprintf("L%d", layer))
	if err := os.MkdirAll(dir, 0755); err != nil {
		return nil, err
	}
	// Clear stale request/response markers from a previous run so the server
	// starts at request 0 with nothing queued (otherwise it replays old
	// req_<n>.go files and never answers our request).
	for _, pat := range []string{"req_*.go", "res_*.done", "res_*.txt"} {
		if old, _ := filepath.Glob(filepath.Join(dir, pat)); old != nil {
			for _, f := range old {
				_ = os.Remove(f)
			}
		}
	}
	// "load gating network into ram": real router.proj.weight rows.
	name := fmt.Sprintf("model.language_model.layers.%d.router.proj.weight", layer)
	raw := g.m.tensorBytes(name)
	if raw == nil {
		return nil, fmt.Errorf("gating: router weight %s not found", name)
	}
	var sb strings.Builder
	for e := 0; e < c.exps; e++ {
		base := e * c.hidden * 2
		for cc := 0; cc < c.width; cc++ {
			off := base + cc*2
			if off+2 > len(raw) {
				return nil, fmt.Errorf("gating: router weight too short at e=%d c=%d", e, cc)
			}
			fmt.Fprintf(&sb, "%04x\n", binary.LittleEndian.Uint16(raw[off:]))
		}
	}
	if err := os.WriteFile(filepath.Join(dir, "w_0.hex"), []byte(sb.String()), 0644); err != nil {
		return nil, err
	}
	if err := os.WriteFile(filepath.Join(dir, "layer.hex"), []byte(fmt.Sprintf("%02x\n", layer)), 0644); err != nil {
		return nil, err
	}
	_ = os.Remove(filepath.Join(dir, "status.txt"))

	logf, err := os.Create(filepath.Join(dir, "server.log"))
	if err != nil {
		return nil, err
	}
	cmd := exec.Command("vvp", c.serverBin)
	cmd.Dir = dir
	cmd.Stdout = logf
	cmd.Stderr = logf
	if err := cmd.Start(); err != nil {
		logf.Close()
		return nil, err
	}
	p := &asicProc{layer: layer, dir: dir, cmd: cmd, log: logf, done: make(chan struct{})}
	go func() {
		cmd.Wait()
		close(p.done)
	}()

	if err := waitFile(filepath.Join(dir, "status.txt"), 10*time.Minute, p.done); err != nil {
		return nil, fmt.Errorf("gating layer %d boot: %w", layer, err)
	}
	if c.cfg.Verbose {
		fmt.Fprintf(os.Stderr, "[gating] layer %d booted (weight words=%d)\n", layer, c.exps*c.width)
	}
	return p, nil
}

func waitFile(path string, timeout time.Duration, done <-chan struct{}) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); err == nil {
			return nil
		}
		if done != nil {
			select {
			case <-done:
				return fmt.Errorf("server exited before %s", filepath.Base(path))
			default:
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	return fmt.Errorf("timeout waiting for %s", filepath.Base(path))
}

// Route sends one router input to the layer's ASIC and returns its logits.
func (c *gatingClient) Route(layer int, ri []float32) ([]float32, error) {
	p, ok := c.procs[layer]
	if !ok {
		return nil, fmt.Errorf("gating: layer %d has no ASIC server", layer)
	}
	// BF16-quantize the (already per-dim cast) router input for the ASIC.
	var sb strings.Builder
	for cc := 0; cc < c.width; cc++ {
		v := float32(0)
		if cc < len(ri) {
			v = ri[cc]
		}
		w := uint16(math.Float32bits(roundBF16(v)) >> 16)
		fmt.Fprintf(&sb, "%04x\n", w)
	}
	hName := fmt.Sprintf("h_%d.hex", p.n)
	// unique request markers per layer directory
	if err := os.WriteFile(filepath.Join(p.dir, hName), []byte(sb.String()), 0644); err != nil {
		return nil, err
	}
	goName := fmt.Sprintf("req_%d.go", p.n)
	doneName := fmt.Sprintf("res_%d.done", p.n)
	resName := fmt.Sprintf("res_%d.txt", p.n)
	_ = os.Remove(filepath.Join(p.dir, doneName))
	_ = os.Remove(filepath.Join(p.dir, resName))
	if err := os.WriteFile(filepath.Join(p.dir, goName), nil, 0644); err != nil {
		return nil, err
	}

	// time budget scales with the number of MAC cycles the ASIC must run
	timeout := time.Duration(120+float64(c.width)*0.5) * time.Second
	if err := waitFile(filepath.Join(p.dir, doneName), timeout, nil); err != nil {
		return nil, fmt.Errorf("gating layer %d request %d: %w", layer, p.n, err)
	}
	logits, ids, err := parseGateResult(filepath.Join(p.dir, resName), c.exps)
	if err != nil {
		return nil, err
	}
	c.routed[layer] = ids
	p.n++

	if c.cfg.OnRoute != nil && len(ids) > 0 {
		c.cfg.OnRoute(layer, ids)
	}

	if !c.cfg.KeepFiles {
		os.Remove(filepath.Join(p.dir, hName))
		os.Remove(filepath.Join(p.dir, goName))
		os.Remove(filepath.Join(p.dir, resName))
		os.Remove(filepath.Join(p.dir, doneName))
	}
	if c.cfg.Verbose {
		fmt.Fprintf(os.Stderr, "[gating] L%d req %d -> topk %v\n", layer, p.n-1, ids)
	}
	return logits, nil
}

func parseGateResult(path string, exps int) ([]float32, []int, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, nil, err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 1<<20), 1<<24)
	if !sc.Scan() {
		return nil, nil, fmt.Errorf("empty result %s", path)
	}
	fields := strings.Fields(sc.Text())
	var ids []int
	if len(fields) > 0 && fields[0] == "idx" {
		for _, x := range fields[1:] {
			v, _ := strconv.Atoi(x)
			ids = append(ids, v)
		}
	}
	if !sc.Scan() {
		return nil, nil, fmt.Errorf("no logits line in %s", path)
	}
	ws := strings.Fields(sc.Text())
	logits := make([]float32, 0, exps)
	for _, h := range ws {
		u, err := strconv.ParseUint(h, 16, 16)
		if err != nil {
			continue
		}
		logits = append(logits, bf16ToF32(uint16(u)))
	}
	if len(logits) != exps {
		return nil, nil, fmt.Errorf("expected %d logits, got %d", exps, len(logits))
	}
	return logits, ids, nil
}

// TopK returns the last ASIC routing decision for a layer.
func (c *gatingClient) TopK(layer int) []int { return c.routed[layer] }

func (c *gatingClient) Close() {
	for _, p := range c.procs {
		if p.cmd != nil && p.cmd.Process != nil {
			_ = p.cmd.Process.Kill()
		}
		if p.log != nil {
			p.log.Close()
		}
	}
}

// RealGatedGenerate runs the real Gemma-4 weights with the hardware Gating ASIC
// supplying router logits for cfg.Layers; every other op stays on the CPU.
func RealGatedGenerate(modelDir string, dims Dims, prompt string, maxTokens int, vocab *BPEVocab, temp float32, cfg GatingConfig) (string, []int, error) {
	answer, _, tokens, err := realGatedCore(modelDir, dims, prompt, maxTokens, vocab, temp, cfg)
	return answer, tokens, err
}

// RealGatedThinking is RealGatedGenerate returning the reasoning trace (the
// model's "<|channel>thought ... <channel|>" block) separately from the final
// answer. Set cfg.Think to pre-fill the channel opener (only needed for a model
// that does not open it itself).
func RealGatedThinking(modelDir string, dims Dims, prompt string, maxTokens int, vocab *BPEVocab, temp float32, cfg GatingConfig) (answer, reasoning string, tokens []int, err error) {
	return realGatedCore(modelDir, dims, prompt, maxTokens, vocab, temp, cfg)
}

func realGatedCore(modelDir string, dims Dims, prompt string, maxTokens int, vocab *BPEVocab, temp float32, cfg GatingConfig) (answer, reasoning string, tokens []int, err error) {
	if vocab == nil {
		return "", "", nil, fmt.Errorf("real gated generate: nil vocab")
	}
	g, err := loadRealGemmaModel(modelDir, vocab)
	if err != nil {
		return "", "", nil, err
	}
	gc, err := newGatingClient(cfg, g)
	if err != nil {
		return "", "", nil, err
	}
	defer gc.Close()

	ids, err := chatIDs(vocab, prompt, cfg.Think)
	if err != nil {
		return "", "", nil, err
	}
	full := append([]int{g.vocab.BosID}, ids...)
	return realGenerateCore(g, full, maxTokens, temp, gc, cfg.PrefillLast, cfg.Think)
}
