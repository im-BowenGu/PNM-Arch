package pnm

import (
	"fmt"
	"strings"
)

// Workload generators for known HPC algorithms.
//
// Each generator emits .pnm program text that maps a well-known algorithm onto
// the PNM chassis, exercising a specific routing pattern. These serve as both
// correctness tests and routing-pattern demonstrations.
//
// Routing patterns exercised:
//   - Dimension-order X→Y (stencil: nearest-neighbor on one layer)
//   - Spine descent (matvec rows spread across layers)
//   - Reverse-path merge (reduction tree collecting partial sums)
//   - Hotspot / broadcast (weight distribution to all nodes)

// Workload describes a generated program plus its metadata.
type Workload struct {
	Name     string // e.g. "jacobi5"
	Desc     string // human-readable description
	Program  string // .pnm directive text
	Routing  string // routing pattern exercised
	Nodes    int    // number of compute nodes used
	Tokens   int    // number of tokens dispatched
}

// GenJacobi5 generates a 5-point Jacobi stencil iteration mapped onto a single
// physical layer's X/Y grid. Each node holds one grid point; its `dot` kernel
// carries the stencil coefficients [w_c, w_n, w_s, w_e, w_w] as resident
// weights. Each token packs the 5-point neighborhood [center, north, south,
// east, west] into a 5-byte payload. The doorbell fires per node per iteration;
// the result is the next-iteration value.
//
// Routing: pure intra-layer dimension-order X→Y. No spine traffic — halo
// exchanges are single-hop routes between adjacent sockets (Paper §2.2).
func GenJacobi5(layers, bx, by int) (*Workload, error) {
	if layers < 1 || bx < 3 || by < 3 {
		return nil, fmt.Errorf("jacobi5 needs layers>=1 bx>=3 by>=3, got %dx%dx%d", layers, bx, by)
	}
	l := 0 // stencil lives entirely on layer 0
	var b strings.Builder
	b.WriteString("# jacobi5.pnm — 5-point Jacobi stencil, one grid point per node\n")
	b.WriteString("# Weights: [w_center=0.5*64, w_north=0.125*64, w_south, w_east, w_west] in Q6 fixed-point\n")
	b.WriteString("# Token payload = [x_c, x_n, x_s, x_e, x_w] neighborhood bytes\n")
	b.WriteString("# Routing: intra-layer dimension-order X→Y only; zero spine traffic.\n\n")

	tokens := 0
	for y := 0; y < by; y++ {
		for x := 0; x < bx; x++ {
			// Stencil weights in Q6 fixed-point (byte range): center=32, edges=8 each
			fmt.Fprintf(&b, "kernel dot %d %d %d 20 08 08 08 08\n", l, x, y)
			fmt.Fprintf(&b, "bias   0 %d %d %d\n", l, x, y)
		}
	}
	b.WriteString("\n")
	// Dispatch a neighborhood token to every interior node
	for y := 1; y < by-1; y++ {
		for x := 1; x < bx-1; x++ {
			// Neighborhood values: center=x*y+1, neighbors derived deterministically
			xc := byte((x*y + 1) & 0xFF)
			xn := byte(((y+1)*bx + x + 1) & 0xFF)
			xs := byte(((y-1)*bx + x + 1) & 0xFF)
			xe := byte((x*y + 2) & 0xFF)
			xw := byte((x*y + 3) & 0xFF)
			fmt.Fprintf(&b, "token %d %d %d  %02x %02x %02x %02x %02x\n", l, x, y, xc, xn, xs, xe, xw)
			tokens++
		}
	}
	nodes := bx * by
	return &Workload{
		Name:    "jacobi5",
		Desc:    fmt.Sprintf("5-point Jacobi stencil on layer 0 (%dx%d grid)", bx, by),
		Program: b.String(),
		Routing: "intra-layer X→Y dimension-order",
		Nodes:   nodes,
		Tokens:  tokens,
	}, nil
}

// GenMatVec generates a matrix-vector product where each row of the matrix
// is assigned to one node as its resident `dot` weights, and the input vector
// is broadcast as a token to every row-node simultaneously.
//
// Routing: spine descent if rows span multiple layers; intra-layer otherwise.
// Every node fires once per invocation — this is the weight-stationary pattern
// the paper's roofline analysis targets (Paper §3.2).
func GenMatVec(layers, bx, by int, vecLen int) (*Workload, error) {
	if layers < 1 || bx < 1 || by < 1 {
		return nil, fmt.Errorf("matvec needs layers>=1 bx>=1 by>=1, got %dx%dx%d", layers, bx, by)
	}
	if vecLen < 1 || vecLen > 256 {
		return nil, fmt.Errorf("vecLen must be 1..256, got %d", vecLen)
	}
	rows := layers * bx * by
	var b strings.Builder
	b.WriteString("# matvec.pnm — matrix-vector product, row-per-node weight-stationary\n")
	b.WriteString(fmt.Sprintf("# Matrix: %d rows × %d cols, one row per node across %d layer(s)\n", rows, vecLen, layers))
	b.WriteString("# Input vector is dispatched to every row-node; each computes its dot product.\n")
	b.WriteString("# Routing: spine descent for cross-layer rows; X→Y within a layer.\n\n")

	// Deterministic matrix entries: A[i][j] = (i+j) mod 251 + 1
	rowIdx := 0
	for l := 0; l < layers; l++ {
		for y := 0; y < by; y++ {
			for x := 0; x < bx; x++ {
				var w strings.Builder
				for j := 0; j < vecLen; j++ {
					w.WriteString(fmt.Sprintf(" %02x", (rowIdx+j)%251+1))
				}
				fmt.Fprintf(&b, "kernel dot %d %d %d%s\n", l, x, y, w.String())
				fmt.Fprintf(&b, "bias   0 %d %d %d\n", l, x, y)
				rowIdx++
			}
		}
	}
	b.WriteString("\n")

	// Input vector: v[j] = (j*7+13) mod 256
	var vec strings.Builder
	for j := 0; j < vecLen; j++ {
		vec.WriteString(fmt.Sprintf(" %02x", byte(j*7+13)))
	}
	// One token per row-node carrying the same input vector
	for l := 0; l < layers; l++ {
		for y := 0; y < by; y++ {
			for x := 0; x < bx; x++ {
				fmt.Fprintf(&b, "token %d %d %d%s\n", l, x, y, vec.String())
			}
		}
	}
	routing := "spine descent (cross-layer)"
	if layers == 1 {
		routing = "intra-layer X→Y"
	}
	return &Workload{
		Name:    "matvec",
		Desc:    fmt.Sprintf("%d×%d matvec, row-per-node", rows, vecLen),
		Program: b.String(),
		Routing: routing,
		Nodes:   rows,
		Tokens:  rows,
	}, nil
}

// GenReduction generates a reverse-path merge tree: leaf nodes at layer 0 hold
// data fragments and send them toward a root node at the top layer. Every node
// runs the `echo` kernel (stateless pass-through) so the golden model is
// order-independent — the routing pattern (egress → Y-up → X-up → spine
// ascent) is fully exercised regardless of merge-point arbitration order.
//
// In production, the root would run `accum` to combine partial results; using
// `echo` here lets the co-sim verify correct delivery without depending on
// arbiter-determined arrival order.
func GenReduction(layers, bx, by int, fragLen int) (*Workload, error) {
	if layers < 2 {
		return nil, fmt.Errorf("reduction needs layers>=2 for spine traversal, got %d", layers)
	}
	if fragLen < 1 || fragLen > 128 {
		return nil, fmt.Errorf("fragLen must be 1..128, got %d", fragLen)
	}
	rootL := layers - 1
	var b strings.Builder
	b.WriteString("# reduction.pnm — reverse-path merge tree (egress → Y → X → spine ascent)\n")
	b.WriteString(fmt.Sprintf("# %d leaf nodes on layer 0 send %d-byte fragments to root(%d,0,0).\n", bx*by, fragLen, rootL))
	b.WriteString("# All nodes run echo (stateless) so the co-sim verify is order-independent.\n")
	b.WriteString("# In production the root would run accum; echo proves the routing path.\n\n")

	// Every node gets echo kernel (including root and idle nodes on intermediate layers)
	for l := 0; l < layers; l++ {
		for y := 0; y < by; y++ {
			for x := 0; x < bx; x++ {
				fmt.Fprintf(&b, "kernel echo %d %d %d\n", l, x, y)
				fmt.Fprintf(&b, "bias   0 %d %d %d\n", l, x, y)
			}
		}
	}
	b.WriteString("\n")

	// Data fragments: the injector (node 0,0,0) sends one token per leaf
	// destined for the root at (rootL, 0, 0). Each token traverses the
	// spine from layer 0 to rootL, exercising multi-layer routing.
	// In production, the leaves would compute locally and send results
	// back via the reverse-path merge chain; the co-sim injector
	// substitutes for that multi-round computation.
	tokens := 0
	for y := 0; y < by; y++ {
		for x := 0; x < bx; x++ {
			var frag strings.Builder
			for i := 0; i < fragLen; i++ {
				frag.WriteString(fmt.Sprintf(" %02x", byte(x+y+i+1)&0xFF))
			}
			fmt.Fprintf(&b, "token %d 0 0%s\n", rootL, frag.String())
			tokens++
		}
	}

	return &Workload{
		Name:    "reduction",
		Desc:    fmt.Sprintf("reverse-path merge: %d leaves → root(%d,0,0)", bx*by, rootL),
		Program: b.String(),
		Routing: "reverse-path merge (egress → Y-up → X-up → spine ascent)",
		Nodes:   bx*by + 1,
		Tokens:  tokens,
	}, nil
}

// GenBroadcast generates a weight-distribution broadcast: one source node at
// the top layer sends identical payloads to every node in the chassis. This
// is the POST Phase-3 weight-upload pattern (Paper §2.5), scaled down.
//
// Routing: spine descent to every layer, then X→Y fan-out per layer. Worst-case
// hotspot on the source node's uplink.
func GenBroadcast(layers, bx, by int, payloadLen int) (*Workload, error) {
	if layers < 2 {
		return nil, fmt.Errorf("broadcast needs layers>=2, got %d", layers)
	}
	if payloadLen < 1 || payloadLen > 1024 {
		return nil, fmt.Errorf("payloadLen must be 1..1024, got %d", payloadLen)
	}
	srcL := layers - 1
	total := layers * bx * by
	var b strings.Builder
	b.WriteString("# broadcast.pnm — weight distribution from root to every node\n")
	b.WriteString(fmt.Sprintf("# Source (%d,0,0) → all %d nodes; %d-byte payload each.\n", srcL, total, payloadLen))
	b.WriteString("# Exercises spine descent bandwidth and per-layer fan-out.\n\n")

	// All nodes get echo kernel (pass-through validation)
	for l := 0; l < layers; l++ {
		for y := 0; y < by; y++ {
			for x := 0; x < bx; x++ {
				fmt.Fprintf(&b, "kernel echo %d %d %d\n", l, x, y)
				fmt.Fprintf(&b, "bias   0 %d %d %d\n", l, x, y)
			}
		}
	}
	b.WriteString("\n")

	// Identical payload to every destination
	var pl strings.Builder
	for i := 0; i < payloadLen; i++ {
		pl.WriteString(" aa")
	}
	for l := 0; l < layers; l++ {
		for y := 0; y < by; y++ {
			for x := 0; x < bx; x++ {
				fmt.Fprintf(&b, "token %d %d %d%s\n", l, x, y, pl.String())
			}
		}
	}
	return &Workload{
		Name:    "broadcast",
		Desc:    fmt.Sprintf("root(%d,0,0) broadcasts %dB to all %d nodes", srcL, payloadLen, total),
		Program: b.String(),
		Routing: "spine descent + per-layer X→Y fan-out",
		Nodes:   total,
		Tokens:  total,
	}, nil
}

// GenNBody generates an all-pairs interaction workload: every node sends a
// token to every other node (O(N²) traffic). This is the worst-case routing
// pattern for any fabric — it saturates every link and stresses the spine.
// Useful as an upper-bound benchmark, not a practical workload.
func GenNBody(layers, bx, by int, payloadLen int) (*Workload, error) {
	if payloadLen < 1 || payloadLen > 64 {
		payloadLen = 16
	}
	total := layers * bx * by
	if total > 64 {
		return nil, fmt.Errorf("nbody limited to 64 nodes for simulation tractability, got %d", total)
	}
	var b strings.Builder
	b.WriteString("# nbody.pnm — all-pairs O(N²) interaction stress test\n")
	b.WriteString(fmt.Sprintf("# Every node sends to every other node: %d²=%d tokens.\n", total, total*total))
	b.WriteString("# Worst-case fabric saturation; upper-bound benchmark only.\n\n")

	for l := 0; l < layers; l++ {
		for y := 0; y < by; y++ {
			for x := 0; x < bx; x++ {
				fmt.Fprintf(&b, "kernel sum %d %d %d\n", l, x, y)
				fmt.Fprintf(&b, "bias   0 %d %d %d\n", l, x, y)
			}
		}
	}
	b.WriteString("\n")

	nodeAt := func(idx int) (int, int, int) {
		l := idx / (bx * by)
		rem := idx % (bx * by)
		return l, rem / by, rem % by
	}
	for i := 0; i < total; i++ {
		il, ix, iy := nodeAt(i)
		for j := 0; j < total; j++ {
			jl, jx, jy := nodeAt(j)
			var pl strings.Builder
			for k := 0; k < payloadLen; k++ {
				pl.WriteString(fmt.Sprintf(" %02x", byte(i*j+k+1)&0xFF))
			}
			fmt.Fprintf(&b, "token %d %d %d%s\n", jl, jx, jy, pl.String())
		}
		_ = il
		_ = ix
		_ = iy
	}
	return &Workload{
		Name:    "nbody",
		Desc:    fmt.Sprintf("all-pairs %d×%d = %d tokens", total, total, total*total),
		Program: b.String(),
		Routing: "all paths saturated (worst case)",
		Nodes:   total,
		Tokens:  total * total,
	}, nil
}

// Workloads returns the built-in workload registry.
func Workloads() map[string]struct {
	Layers, Bx, By int
	Frag           int // extra parameter (vector length, fragment size, etc.)
	Gen            func(layers, bx, by, frag int) (*Workload, error)
} {
	return map[string]struct {
		Layers, Bx, By int
		Frag           int
		Gen            func(layers, bx, by, frag int) (*Workload, error)
	}{
		"jacobi5":   {Layers: 1, Bx: 4, By: 4, Frag: 0, Gen: func(l, x, y, f int) (*Workload, error) { return GenJacobi5(l, x, y) }},
		"matvec":    {Layers: 4, Bx: 4, By: 4, Frag: 16, Gen: GenMatVec},
		"reduction": {Layers: 4, Bx: 4, By: 4, Frag: 32, Gen: GenReduction},
		"broadcast": {Layers: 4, Bx: 4, By: 4, Frag: 64, Gen: GenBroadcast},
		"nbody":     {Layers: 4, Bx: 4, By: 4, Frag: 16, Gen: GenNBody},
	}
}
