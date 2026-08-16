package pnm

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
)

// pnmc — a tiny AOT compiler + simulator driver for PNM programs, ported
// from sim/pnmc.py.
//
// Lowers a plain-text program onto the chassis (Paper.MD §2.7–2.8), emits the
// stimulus and the golden model, compiles the Verilog slices (parallel iverilog),
// simulates them in parallel vvp processes, and verifies the hardware-delivered
// results against the golden model.
//
// Program format (one directive per line, '#' comments):
//
//	kernel <sum|echo|accum|dot> <l> <x> <y> [<hex weights...>]
//	bias   <k> <l> <x> <y>
//	token  <l> <x> <y> <hex bytes...>
//
// Semantics: 'bias K' is compiled into the node's MAC stub (pe_tile_stub
// KERNEL_CONST); every token payload arrives at the doorbell with +K already
// applied in silicon, and the resident kernel runs on the transformed payload.
// The golden model applies the same transform, so a PASS proves the gates AND
// the stub's arithmetic.

// KernelDef is one compiled kernel directive: (node -> kernel name, weights).
type KernelDef struct {
	Name    string
	Weights []int
}

// Token is one compiled token directive: (node, payload bytes).
type Token struct {
	Node    NodeID
	Payload []byte
}

func inChassis(n NodeID, dims Dims) bool {
	return 0 <= n.L && n.L < dims.Layers && 0 <= n.X && n.X < dims.Bx && 0 <= n.Y && n.Y < dims.By
}

// CompileProgram parses the program text into (kernels, biases, tokens).
// kernOrder/biasOrder preserve file insertion order so printed listings and
// error reports match the Python dict iteration.
func CompileProgram(text string, dims Dims) (kernels map[NodeID]KernelDef, kernOrder []NodeID, biases map[NodeID]int, biasOrder []NodeID, tokens []Token, err error) {
	kernels = map[NodeID]KernelDef{}
	biases = map[NodeID]int{}
	known := map[string]bool{}
	for _, k := range KERNEL_MIX {
		known[k] = true
	}
	checkAll := func(ln int) error {
		for _, n := range kernOrder {
			if !inChassis(n, dims) {
				return fmt.Errorf("%d: node %s out of chassis %s", ln, n, dims)
			}
		}
		for _, n := range biasOrder {
			if !inChassis(n, dims) {
				return fmt.Errorf("%d: node %s out of chassis %s", ln, n, dims)
			}
		}
		for _, t := range tokens {
			if !inChassis(t.Node, dims) {
				return fmt.Errorf("%d: node %s out of chassis %s", ln, t.Node, dims)
			}
		}
		return nil
	}
	fail := func(msg string) error { return fmt.Errorf("%s", msg) }

	for ln, raw := range strings.Split(text, "\n") {
		ln++ // 1-based
		line := raw
		if i := strings.IndexByte(line, '#'); i >= 0 {
			line = line[:i]
		}
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		p := strings.Fields(line)
		cmd, args := p[0], p[1:]
		switch cmd {
		case "kernel":
			if len(args) < 4 {
				return nil, nil, nil, nil, nil, fail(fmt.Sprintf("%d: malformed line: %s", ln, raw))
			}
			name := args[0]
			l, e1 := strconv.Atoi(args[1])
			x, e2 := strconv.Atoi(args[2])
			y, e3 := strconv.Atoi(args[3])
			if e1 != nil || e2 != nil || e3 != nil {
				return nil, nil, nil, nil, nil, fail(fmt.Sprintf("%d: malformed line: %s", ln, raw))
			}
			var w []int
			for _, t := range args[4:] {
				v, e := parseHexByte(t)
				if e != nil {
					return nil, nil, nil, nil, nil, fail(fmt.Sprintf("%d: malformed line: %s", ln, raw))
				}
				w = append(w, v)
			}
			if !known[name] {
				return nil, nil, nil, nil, nil, fail(fmt.Sprintf("%d: unknown kernel '%s'", ln, name))
			}
			n := NodeID{L: l, X: x, Y: y}
			if _, exists := kernels[n]; !exists {
				kernOrder = append(kernOrder, n)
			}
			kernels[n] = KernelDef{Name: name, Weights: w}
		case "bias":
			if len(args) < 4 {
				return nil, nil, nil, nil, nil, fail(fmt.Sprintf("%d: malformed line: %s", ln, raw))
			}
			k, e1 := strconv.Atoi(args[0])
			l, e2 := strconv.Atoi(args[1])
			x, e3 := strconv.Atoi(args[2])
			y, e4 := strconv.Atoi(args[3])
			if e1 != nil || e2 != nil || e3 != nil || e4 != nil {
				return nil, nil, nil, nil, nil, fail(fmt.Sprintf("%d: malformed line: %s", ln, raw))
			}
			n := NodeID{L: l, X: x, Y: y}
			if _, exists := biases[n]; !exists {
				biasOrder = append(biasOrder, n)
			}
			biases[n] = k
		case "token":
			if len(args) < 3 {
				return nil, nil, nil, nil, nil, fail(fmt.Sprintf("%d: malformed line: %s", ln, raw))
			}
			l, e1 := strconv.Atoi(args[0])
			x, e2 := strconv.Atoi(args[1])
			y, e3 := strconv.Atoi(args[2])
			if e1 != nil || e2 != nil || e3 != nil {
				return nil, nil, nil, nil, nil, fail(fmt.Sprintf("%d: malformed line: %s", ln, raw))
			}
			payload := make([]byte, 0, len(args)-3)
			for _, t := range args[3:] {
				v, e := parseHexByte(t)
				if e != nil {
					return nil, nil, nil, nil, nil, fail(fmt.Sprintf("%d: malformed line: %s", ln, raw))
				}
				payload = append(payload, byte(v))
			}
			if len(payload) == 0 {
				return nil, nil, nil, nil, nil, fail(fmt.Sprintf("%d: empty token", ln))
			}
			tokens = append(tokens, Token{Node: NodeID{L: l, X: x, Y: y}, Payload: payload})
		default:
			return nil, nil, nil, nil, nil, fail(fmt.Sprintf("%d: unknown directive '%s'", ln, cmd))
		}
		// bounds-check every accumulated node (mirrors pnmc.py, which
		// re-checks the whole manifest after each directive)
		if err := checkAll(ln); err != nil {
			return nil, nil, nil, nil, nil, err
		}
	}
	return kernels, kernOrder, biases, biasOrder, tokens, nil
}

// parseHexByte mirrors Python int(t, 16) with optional 0x/0X prefix.
func parseHexByte(t string) (int, error) {
	s := strings.TrimPrefix(t, "0x")
	s = strings.TrimPrefix(s, "0X")
	v, err := strconv.ParseUint(s, 16, 8)
	if err != nil {
		return 0, err
	}
	return int(v), nil
}

// pyListBytes formats a byte slice like Python's list repr: "[1, 2, 3]".
func pyListBytes(b []byte) string {
	parts := make([]string, len(b))
	for i, v := range b {
		parts[i] = strconv.Itoa(int(v))
	}
	return "[" + strings.Join(parts, ", ") + "]"
}

// RunCompiler is the pnmc driver (formerly sim/pnmc.py main()).
func RunCompiler(program string, layers, bx, by, groups int, seed int64) int {
	progAbs, err := filepath.Abs(program)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	simDir := SimDir()
	if err := os.Chdir(simDir); err != nil {
		fmt.Fprintf(os.Stderr, "chdir %s: %v\n", simDir, err)
		return 1
	}
	stem := strings.TrimSuffix(filepath.Base(progAbs), filepath.Ext(progAbs))

	dims := Dims{Layers: layers, Bx: bx, By: by}
	nodes := AllNodes(layers, bx, by)
	if groups == 0 {
		groups = min(layers, runtime.NumCPU())
	}

	data, err := os.ReadFile(progAbs)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	kernels, kernOrder, biases, _, tokens, err := CompileProgram(string(data), dims)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}

	// unprogrammed token sinks default to the echo kernel (validation node)
	for _, t := range tokens {
		if _, ok := kernels[t.Node]; !ok {
			kernels[t.Node] = KernelDef{Name: "echo", Weights: []int{}}
			kernOrder = append(kernOrder, t.Node)
		}
	}

	// -- AOT mapping (Paper.MD §2.8): program nodes, then inject tokens ---
	prog := NewProgram(stem, nodes, "bounded")
	for _, n := range nodes {
		prog.BP[n] = 1 // no backpressure: idle fabric
	}
	for _, n := range kernOrder {
		kd := kernels[n]
		prog.ProgramNode(n, kd.Name, kd.Weights, biases[n])
	}
	for i, t := range tokens {
		prog.InjectRouted(t.Node, CTRL_COMPUTE_SPINE|((i&0x0F)&^1), t.Payload, false)
	}

	// -- compiled program listing (the AOT "assembly") --------------------
	fmt.Printf("compiled '%s' for %dx%dx%d = %d nodes, %d slice(s):\n",
		stem, layers, bx, by, len(nodes), groups)
	for _, n := range kernOrder {
		kd := kernels[n]
		fmt.Printf("  node (%d,%d,%d): kernel=%s bias=%#04x weights=%d\n",
			n.L, n.X, n.Y, kd.Name, biases[n], len(kd.Weights))
	}
	for _, t := range tokens {
		kd, ok := kernels[t.Node]
		if !ok {
			kd = KernelDef{Name: "echo", Weights: []int{}}
		}
		g := Golden(kd.Name, t.Payload, kd.Weights, map[string]uint64{}, biases[t.Node])
		gs := formatGolden(g)
		fmt.Printf("  token -> (%d,%d,%d): %d bytes -> golden %s\n",
			t.Node.L, t.Node.X, t.Node.Y, len(t.Payload), gs)
	}

	if !RunOne(prog, nodes, dims, groups, 1) {
		return 1
	}
	return 0
}

func formatGolden(g interface{}) string {
	switch v := g.(type) {
	case []byte:
		return pyListBytes(v)
	case uint64:
		return strconv.FormatUint(v, 10)
	}
	return fmt.Sprintf("%v", g)
}
