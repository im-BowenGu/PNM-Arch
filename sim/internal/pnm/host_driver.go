package pnm

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

// HostDriver is the unified entry point for running any workload on the PNM
// chassis.  It replaces the fragmented cmd/pnm, cmd/pnmc, and language CLI
// toolchains with a single driver that handles scenarios, HPC workloads,
// .pnm programs, model compilation, and LLM inference — all with structured
// logging and result export.
//
// Usage pattern:
//
//	hd := pnm.NewHostDriver(pnm.HostConfig{
//	    Layers: 4, Bx: 4, By: 4,
//	    OutputDir: "results/",
//	    LogFile:   "results/run.log",
//	})
//	hd.RunScenario("sweep")
//	hd.RunWorkload("matvec", 0)
//	hd.RunProgram("examples/bias_add.pnm")
//	hd.RunModel("examples/gemma4_test_synthetic")
//	hd.RunInference("examples/gemma4_test_synthetic", "Hello, world!")
//	hd.WriteResults()

// HostConfig configures the unified host driver.
type HostConfig struct {
	Layers int // spine layers / boards
	Bx     int // X columns per board
	By     int // Y rows per board

	OutputDir string  // write results here (empty = no file output)
	LogFile   string  // write timestamped log here (empty = stdout only)
	Seed      int64   // RNG seed
	Groups    int     // parallel vvp slices (0 = auto)
	HotFrac   float64 // hotspot expert traffic share
	Flits     *int    // override flit count (nil = default)
	Replay    int     // replay count for determinism checks (1 = no replay)

	// Inference options
	MaxTokens   int     // max tokens to generate
	Temperature float32 // sampling temperature (0 = greedy)
	DataType    string  // "fp16" or "bf16"
}

// HostResult collects all output from a driver run.
type HostResult struct {
	Config     HostConfig
	Scenarios  []ScenarioResult
	Workloads  []WorkloadResult
	Programs   []ProgramResult
	Models     []ModelResult
	Inferences []InferenceResult
	Errors     []string
	StartTime  time.Time
	EndTime    time.Time
}

// WorkloadResult captures one HPC workload run.
type WorkloadResult struct {
	Name      string   `json:"name"`
	Pass      bool     `json:"pass"`
	Nodes     int      `json:"nodes"`
	Tokens    int      `json:"tokens"`
	WireBytes int      `json:"wire_bytes"`
	Errors    []string `json:"errors,omitempty"`
}

// ProgramResult captures one .pnm program run.
type ProgramResult struct {
	Path     string   `json:"path"`
	Pass     bool     `json:"pass"`
	Packets  int      `json:"packets"`
	DmaBytes int      `json:"dma_bytes"`
	Errors   []string `json:"errors,omitempty"`
}

// ModelResult captures one model compilation.
type ModelResult struct {
	Dir         string   `json:"dir"`
	Layers      int      `json:"layers"`
	Nodes       int      `json:"nodes"`
	TotalGB     float64  `json:"total_gb"`
	SchemaPath  string   `json:"schema_path,omitempty"`
	ProgramPath string   `json:"program_path,omitempty"`
	Errors      []string `json:"errors,omitempty"`
}

// RunLogger provides timestamped, optionally file-backed logging.
type RunLogger struct {
	w     io.Writer
	tags  bool // prepend timestamps
	start time.Time
}

// NewRunLogger creates a logger that writes to stdout and optionally to a file.
func NewRunLogger(logFile string) *RunLogger {
	l := &RunLogger{w: os.Stdout, tags: true, start: time.Now()}
	if logFile != "" {
		if err := os.MkdirAll(filepath.Dir(logFile), 0o755); err != nil {
			fmt.Fprintf(os.Stderr, "log dir: %v\n", err)
			return l
		}
		f, err := os.OpenFile(logFile, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
		if err != nil {
			fmt.Fprintf(os.Stderr, "log file: %v\n", err)
			return l
		}
		l.w = io.MultiWriter(os.Stdout, f)
	}
	return l
}

func (l *RunLogger) Printf(format string, args ...interface{}) {
	if l.tags {
		elapsed := time.Since(l.start).Truncate(time.Millisecond)
		fmt.Fprintf(l.w, "[%s] ", elapsed)
	}
	fmt.Fprintf(l.w, format, args...)
}

func (l *RunLogger) Println(args ...interface{}) {
	if l.tags {
		elapsed := time.Since(l.start).Truncate(time.Millisecond)
		args = append([]interface{}{fmt.Sprintf("[%s] ", elapsed)}, args...)
	}
	fmt.Fprintln(l.w, args...)
}

// NewHostDriver creates a unified host driver.
func NewHostDriver(cfg HostConfig) *HostDriver {
	if cfg.Layers == 0 {
		cfg.Layers = 3
	}
	if cfg.Bx == 0 {
		cfg.Bx = 4
	}
	if cfg.By == 0 {
		cfg.By = 4
	}
	if cfg.Seed == 0 {
		cfg.Seed = 0xC0FFEE
	}
	if cfg.Groups == 0 {
		cfg.Groups = min(cfg.Layers, runtime.NumCPU())
	}
	if cfg.MaxTokens == 0 {
		cfg.MaxTokens = 32
	}
	if cfg.DataType == "" {
		cfg.DataType = "bf16"
	}

	log := NewRunLogger(cfg.LogFile)

	return &HostDriver{
		Cfg:    cfg,
		Dims:   Dims{Layers: cfg.Layers, Bx: cfg.Bx, By: cfg.By},
		Nodes:  AllNodes(cfg.Layers, cfg.Bx, cfg.By),
		Log:    log,
		Result: &HostResult{Config: cfg, StartTime: time.Now()},
	}
}

// HostDriver orchestrates all PNM workloads.
type HostDriver struct {
	Cfg    HostConfig
	Dims   Dims
	Nodes  []NodeID
	Log    *RunLogger
	Result *HostResult
}

// RunScenario runs a fabric verification scenario (sweep, vcsweep, load, hotspot, stress, replay).
func (hd *HostDriver) RunScenario(name string) bool {
	hd.Log.Printf("scenario %q: %dx%dx%d = %d nodes, seed=%d\n",
		name, hd.Cfg.Layers, hd.Cfg.Bx, hd.Cfg.By, len(hd.Nodes), hd.Cfg.Seed)

	var prog *Program
	switch name {
	case "sweep":
		prog = ScenarioSweep(hd.Cfg.Layers, hd.Cfg.Bx, hd.Cfg.By, hd.Cfg.Seed)
	case "vcsweep":
		prog = ScenarioVCSweep(hd.Cfg.Layers, hd.Cfg.Bx, hd.Cfg.By, hd.Cfg.Seed)
	case "load":
		f := 500
		if hd.Cfg.Flits != nil && *hd.Cfg.Flits != 0 {
			f = *hd.Cfg.Flits
		}
		prog = ScenarioLoad(hd.Cfg.Layers, hd.Cfg.Bx, hd.Cfg.By, hd.Cfg.Seed, f)
	case "hotspot":
		f := 400
		if hd.Cfg.Flits != nil && *hd.Cfg.Flits != 0 {
			f = *hd.Cfg.Flits
		}
		prog = ScenarioHotspot(hd.Cfg.Layers, hd.Cfg.Bx, hd.Cfg.By, hd.Cfg.Seed, f, hd.Cfg.HotFrac)
	case "stress":
		var f int
		if hd.Cfg.Flits != nil {
			f = *hd.Cfg.Flits
		}
		prog = ScenarioStress(hd.Cfg.Layers, hd.Cfg.Bx, hd.Cfg.By, hd.Cfg.Seed, f)
	case "replay":
		f := 300
		if hd.Cfg.Flits != nil && *hd.Cfg.Flits != 0 {
			f = *hd.Cfg.Flits
		}
		prog = ScenarioStress(hd.Cfg.Layers, hd.Cfg.Bx, hd.Cfg.By, hd.Cfg.Seed, f)
	default:
		hd.Log.Printf("unknown scenario: %s\n", name)
		hd.Result.Errors = append(hd.Result.Errors, fmt.Sprintf("unknown scenario: %s", name))
		return false
	}

	sr, ok := RunOne(prog, hd.Nodes, hd.Dims, hd.Cfg.Groups, hd.Cfg.Replay)
	if sr != nil {
		sr.Name = name
		hd.Result.Scenarios = append(hd.Result.Scenarios, *sr)
	}
	if !ok {
		hd.Result.Errors = append(hd.Result.Errors, fmt.Sprintf("scenario %s failed", name))
	}
	return ok
}

// RunScenarios runs multiple scenarios sequentially.
func (hd *HostDriver) RunScenarios(names ...string) bool {
	allPass := true
	for _, name := range names {
		hd.Log.Printf("--- scenario '%s' ---\n", name)
		if !hd.RunScenario(name) {
			allPass = false
		}
	}
	return allPass
}

// RunWorkload runs an HPC workload (jacobi5, matvec, reduction, broadcast, nbody).
func (hd *HostDriver) RunWorkload(name string, frag int) bool {
	registry := Workloads()
	reg, ok := registry[name]
	if !ok {
		hd.Log.Printf("unknown workload: %s\n", name)
		hd.Result.Errors = append(hd.Result.Errors, fmt.Sprintf("unknown workload: %s", name))
		return false
	}
	if frag == 0 {
		frag = reg.Frag
	}

	hd.Log.Printf("workload %q: generating program\n", name)
	wl, err := reg.Gen(hd.Cfg.Layers, hd.Cfg.Bx, hd.Cfg.By, frag)
	if err != nil {
		hd.Log.Printf("workload %s: %v\n", name, err)
		hd.Result.Errors = append(hd.Result.Errors, fmt.Sprintf("workload %s: %v", name, err))
		return false
	}

	hd.Log.Printf("  %s (%d nodes, %d tokens, routing: %s)\n",
		wl.Desc, wl.Nodes, wl.Tokens, wl.Routing)

	// Compile program text
	kernels, kernOrder, biases, _, tokens, err := CompileProgram(wl.Program, hd.Dims)
	if err != nil {
		hd.Log.Printf("compile workload: %v\n", err)
		hd.Result.Errors = append(hd.Result.Errors, fmt.Sprintf("compile workload: %v", err))
		return false
	}

	// Fill in echo for unprogrammed token sinks
	for _, t := range tokens {
		if _, ok := kernels[t.Node]; !ok {
			kernels[t.Node] = KernelDef{Name: "echo", Weights: []int{}}
			kernOrder = append(kernOrder, t.Node)
		}
	}

	prog := NewProgram(name, hd.Nodes, "bounded")
	for _, n := range hd.Nodes {
		prog.BP[n] = 1
	}
	for _, n := range kernOrder {
		kd := kernels[n]
		prog.ProgramNode(n, kd.Name, kd.Weights, biases[n])
	}
	for i, t := range tokens {
		prog.InjectRouted(t.Node, CTRL_COMPUTE_SPINE|((i&0x0F)&^1), t.Payload, false)
	}

	hd.Log.Printf("  %d kernels, %d tokens, %d wire bytes\n", len(kernels), len(tokens), len(prog.Stream))

	_, ok = RunOne(prog, hd.Nodes, hd.Dims, hd.Cfg.Groups, 1)
	wr := WorkloadResult{
		Name:      name,
		Pass:      ok,
		Nodes:     wl.Nodes,
		Tokens:    wl.Tokens,
		WireBytes: len(prog.Stream),
	}
	hd.Result.Workloads = append(hd.Result.Workloads, wr)

	if !ok {
		hd.Result.Errors = append(hd.Result.Errors, fmt.Sprintf("workload %s failed", name))
	}
	return ok
}

// RunProgram compiles and runs a .pnm program file.
func (hd *HostDriver) RunProgram(path string) bool {
	hd.Log.Printf("program: compiling %s\n", path)

	data, err := os.ReadFile(path)
	if err != nil {
		hd.Log.Printf("read program: %v\n", err)
		hd.Result.Errors = append(hd.Result.Errors, fmt.Sprintf("read program: %v", err))
		return false
	}

	pr := ProgramResult{Path: path}
	kernels, kernOrder, biases, _, tokens, err := CompileProgram(string(data), hd.Dims)
	if err != nil {
		hd.Log.Printf("compile program: %v\n", err)
		pr.Errors = append(pr.Errors, fmt.Sprintf("compile: %v", err))
		hd.Result.Programs = append(hd.Result.Programs, pr)
		hd.Result.Errors = append(hd.Result.Errors, fmt.Sprintf("program %s: compile failed", path))
		return false
	}

	// Fill in echo for unprogrammed token sinks
	for _, t := range tokens {
		if _, ok := kernels[t.Node]; !ok {
			kernels[t.Node] = KernelDef{Name: "echo", Weights: []int{}}
			kernOrder = append(kernOrder, t.Node)
		}
	}

	prog := NewProgram(path, hd.Nodes, "bounded")
	for _, n := range hd.Nodes {
		prog.BP[n] = 1
	}
	for _, n := range kernOrder {
		kd := kernels[n]
		prog.ProgramNode(n, kd.Name, kd.Weights, biases[n])
	}
	for i, t := range tokens {
		prog.InjectRouted(t.Node, CTRL_COMPUTE_SPINE|((i&0x0F)&^1), t.Payload, false)
	}

	hd.Log.Printf("  %d kernels, %d tokens, %d wire bytes\n", len(kernels), len(tokens), len(prog.Stream))

	_, ok := RunOne(prog, hd.Nodes, hd.Dims, hd.Cfg.Groups, 1)
	pr.Pass = ok
	hd.Result.Programs = append(hd.Result.Programs, pr)

	if !ok {
		hd.Result.Errors = append(hd.Result.Errors, fmt.Sprintf("program %s failed", path))
	}
	return ok
}

// RunModel compiles a HuggingFace model directory onto the chassis.
func (hd *HostDriver) RunModel(modelDir string) bool {
	hd.Log.Printf("model: compiling %s onto %dx%dx%d chassis\n",
		modelDir, hd.Cfg.Layers, hd.Cfg.Bx, hd.Cfg.By)

	drv, err := NewDriver(DriverConfig{ModelDir: modelDir, Dims: hd.Dims})
	if err != nil {
		hd.Log.Printf("driver init: %v\n", err)
		mr := ModelResult{Dir: modelDir, Errors: []string{err.Error()}}
		hd.Result.Models = append(hd.Result.Models, mr)
		hd.Result.Errors = append(hd.Result.Errors, fmt.Sprintf("model %s: %v", modelDir, err))
		return false
	}

	tc := &drv.Config.TextConfig
	mr := ModelResult{
		Dir:     modelDir,
		Layers:  tc.NumHiddenLayers,
		Nodes:   hd.Cfg.Layers * hd.Cfg.Bx * hd.Cfg.By,
		TotalGB: float64(drv.MC.TotalBytes) / 1e9,
	}

	hd.Log.Printf("  %d layers, hidden=%d, experts=%d, vocab=%d\n",
		tc.NumHiddenLayers, tc.HiddenSize, tc.NumExperts, tc.VocabSize)
	hd.Log.Printf("  total weights: %.1f GB, per-node budget: %.1f GB\n",
		float64(drv.MC.TotalBytes)/1e9, float64(drv.MC.PerNodeBudget)/1e9)

	// Write output files
	if hd.Cfg.OutputDir != "" {
		os.MkdirAll(hd.Cfg.OutputDir, 0o755)

		rtPath := filepath.Join(hd.Cfg.OutputDir, "routing_table.json")
		if err := drv.WriteRoutingTable(rtPath); err != nil {
			hd.Log.Printf("  write routing table: %v\n", err)
		} else {
			hd.Log.Printf("  wrote: %s\n", rtPath)
		}

		moePath := filepath.Join(hd.Cfg.OutputDir, "moe_map.json")
		if err := drv.WriteMoeMap(moePath); err != nil {
			hd.Log.Printf("  write MoE map: %v\n", err)
		} else {
			hd.Log.Printf("  wrote: %s\n", moePath)
		}

		schemaPath := filepath.Join(hd.Cfg.OutputDir, "model_schema.txt")
		if err := os.WriteFile(schemaPath, []byte(drv.MC.EmitSchema()), 0o644); err != nil {
			hd.Log.Printf("  write schema: %v\n", err)
		} else {
			hd.Log.Printf("  wrote: %s\n", schemaPath)
			mr.SchemaPath = schemaPath
		}

		progPath := filepath.Join(hd.Cfg.OutputDir, "model.pnm")
		if err := os.WriteFile(progPath, []byte(drv.MC.EmitProgram()), 0o644); err != nil {
			hd.Log.Printf("  write program: %v\n", err)
		} else {
			hd.Log.Printf("  wrote: %s\n", progPath)
			mr.ProgramPath = progPath
		}
	}

	// Run boot sequence
	fw := drv.FW
	hd.Log.Printf("--- boot sequence ---\n")

	for phase := 0; phase < 5; phase++ {
		cmds, err := fw.BootPhase()
		if err != nil {
			hd.Log.Printf("  boot phase %d: %v\n", phase+1, err)
			mr.Errors = append(mr.Errors, fmt.Sprintf("boot phase %d: %v", phase+1, err))
			hd.Result.Models = append(hd.Result.Models, mr)
			hd.Result.Errors = append(hd.Result.Errors, fmt.Sprintf("model %s boot failed", modelDir))
			return false
		}
		switch phase {
		case 0:
			hd.Log.Printf("  phase 1 POST discovery: %d nodes\n", fw.NodeCount)
		case 1:
			hd.Log.Printf("  phase 2 routing table: %d entries\n", len(drv.RouteBitmaps))
		case 2:
			if err := fw.VerifyWeightUpload(cmds); err != nil {
				hd.Log.Printf("  weight verification: %v\n", err)
				mr.Errors = append(mr.Errors, fmt.Sprintf("weight verify: %v", err))
			} else {
				hd.Log.Printf("  phase 3 weight upload: PASSED (%d commands)\n", len(cmds))
			}
		case 3:
			hd.Log.Printf("  phase 4 MoE gating: %d expert mappings\n", len(drv.MoeMap))
		case 4:
			hd.Log.Printf("  phase 5 READY\n")
		}
	}

	return hd.finishModel(modelDir, &mr)
}

// finishModel records the final verdict for a model compilation and returns
// whether it succeeded. A model whose boot loop or weight verification
// recorded any error must not be reported as OK.
func (hd *HostDriver) finishModel(modelDir string, mr *ModelResult) bool {
	hd.Result.Models = append(hd.Result.Models, *mr)
	if len(mr.Errors) > 0 {
		hd.Log.Printf("model %s: FAILED (%d errors)\n", modelDir, len(mr.Errors))
		hd.Result.Errors = append(hd.Result.Errors, fmt.Sprintf("model %s: boot/verification failed", modelDir))
		return false
	}
	hd.Log.Printf("model %s: OK\n", modelDir)
	return true
}

// datatypeFromString maps the HostConfig.DataType string ("fp16"/"bf16")
// to the ComputeUnitType used by the LLM client. RunInference previously
// hardcoded CUTypeBF16FMA, silently ignoring the documented config field.
func datatypeFromString(s string) ComputeUnitType {
	switch strings.ToLower(s) {
	case "fp16":
		return CUTypeFP16FMA
	default:
		return CUTypeBF16FMA
	}
}

// RunInference runs LLM inference on the compiled model.
func (hd *HostDriver) RunInference(modelDir, prompt string) bool {
	hd.Log.Printf("inference: model=%s, prompt=%q\n", modelDir, prompt)

	drv, err := NewDriver(DriverConfig{ModelDir: modelDir, Dims: hd.Dims})
	if err != nil {
		hd.Log.Printf("driver init: %v\n", err)
		hd.Result.Errors = append(hd.Result.Errors, fmt.Sprintf("inference driver: %v", err))
		return false
	}

	// Real-weight forward pass: Gemma-4 numeric math over actual BF16
	// weights + the real tokenizer.  Falls back to dispatch simulation
	// when the checkpoint shards are absent.
	if len(drv.TensorData) > 0 {
		vocab, verr := LoadBPEVocab(filepath.Join(modelDir, "tokenizer.json"))
		if verr == nil {
			text, tids, rerr := RealGenerate(modelDir, hd.Dims, prompt, hd.Cfg.MaxTokens, vocab)
			if rerr == nil {
				hd.Log.Printf("real-weights forward: %q (engine: gemma4-bf16)\n", text)
				hd.Result.Inferences = append(hd.Result.Inferences, InferenceResult{
					Tokens: TokenResult{Prompt: prompt, Tokens: tids, Text: text, GenLen: len(tids)},
					Stats:  map[string]int{"engine": 1},
				})
				return true
			}
			hd.Log.Printf("real inference error (falling back): %v\n", rerr)
		} else {
			hd.Log.Printf("real tokenizer error (falling back): %v\n", verr)
		}
	}
	llmCfg := LLMConfig{
		Dims:        hd.Dims,
		MaxTokens:   hd.Cfg.MaxTokens,
		Temperature: hd.Cfg.Temperature,
		DataType:    datatypeFromString(hd.Cfg.DataType),
	}

	client, err := NewLLMClient(llmCfg)
	if err != nil {
		hd.Log.Printf("LLM client: %v\n", err)
		hd.Result.Errors = append(hd.Result.Errors, fmt.Sprintf("LLM client: %v", err))
		return false
	}

	// Boot firmware
	fw := drv.FW
	for phase := 0; phase < 5; phase++ {
		if _, err := fw.BootPhase(); err != nil {
			hd.Log.Printf("boot phase %d: %v\n", phase+1, err)
			hd.Result.Errors = append(hd.Result.Errors, fmt.Sprintf("inference boot: %v", err))
			return false
		}
	}
	hd.Log.Printf("firmware: READY\n")

	// Generate
	tokens, err := client.Generate(prompt)
	if err != nil {
		hd.Log.Printf("generate: %v\n", err)
		hd.Result.Errors = append(hd.Result.Errors, fmt.Sprintf("generate: %v", err))
		return false
	}

	text := client.Vocab.Decode(tokens)
	hd.Log.Printf("generated %d tokens: %s\n", len(tokens), text)

	ir := InferenceResult{
		Tokens: TokenResult{
			Prompt:    prompt,
			Tokens:    tokens,
			Text:      text,
			PromptLen: len(client.Vocab.Encode(prompt)),
			GenLen:    len(tokens),
		},
		Stats: InferenceStatsToMap(&client.Stats),
	}
	hd.Result.Inferences = append(hd.Result.Inferences, ir)

	if hd.Cfg.OutputDir != "" {
		os.MkdirAll(hd.Cfg.OutputDir, 0o755)
		tokenPath := filepath.Join(hd.Cfg.OutputDir, "tokens.txt")
		if err := client.WriteTokens(tokenPath, prompt, tokens); err != nil {
			hd.Log.Printf("write tokens: %v\n", err)
		} else {
			hd.Log.Printf("wrote: %s\n", tokenPath)
		}
	}

	return true
}

func (hd *HostDriver) Summary() string {
	var b strings.Builder
	fmt.Fprintf(&b, "PNM host driver\n")
	fmt.Fprintf(&b, "  chassis: %dx%dx%d = %d nodes\n", hd.Dims.Layers, hd.Dims.Bx, hd.Dims.By, len(hd.Nodes))
	if hd.Cfg.OutputDir != "" {
		fmt.Fprintf(&b, "  output: %s\n", hd.Cfg.OutputDir)
	}
	e := len(hd.Result.Errors)
	i := len(hd.Result.Inferences)
	fmt.Fprintf(&b, "  scenarios: %d  workloads: %d  models: %d  inferences: %d  errors: %d\n",
		len(hd.Result.Scenarios), len(hd.Result.Workloads), len(hd.Result.Models), i, e)
	if e == 0 {
		fmt.Fprintf(&b, "  result: ALL PASSED\n")
	} else {
		fmt.Fprintf(&b, "  result: %d FAILURES\n", e)
	}
	return b.String()
}

func (hd *HostDriver) WriteResults() {
	hd.Result.EndTime = time.Now()
	if hd.Cfg.OutputDir == "" {
		return
	}
	os.MkdirAll(hd.Cfg.OutputDir, 0o755)
	p := filepath.Join(hd.Cfg.OutputDir, "result.json")
	data, _ := json.MarshalIndent(hd.Result, "", "  ")
	if err := os.WriteFile(p, data, 0o644); err != nil {
		hd.Log.Printf("write results: %v\n", err)
	}
	hd.Log.Printf("wrote: %s\n", p)
}
