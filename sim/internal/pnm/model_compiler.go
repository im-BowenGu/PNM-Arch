package pnm

import (
	"fmt"
	"sort"
	"strings"
)

// ModelCompiler is the populated schema: a ModelIR placed onto a concrete
// chassis (node assignments, budgets, per-node compute units).
type ModelCompiler struct {
	Config *ModelConfig
	Index  *SafetensorsIndex
	Tensors map[string]*TensorMeta
	Dims    Dims
	IR      *ModelIR

	// Mapping results
	NodeAssignments map[NodeID]*NodeAssignment
	TotalBytes      int64
	NodeBudget      int64
	PerNodeBudget   int64
}

// NodeAssignment describes what a single node holds.
type NodeAssignment struct {
	Node       NodeID
	Layers     []int           // model layer indices assigned here
	Kernels    map[int]string  // model_layer -> kernel type
	Tensors    []TensorRef     // tensors resident on this node
	TotalBytes int64
	Bias       int
	// Available compute units on this node (populated by Partition)
	ComputeUnits []ComputeUnitType
}

// ComputeUnitType enumerates the hardware compute units available on each node.
type ComputeUnitType int

const (
	CUTypeNone     ComputeUnitType = iota
	CUTypeBF16FMA                  // bf16_fma: 16-bit BF16 Fused Multiply-Accumulate
	CUTypeFP16FMA                  // fp16_fma: 16-bit IEEE FP16 FMA
	CUTypeFP32FMA                  // fp32_fma: 32-bit FP FMA
	CUTypeFP64FMA                  // fp64_fma: 64-bit FP FMA
	CUTypeFP32ALU                  // fp32_alu: FP32 multi-function ALU (ADD/SUB/MUL/DIV/MIN/MAX/CMP)
	CUTypeINT8MAC                  // int8_mac: INT8 Multiply-Accumulate
	CUTypeBF16Array                // bf16_mac_array: BF16 systolic MAC array
	CUTypeFP16Array                // fp16_mac_array: FP16 systolic MAC array
	CUTypeFP64ALU                  // fp64_alu: FP64 multi-function ALU
	CUTypeFP32Array                // fp32_mac_array: FP32 systolic MAC array
	CUTypeINT8ALU                  // int8_alu: INT8 ALU (add/sub/shift)
)

// String returns the human-readable name of the compute unit type.
func (t ComputeUnitType) String() string {
	switch t {
	case CUTypeBF16FMA:
		return "bf16_fma"
	case CUTypeFP16FMA:
		return "fp16_fma"
	case CUTypeFP32FMA:
		return "fp32_fma"
	case CUTypeFP64FMA:
		return "fp64_fma"
	case CUTypeFP32ALU:
		return "fp32_alu"
	case CUTypeINT8MAC:
		return "int8_mac"
	case CUTypeBF16Array:
		return "bf16_mac_array"
	case CUTypeFP16Array:
		return "fp16_mac_array"
	case CUTypeFP64ALU:
		return "fp64_alu"
	case CUTypeFP32Array:
		return "fp32_mac_array"
	case CUTypeINT8ALU:
		return "int8_alu"
	default:
		return "none"
	}
}

// DTypeBytes returns the byte width of the compute unit's native data type.
func (t ComputeUnitType) DTypeBytes() int {
	switch t {
	case CUTypeBF16FMA, CUTypeFP16FMA, CUTypeBF16Array, CUTypeFP16Array:
		return 2
	case CUTypeINT8MAC, CUTypeINT8ALU:
		return 1
	case CUTypeFP32FMA, CUTypeFP32ALU, CUTypeFP32Array:
		return 4
	case CUTypeFP64FMA, CUTypeFP64ALU:
		return 8
	default:
		return 2 // BF16 default
	}
}

// TensorRef is a reference to a tensor with its role and compute unit type.
type TensorRef struct {
	Name      string
	Role      string          // "expert_gate_up", "expert_down", "attention_q", etc.
	ModelLayer int
	ExpertIdx  int            // -1 if not expert-specific
	SizeBytes  int64
	CUType     ComputeUnitType // hardware unit that processes this tensor
	DType      string         // "BF16", "FP16", "FP32", "INT8"
}

// CompileModel performs the full AOT compilation pipeline: lower the model to
// chassis-independent IR, then populate the chassis schema from it.
func CompileModel(cfg *ModelConfig, idx *SafetensorsIndex, dims Dims) (*ModelCompiler, error) {
	ir, err := CompileModelIR(cfg, idx)
	if err != nil {
		return nil, err
	}
	return ir.PopulateSchema(dims)
}

// EmitListing prints the compilation listing (the AOT "assembly").
func (mc *ModelCompiler) EmitListing() string {
	var b strings.Builder
	tc := &mc.Config.TextConfig

	b.WriteString(fmt.Sprintf("# Gemma-4-26B-A4B-it PNM compilation listing\n"))
	b.WriteString(fmt.Sprintf("# chassis: %dx%dx%d = %d nodes\n",
		mc.Dims.Layers, mc.Dims.Bx, mc.Dims.By,
		mc.Dims.Layers*mc.Dims.Bx*mc.Dims.By))
	b.WriteString(fmt.Sprintf("# model: %d layers, hidden=%d, experts=%d, active=%d\n",
		tc.NumHiddenLayers, tc.HiddenSize, tc.NumExperts, tc.TopKExperts))
	b.WriteString(fmt.Sprintf("# total weights: %.1f GB (BF16)\n", float64(mc.TotalBytes)/1e9))
	b.WriteString(fmt.Sprintf("# node budget: %.1f GB each\n",
		float64(mc.PerNodeBudget)/1e9))
	b.WriteString("\n")

	// Sort nodes for deterministic output
	var nodes []NodeID
	for nid := range mc.NodeAssignments {
		nodes = append(nodes, nid)
	}
	sort.Slice(nodes, func(i, j int) bool {
		a, b := nodes[i], nodes[j]
		if a.L != b.L {
			return a.L < b.L
		}
		if a.X != b.X {
			return a.X < b.X
		}
		return a.Y < b.Y
	})

	var maxUsage float64
	nodeBudget := float64(mc.PerNodeBudget)

	for _, nid := range nodes {
		na := mc.NodeAssignments[nid]
		if na.TotalBytes == 0 {
			continue
		}
		usage := float64(na.TotalBytes) / nodeBudget * 100
		if usage > maxUsage {
			maxUsage = usage
		}

		b.WriteString(fmt.Sprintf("# node (%d,%d,%d): %d layers, %d tensors, %.1f MB (%.1f%%)\n",
			nid.L, nid.X, nid.Y,
			len(na.Layers), len(na.Tensors),
			float64(na.TotalBytes)/1e6, usage))

		// Group tensors by model layer
		byLayer := map[int][]TensorRef{}
		for _, t := range na.Tensors {
			byLayer[t.ModelLayer] = append(byLayer[t.ModelLayer], t)
		}

		var layerIndices []int
		for ml := range byLayer {
			layerIndices = append(layerIndices, ml)
		}
		sort.Ints(layerIndices)

		for _, ml := range layerIndices {
			refs := byLayer[ml]
			roles := map[string]int{}
			for _, r := range refs {
				roles[r.Role]++
			}
			roleStrs := make([]string, 0, len(roles))
			for role, count := range roles {
				if count > 1 {
					roleStrs = append(roleStrs, fmt.Sprintf("%s(%d)", role, count))
				} else {
					roleStrs = append(roleStrs, role)
				}
			}
			sort.Strings(roleStrs)
			b.WriteString(fmt.Sprintf("  layer %d: %s\n", ml, strings.Join(roleStrs, ", ")))
		}
	}

	b.WriteString(fmt.Sprintf("\n# max node utilization: %.1f%%\n", maxUsage))
	b.WriteString(fmt.Sprintf("# spine layers: %d, cross-layer traffic: %s\n",
		mc.Dims.Layers, mc.estimateCrossLayerTraffic()))

	return b.String()
}

// estimateCrossLayerTraffic estimates the cross-layer traffic fraction.
func (mc *ModelCompiler) estimateCrossLayerTraffic() string {
	tc := &mc.Config.TextConfig
	// For MoE with random placement, alpha = (layers-1)/layers
	// With layer-local expert placement, alpha approaches 0
	layersWithExperts := 0
	for pl := 0; pl < mc.Dims.Layers; pl++ {
		hasExperts := false
		for _, na := range mc.NodeAssignments {
			if na.Node.L == pl && na.TotalBytes > 0 {
				hasExperts = true
				break
			}
		}
		if hasExperts {
			layersWithExperts++
		}
	}
	alpha := float64(mc.Dims.Layers-1) / float64(mc.Dims.Layers)
	return fmt.Sprintf("alpha=%.2f (%d/%d layers with experts, %d active/tok)",
		alpha, layersWithExperts, mc.Dims.Layers, tc.TopKExperts)
}

// EmitProgram generates the .pnm program text.
func (mc *ModelCompiler) EmitProgram() string {
	var b strings.Builder
	tc := &mc.Config.TextConfig

	b.WriteString(fmt.Sprintf("# Gemma-4-26B-A4B-it PNM program\n"))
	b.WriteString(fmt.Sprintf("# Generated by model compiler\n"))
	b.WriteString(fmt.Sprintf("# chassis: %dx%dx%d\n\n", mc.Dims.Layers, mc.Dims.Bx, mc.Dims.By))

	// Sort nodes
	var nodes []NodeID
	for nid := range mc.NodeAssignments {
		nodes = append(nodes, nid)
	}
	sort.Slice(nodes, func(i, j int) bool {
		a, b := nodes[i], nodes[j]
		if a.L != b.L {
			return a.L < b.L
		}
		if a.X != b.X {
			return a.X < b.X
		}
		return a.Y < b.Y
	})

	for _, nid := range nodes {
		na := mc.NodeAssignments[nid]
		if na.TotalBytes == 0 || nid.L == -1 {
			continue // skip empty nodes and the router chip
		}

		// Emit kernel directives for each model layer on this node
		byLayer := map[int][]TensorRef{}
		for _, t := range na.Tensors {
			byLayer[t.ModelLayer] = append(byLayer[t.ModelLayer], t)
		}

		var layerIndices []int
		for ml := range byLayer {
			layerIndices = append(layerIndices, ml)
		}
		sort.Ints(layerIndices)

		for _, ml := range layerIndices {
			refs := byLayer[ml]

			// Expert kernels
			for _, r := range refs {
				if r.Role == "expert_gate_up" || r.Role == "expert_down" {
					// Truncate weights to a representative sample (full weights too large)
					sampleSize := min(64, tc.HiddenSize)
					weights := make([]string, sampleSize)
					for i := range weights {
						weights[i] = fmt.Sprintf("%02x", (i+ml+r.ExpertIdx)&0xFF)
					}
					b.WriteString(fmt.Sprintf("kernel dot %d %d %d %s\n",
						nid.L, nid.X, nid.Y,
						strings.Join(weights, " ")))
					break // one kernel per model layer per node
				}
			}

			// Bias directive (representative)
			if len(refs) > 0 {
				bias := (ml*7 + nid.X*3 + nid.Y*5) & 0xFF
				b.WriteString(fmt.Sprintf("bias %d %d %d %d\n",
					bias, nid.L, nid.X, nid.Y))
			}
		}
	}

	// Emit token injection directives for a sample inference pass
	b.WriteString("\n# -- sample inference: 1 token through all layers --\n")
	// Token enters at layer 0, node (0,0,0)
	samplePayload := make([]string, 32)
	for i := range samplePayload {
		samplePayload[i] = fmt.Sprintf("%02x", i)
	}
	b.WriteString(fmt.Sprintf("token 0 0 0 %s\n", strings.Join(samplePayload, " ")))

	return b.String()
}

// EmitSchema generates the node schema (coordinate assignment + routing info).
func (mc *ModelCompiler) EmitSchema() string {
	var b strings.Builder

	b.WriteString(fmt.Sprintf("# PNM Schema: Gemma-4-26B-A4B-it\n"))
	b.WriteString(fmt.Sprintf("# chassis: %dx%dx%d = %d nodes\n\n",
		mc.Dims.Layers, mc.Dims.Bx, mc.Dims.By,
		mc.Dims.Layers*mc.Dims.Bx*mc.Dims.By))

	// Sort nodes
	var nodes []NodeID
	for nid := range mc.NodeAssignments {
		nodes = append(nodes, nid)
	}
	sort.Slice(nodes, func(i, j int) bool {
		a, b := nodes[i], nodes[j]
		if a.L != b.L {
			return a.L < b.L
		}
		if a.X != b.X {
			return a.X < b.X
		}
		return a.Y < b.Y
	})

	b.WriteString("# Coordinate Map\n")
	b.WriteString("# L  X  Y  | MODULE_ID | ROUTE_BITMAP | ROLE\n")
	b.WriteString("# ---------+-----------+--------------+------\n")
	for _, nid := range nodes {
		na := mc.NodeAssignments[nid]
		if nid.L == -1 {
			b.WriteString(fmt.Sprintf("# central router chip: %d layers, %d tensors, %.0f MB\n",
				len(na.Layers), len(na.Tensors), float64(na.TotalBytes)/1e6))
			continue
		}
		moduleID := (nid.X << 4) | nid.Y
		routeBitmap := ((nid.L + 1) << 7) | (1 << 6) | (nid.Y << 0) // layer + AXIS=Y + Y dist
		role := "empty"
		if na.TotalBytes > 0 {
			role = fmt.Sprintf("compute (%d tensors, %.0f MB)",
				len(na.Tensors), float64(na.TotalBytes)/1e6)
		}
		b.WriteString(fmt.Sprintf("  %d  %d  %d  |   0x%02x    |   0x%03x      | %s\n",
			nid.L, nid.X, nid.Y, moduleID, routeBitmap, role))
	}

	b.WriteString("\n# Routing Bitmaps (for xyz_repeater and HFR load)\n")
	b.WriteString("# Each repeater/hfr receives: 11-bit bitmap [LAYER:4][AXIS:1][SIGN:1][DIST:5]\n")
	b.WriteString("# layer_bits = (LAYER_ID) << 7, AXIS=0 (X), SIGN=0 (+), DIST=0\n")
	for l := 0; l < mc.Dims.Layers; l++ {
		bitmap := (l + 1) << 7
		b.WriteString(fmt.Sprintf("# layer %d: xyz_repeater bitmap = 11'h%03x\n", l, bitmap))
	}

	b.WriteString("\n# Spine Sizing\n")
	b.WriteString(fmt.Sprintf("# spine_layers = %d\n", mc.Dims.Layers))
	b.WriteString(fmt.Sprintf("# link_rate = 16 GB/s per lane\n"))
	b.WriteString(fmt.Sprintf("# spine_aggregate = ~2 TB/s per direction\n"))

	return b.String()
}

// ComputeUnitSummary returns a per-type count of compute units across all nodes.
func (mc *ModelCompiler) ComputeUnitSummary() map[ComputeUnitType]int {
	counts := map[ComputeUnitType]int{}
	for _, na := range mc.NodeAssignments {
		if na.Node.L < 0 {
			continue
		}
		for _, cu := range na.ComputeUnits {
			counts[cu]++
		}
	}
	return counts
}
