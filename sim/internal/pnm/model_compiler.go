package pnm

import (
	"fmt"
	"math"
	"sort"
	"strings"
)

// ModelCompiler transpiles a model (safetensors + config) onto a PNM chassis.
type ModelCompiler struct {
	Config *ModelConfig
	Index  *SafetensorsIndex
	Tensors map[string]*TensorMeta
	Dims    Dims

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
}

// TensorRef is a reference to a tensor with its role.
type TensorRef struct {
	Name      string
	Role      string // "expert_gate_up", "expert_down", "attention_q", etc.
	ModelLayer int
	ExpertIdx  int  // -1 if not expert-specific
	SizeBytes  int64
}

// CompileModel performs the full AOT compilation pipeline.
func CompileModel(cfg *ModelConfig, idx *SafetensorsIndex, dims Dims) (*ModelCompiler, error) {
	tensors, totalBytes := CollectTensors(idx, cfg)

	mc := &ModelCompiler{
		Config:   cfg,
		Index:    idx,
		Tensors:  tensors,
		Dims:     dims,
		TotalBytes: totalBytes,
		NodeBudget:     int64(dims.Layers*dims.Bx*dims.By) * 128 * 1024 * 1024 * 1024,
		PerNodeBudget:  128 * 1024 * 1024 * 1024, // 128 GB per node
		NodeAssignments: make(map[NodeID]*NodeAssignment),
	}

	if err := mc.Partition(); err != nil {
		return nil, err
	}

	return mc, nil
}

// Partition assigns model layers and experts to physical nodes.
func (mc *ModelCompiler) Partition() error {
	tc := &mc.Config.TextConfig
	numLayers := tc.NumHiddenLayers
	nodesPerLayer := mc.Dims.Bx * mc.Dims.By

	// Distribute model layers evenly across physical layers
	modelLayersPerPhysical := int(math.Ceil(float64(numLayers) / float64(mc.Dims.Layers)))

	// Initialize all nodes
	for l := 0; l < mc.Dims.Layers; l++ {
		for x := 0; x < mc.Dims.Bx; x++ {
			for y := 0; y < mc.Dims.By; y++ {
				nid := NodeID{L: l, X: x, Y: y}
				mc.NodeAssignments[nid] = &NodeAssignment{
					Node:    nid,
					Layers:  []int{},
					Kernels: make(map[int]string),
					Tensors: []TensorRef{},
				}
			}
		}
	}

	// Phase 1: Assign model layers to physical layers
	type layerMapping struct {
		physicalLayer int
		modelLayers   []int
	}
	var mappings []layerMapping
	for pl := 0; pl < mc.Dims.Layers; pl++ {
		start := pl * modelLayersPerPhysical
		end := start + modelLayersPerPhysical
		if end > numLayers {
			end = numLayers
		}
		if start >= numLayers {
			break
		}
		mls := make([]int, end-start)
		for i := range mls {
			mls[i] = start + i
		}
		mappings = append(mappings, layerMapping{physicalLayer: pl, modelLayers: mls})
	}

	// Phase 2: Within each physical layer, distribute experts across nodes
	for _, m := range mappings {
		pl := m.physicalLayer
		for _, ml := range m.modelLayers {
			layerType := "sliding_attention"
			if ml < len(tc.LayerTypes) {
				layerType = tc.LayerTypes[ml]
			}

			// Assign experts round-robin across nodes on this physical layer
			for expIdx := 0; expIdx < tc.NumExperts; expIdx++ {
				nodeIdx := expIdx % nodesPerLayer
				x := nodeIdx / mc.Dims.By
				y := nodeIdx % mc.Dims.By
				nid := NodeID{L: pl, X: x, Y: y}
				na := mc.NodeAssignments[nid]

				if len(na.Layers) == 0 || na.Layers[len(na.Layers)-1] != ml {
					na.Layers = append(na.Layers, ml)
				}

				// Expert gate_up projection
				na.Tensors = append(na.Tensors, TensorRef{
					Name:       fmt.Sprintf("layers.%d.experts.gate_up_proj", ml),
					Role:       "expert_gate_up",
					ModelLayer: ml,
					ExpertIdx:  expIdx,
					SizeBytes:  int64(2*tc.MoEIntermediateSize*tc.HiddenSize) * 2, // BF16
				})

				// Expert down projection
				na.Tensors = append(na.Tensors, TensorRef{
					Name:       fmt.Sprintf("layers.%d.experts.down_proj", ml),
					Role:       "expert_down",
					ModelLayer: ml,
					ExpertIdx:  expIdx,
					SizeBytes:  int64(tc.MoEIntermediateSize*tc.HiddenSize) * 2,
				})
			}

			// Assign attention + dense MLP to a dedicated node (round-robin by model layer)
			attnNodeIdx := ml % nodesPerLayer
			x := attnNodeIdx / mc.Dims.By
			y := attnNodeIdx % mc.Dims.By
			nid := NodeID{L: pl, X: x, Y: y}
			na := mc.NodeAssignments[nid]

			na.Tensors = append(na.Tensors, []TensorRef{
				{Name: fmt.Sprintf("layers.%d.self_attn.q_proj", ml), Role: "attn_q", ModelLayer: ml, SizeBytes: int64(tc.HiddenSize*tc.HiddenSize) * 2},
				{Name: fmt.Sprintf("layers.%d.self_attn.k_proj", ml), Role: "attn_k", ModelLayer: ml, SizeBytes: int64(tc.NumKeyValueHeads*tc.HeadDim*tc.HiddenSize) * 2},
				{Name: fmt.Sprintf("layers.%d.self_attn.v_proj", ml), Role: "attn_v", ModelLayer: ml, SizeBytes: int64(tc.NumKeyValueHeads*tc.HeadDim*tc.HiddenSize) * 2},
				{Name: fmt.Sprintf("layers.%d.self_attn.o_proj", ml), Role: "attn_o", ModelLayer: ml, SizeBytes: int64(tc.HiddenSize*tc.HiddenSize) * 2},
				{Name: fmt.Sprintf("layers.%d.mlp.gate_proj", ml), Role: "dense_gate", ModelLayer: ml, SizeBytes: int64(tc.IntermediateSize*tc.HiddenSize) * 2},
				{Name: fmt.Sprintf("layers.%d.mlp.up_proj", ml), Role: "dense_up", ModelLayer: ml, SizeBytes: int64(tc.IntermediateSize*tc.HiddenSize) * 2},
				{Name: fmt.Sprintf("layers.%d.mlp.down_proj", ml), Role: "dense_down", ModelLayer: ml, SizeBytes: int64(tc.HiddenSize*tc.IntermediateSize) * 2},
				{Name: fmt.Sprintf("layers.%d.input_layernorm", ml), Role: "layernorm", ModelLayer: ml, SizeBytes: int64(tc.HiddenSize) * 2},
				{Name: fmt.Sprintf("layers.%d.post_attention_layernorm", ml), Role: "layernorm", ModelLayer: ml, SizeBytes: int64(tc.HiddenSize) * 2},
			}...)
			_ = layerType
		}
	}

	// Phase 2b: Router weights live on the central router chip (paper §2.1,
	// §2.8) — not on any compute node.  We mark them with a special sentinel
	// node (-1, -1, -1) that EmitSchema / EmitProgram can recognise.
	routerNID := NodeID{L: -1, X: -1, Y: -1}
	if _, ok := mc.NodeAssignments[routerNID]; !ok {
		mc.NodeAssignments[routerNID] = &NodeAssignment{
			Node:    routerNID,
			Layers:  []int{},
			Kernels: make(map[int]string),
			Tensors: []TensorRef{},
		}
	}
	for _, m := range mappings {
		for _, ml := range m.modelLayers {
			na := mc.NodeAssignments[routerNID]
			if len(na.Layers) == 0 || na.Layers[len(na.Layers)-1] != ml {
				na.Layers = append(na.Layers, ml)
			}
			na.Tensors = append(na.Tensors, TensorRef{
				Name:       fmt.Sprintf("layers.%d.router.proj", ml),
				Role:       "router_weights",
				ModelLayer: ml,
				SizeBytes:  int64(tc.NumExperts*tc.HiddenSize) * 2, // BF16
			})
		}
	}

	// Phase 3: Assign shared tensors (embeddings, final norm)
	// Shard the embedding table across layer-0 nodes by token-ID range
	// so no single node is a memory hotspot for the vocabulary.
	nodesLayer0 := mc.Dims.Bx * mc.Dims.By
	if nodesLayer0 < 1 {
		nodesLayer0 = 1
	}
	rowsPerNode := tc.VocabSize / nodesLayer0
	extraRows := tc.VocabSize % nodesLayer0
	for n := 0; n < nodesLayer0; n++ {
		x := n / mc.Dims.By
		y := n % mc.Dims.By
		nid := NodeID{L: 0, X: x, Y: y}
		na := mc.NodeAssignments[nid]

		rows := rowsPerNode
		if n < extraRows {
			rows++ // distribute remainder to first nodes
		}
		embedBytes := int64(rows*tc.HiddenSize) * 2 // BF16
		na.Tensors = append(na.Tensors, TensorRef{
			Name:       fmt.Sprintf("embed_tokens.shard_%d", n),
			Role:       "embedding",
			ModelLayer: -1,
			SizeBytes:  embedBytes,
		})
	}

	// Final norm is tiny (~5 KB); place on a rotating layer-0 node
	normNodeIdx := tc.NumHiddenLayers % nodesLayer0
	xn := normNodeIdx / mc.Dims.By
	yn := normNodeIdx % mc.Dims.By
	nidNorm := NodeID{L: 0, X: xn, Y: yn}
	naNorm := mc.NodeAssignments[nidNorm]
	naNorm.Tensors = append(naNorm.Tensors, TensorRef{
		Name:       "norm",
		Role:       "final_norm",
		ModelLayer: -1,
		SizeBytes:  int64(tc.HiddenSize) * 2,
	})

	// Phase 3b: Reserve KV cache memory on attention nodes
	// Each attention node stores K/V projections for autoregressive inference.
	// Reserve 80% of remaining budget for KV cache (20%留给 activation memory).
	tc = &mc.Config.TextConfig
	kvEntryBytes := int64(tc.HiddenSize) * 4 // K(2B) + V(2B) per hidden dim
	kvBudgetPerNode := int64(float64(mc.PerNodeBudget) * 0.80)
	kvEntriesPerNode := kvBudgetPerNode / kvEntryBytes
	if kvEntriesPerNode > 16384 {
		kvEntriesPerNode = 16384 // cap at 16K entries (16K context)
	}
	for nid, na := range mc.NodeAssignments {
		if nid.L < 0 || na.TotalBytes == 0 {
			continue
		}
		// Only add KV cache to nodes that have attention weights
		hasAttn := false
		for _, t := range na.Tensors {
			if t.Role == "attn_q" {
				hasAttn = true
				break
			}
		}
		if hasAttn {
			kvBytes := kvEntriesPerNode * kvEntryBytes
			na.Tensors = append(na.Tensors, TensorRef{
				Name:       fmt.Sprintf("kv_cache.l%d", nid.L),
				Role:       "kv_cache",
				ModelLayer: -1,
				SizeBytes:  kvBytes,
			})
		}
	}

	// Compute per-node totals and enforce per-node budget
	for _, na := range mc.NodeAssignments {
		var total int64
		for _, t := range na.Tensors {
			total += t.SizeBytes
		}
		na.TotalBytes = total

		// Assign kernel type based on dominant role
		if total > 0 {
			na.Kernels[-1] = "dot" // default kernel for compute nodes
		}

		// Enforce per-node memory budget (skip the router chip node)
		if na.Node.L >= 0 && total > mc.PerNodeBudget {
			return fmt.Errorf("node %s: %.1f GB exceeds 128 GB budget",
				na.Node, float64(total)/1e9)
		}
	}

	return nil
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
		routeBitmap := ((nid.L + 1) << 7) | (nid.Y << 0) // layer + Y dist
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

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
