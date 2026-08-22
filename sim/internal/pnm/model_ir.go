// Model-to-IR compiler: lowers a HuggingFace model (config + safetensors
// index) into a chassis-independent intermediate representation, which is then
// populated onto a concrete chassis schema by PopulateSchema.
package pnm

import (
	"fmt"
	"math"
	"sort"
	"strings"
)

// ModelOp is one chassis-independent operation lowered from the model.
type ModelOp struct {
	ModelLayer int // model layer index, -1 for model-global ops
	Role       string
	ExpertIdx  int // -1 if not expert-specific
	CUType     ComputeUnitType
	DType      string
	SizeBytes  int64
}

// ModelIR is the chassis-independent intermediate representation of a model:
// what the model is, not where it lands on a chassis.
type ModelIR struct {
	Config     *ModelConfig
	Index      *SafetensorsIndex
	Tensors    map[string]*TensorMeta
	TotalBytes int64
	Ops        []ModelOp
}

// CompileModelIR ingests a model config + safetensors index and lowers it to
// the chassis-independent ModelIR. No chassis dimensions are involved.
func CompileModelIR(cfg *ModelConfig, idx *SafetensorsIndex) (*ModelIR, error) {
	if cfg == nil {
		return nil, fmt.Errorf("nil model config")
	}
	if idx == nil {
		return nil, fmt.Errorf("nil safetensors index")
	}
	tensors, totalBytes := CollectTensors(idx, cfg)
	ir := &ModelIR{
		Config:     cfg,
		Index:      idx,
		Tensors:    tensors,
		TotalBytes: totalBytes,
	}
	tc := &cfg.TextConfig

	h := int64(tc.HiddenSize)
	kvDim := int64(tc.NumKeyValueHeads * tc.HeadDim)
	inter := int64(tc.IntermediateSize)
	moeInter := int64(tc.MoEIntermediateSize)

	for ml := 0; ml < tc.NumHiddenLayers; ml++ {
		ir.Ops = append(ir.Ops,
			ModelOp{ModelLayer: ml, Role: "attn_q", ExpertIdx: -1, CUType: CUTypeBF16Array, DType: "BF16", SizeBytes: h * h * 2},
			ModelOp{ModelLayer: ml, Role: "attn_k", ExpertIdx: -1, CUType: CUTypeBF16Array, DType: "BF16", SizeBytes: kvDim * h * 2},
			ModelOp{ModelLayer: ml, Role: "attn_v", ExpertIdx: -1, CUType: CUTypeBF16Array, DType: "BF16", SizeBytes: kvDim * h * 2},
			ModelOp{ModelLayer: ml, Role: "attn_o", ExpertIdx: -1, CUType: CUTypeBF16Array, DType: "BF16", SizeBytes: h * h * 2},
			ModelOp{ModelLayer: ml, Role: "dense_gate", ExpertIdx: -1, CUType: CUTypeBF16FMA, DType: "BF16", SizeBytes: inter * h * 2},
			ModelOp{ModelLayer: ml, Role: "dense_up", ExpertIdx: -1, CUType: CUTypeBF16FMA, DType: "BF16", SizeBytes: inter * h * 2},
			ModelOp{ModelLayer: ml, Role: "dense_down", ExpertIdx: -1, CUType: CUTypeBF16FMA, DType: "BF16", SizeBytes: inter * h * 2},
			ModelOp{ModelLayer: ml, Role: "input_layernorm", ExpertIdx: -1, CUType: CUTypeFP32ALU, DType: "FP32", SizeBytes: h * 2},
			ModelOp{ModelLayer: ml, Role: "post_attention_layernorm", ExpertIdx: -1, CUType: CUTypeFP32ALU, DType: "FP32", SizeBytes: h * 2},
			ModelOp{ModelLayer: ml, Role: "router_weights", ExpertIdx: -1, CUType: CUTypeBF16FMA, DType: "BF16", SizeBytes: int64(tc.NumExperts) * h * 2},
		)
		for e := 0; e < tc.NumExperts; e++ {
			ir.Ops = append(ir.Ops,
				ModelOp{ModelLayer: ml, Role: "expert_gate_up", ExpertIdx: e, CUType: CUTypeBF16FMA, DType: "BF16", SizeBytes: 2 * moeInter * h * 2},
				ModelOp{ModelLayer: ml, Role: "expert_down", ExpertIdx: e, CUType: CUTypeBF16FMA, DType: "BF16", SizeBytes: moeInter * h * 2},
			)
		}
	}

	ir.Ops = append(ir.Ops,
		ModelOp{ModelLayer: -1, Role: "embedding", ExpertIdx: -1, CUType: CUTypeBF16FMA, DType: "BF16", SizeBytes: int64(tc.VocabSize) * h * 2},
		ModelOp{ModelLayer: -1, Role: "final_norm", ExpertIdx: -1, CUType: CUTypeFP32ALU, DType: "FP32", SizeBytes: h * 2},
	)

	return ir, nil
}

// Emit returns the IR as a textual listing, aggregated per model layer.
func (ir *ModelIR) Emit() string {
	var b strings.Builder
	tc := &ir.Config.TextConfig
	b.WriteString("# Model IR\n")
	b.WriteString(fmt.Sprintf("# %d layers, hidden=%d, experts=%d, active=%d, vocab=%d\n",
		tc.NumHiddenLayers, tc.HiddenSize, tc.NumExperts, tc.TopKExperts, tc.VocabSize))
	var opBytes int64
	for _, op := range ir.Ops {
		opBytes += op.SizeBytes
	}
	b.WriteString(fmt.Sprintf("# %d ops, %.1f GB in ops (%.1f GB weights indexed)\n\n",
		len(ir.Ops), float64(opBytes)/1e9, float64(ir.TotalBytes)/1e9))

	type aggEntry struct {
		count   int
		bytes   int64
		cu      ComputeUnitType
		dtype   string
		experts int
	}
	agg := map[int]map[string]*aggEntry{}
	for _, op := range ir.Ops {
		m := agg[op.ModelLayer]
		if m == nil {
			m = map[string]*aggEntry{}
			agg[op.ModelLayer] = m
		}
		e := m[op.Role]
		if e == nil {
			e = &aggEntry{cu: op.CUType, dtype: op.DType}
			m[op.Role] = e
		}
		e.count++
		e.bytes += op.SizeBytes
		if op.ExpertIdx >= 0 {
			e.experts++
		}
	}

	layers := make([]int, 0, len(agg))
	for ml := range agg {
		layers = append(layers, ml)
	}
	sort.Ints(layers)
	for _, ml := range layers {
		if ml < 0 {
			b.WriteString("global:\n")
		} else {
			b.WriteString(fmt.Sprintf("layer %d:\n", ml))
		}
		roles := make([]string, 0, len(agg[ml]))
		for role := range agg[ml] {
			roles = append(roles, role)
		}
		sort.Strings(roles)
		for _, role := range roles {
			e := agg[ml][role]
			line := fmt.Sprintf("  %-26s x%-4d %12.1f MB  %s/%s",
				role, e.count, float64(e.bytes)/1e6, e.cu, e.dtype)
			if e.experts > 0 {
				line += fmt.Sprintf(" (%d experts)", e.experts)
			}
			b.WriteString(line + "\n")
		}
	}
	return b.String()
}

// PopulateSchema places the IR onto a concrete chassis, producing the
// populated schema (node assignments, KV reservation, budget enforcement).
func (ir *ModelIR) PopulateSchema(dims Dims) (*ModelCompiler, error) {
	cfg := ir.Config
	tc := &cfg.TextConfig
	mc := &ModelCompiler{
		Config:          cfg,
		Index:           ir.Index,
		Tensors:         ir.Tensors,
		Dims:            dims,
		TotalBytes:      ir.TotalBytes,
		NodeBudget:      int64(dims.Layers*dims.Bx*dims.By) * 128 * 1024 * 1024 * 1024,
		PerNodeBudget:   128 * 1024 * 1024 * 1024,
		NodeAssignments: make(map[NodeID]*NodeAssignment),
		IR:              ir,
	}

	getNode := func(nid NodeID) *NodeAssignment {
		na, ok := mc.NodeAssignments[nid]
		if !ok {
			na = &NodeAssignment{
				Node:    nid,
				Layers:  []int{},
				Kernels: make(map[int]string),
				Tensors: []TensorRef{},
			}
			mc.NodeAssignments[nid] = na
		}
		return na
	}

	for l := 0; l < dims.Layers; l++ {
		for x := 0; x < dims.Bx; x++ {
			for y := 0; y < dims.By; y++ {
				getNode(NodeID{L: l, X: x, Y: y})
			}
		}
	}

	nodesPerLayer := dims.Bx * dims.By
	modelLayersPerPhysical := int(math.Ceil(float64(tc.NumHiddenLayers) / float64(dims.Layers)))
	physLayerOf := func(ml int) int { return ml / modelLayersPerPhysical }

	routerNID := NodeID{L: -1, X: -1, Y: -1}

	tensorName := func(op ModelOp) string {
		switch op.Role {
		case "expert_gate_up":
			return fmt.Sprintf("layers.%d.experts.gate_up_proj", op.ModelLayer)
		case "expert_down":
			return fmt.Sprintf("layers.%d.experts.down_proj", op.ModelLayer)
		case "attn_q":
			return fmt.Sprintf("layers.%d.self_attn.q_proj", op.ModelLayer)
		case "attn_k":
			return fmt.Sprintf("layers.%d.self_attn.k_proj", op.ModelLayer)
		case "attn_v":
			return fmt.Sprintf("layers.%d.self_attn.v_proj", op.ModelLayer)
		case "attn_o":
			return fmt.Sprintf("layers.%d.self_attn.o_proj", op.ModelLayer)
		case "dense_gate":
			return fmt.Sprintf("layers.%d.mlp.gate_proj", op.ModelLayer)
		case "dense_up":
			return fmt.Sprintf("layers.%d.mlp.up_proj", op.ModelLayer)
		case "dense_down":
			return fmt.Sprintf("layers.%d.mlp.down_proj", op.ModelLayer)
		case "input_layernorm":
			return fmt.Sprintf("layers.%d.input_layernorm", op.ModelLayer)
		case "post_attention_layernorm":
			return fmt.Sprintf("layers.%d.post_attention_layernorm", op.ModelLayer)
		case "router_weights":
			return fmt.Sprintf("layers.%d.router.proj", op.ModelLayer)
		default:
			return op.Role
		}
	}

	place := func(nid NodeID, op ModelOp) {
		na := getNode(nid)
		if op.ModelLayer >= 0 && (len(na.Layers) == 0 || na.Layers[len(na.Layers)-1] != op.ModelLayer) {
			na.Layers = append(na.Layers, op.ModelLayer)
		}
		na.Tensors = append(na.Tensors, TensorRef{
			Name:       tensorName(op),
			Role:       op.Role,
			ModelLayer: op.ModelLayer,
			ExpertIdx:  op.ExpertIdx,
			SizeBytes:  op.SizeBytes,
			CUType:     op.CUType,
			DType:      op.DType,
		})
	}

	nodesLayer0 := dims.Bx * dims.By
	if nodesLayer0 < 1 {
		nodesLayer0 = 1
	}
	rowsPerNode := tc.VocabSize / nodesLayer0
	extraRows := tc.VocabSize % nodesLayer0
	shardEmbedded := false

	for _, op := range ir.Ops {
		switch {
		case op.Role == "router_weights":
			place(routerNID, op)
		case op.Role == "embedding":
			if shardEmbedded {
				continue
			}
			shardEmbedded = true
			for n := 0; n < nodesLayer0; n++ {
				rows := rowsPerNode
				if n < extraRows {
					rows++
				}
				na := getNode(NodeID{L: 0, X: n / dims.By, Y: n % dims.By})
				na.Tensors = append(na.Tensors, TensorRef{
					Name:       fmt.Sprintf("embed_tokens.shard_%d", n),
					Role:       "embedding",
					ModelLayer: -1,
					SizeBytes:  int64(rows*tc.HiddenSize) * 2,
					CUType:     op.CUType,
					DType:      op.DType,
				})
			}
		case op.Role == "final_norm":
			normNodeIdx := tc.NumHiddenLayers % nodesLayer0
			place(NodeID{L: 0, X: normNodeIdx / dims.By, Y: normNodeIdx % dims.By}, op)
		case strings.HasPrefix(op.Role, "expert_"):
			nodeIdx := op.ExpertIdx % nodesPerLayer
			place(NodeID{L: physLayerOf(op.ModelLayer), X: nodeIdx / dims.By, Y: nodeIdx % dims.By}, op)
		default:
			attnNodeIdx := op.ModelLayer % nodesPerLayer
			place(NodeID{L: physLayerOf(op.ModelLayer), X: attnNodeIdx / dims.By, Y: attnNodeIdx % dims.By}, op)
		}
	}

	// Reserve KV cache memory on attention nodes (chassis-dependent policy):
	// 80% of the remaining per-node budget, capped at 16K entries.
	kvEntryBytes := int64(tc.HiddenSize) * 4
	for nid, na := range mc.NodeAssignments {
		if nid.L < 0 || len(na.Tensors) == 0 {
			continue
		}
		hasAttn := false
		var usedBytes int64
		for _, t := range na.Tensors {
			if t.Role == "attn_q" {
				hasAttn = true
			}
			usedBytes += t.SizeBytes
		}
		if !hasAttn {
			continue
		}
		remaining := mc.PerNodeBudget - usedBytes
		if remaining < 0 {
			remaining = 0
		}
		kvBudgetPerNode := int64(float64(remaining) * 0.80)
		kvEntriesPerNode := kvBudgetPerNode / kvEntryBytes
		if kvEntriesPerNode > 16384 {
			kvEntriesPerNode = 16384
		}
		na.Tensors = append(na.Tensors, TensorRef{
			Name:       fmt.Sprintf("kv_cache.l%d", nid.L),
			Role:       "kv_cache",
			ModelLayer: -1,
			SizeBytes:  kvEntriesPerNode * kvEntryBytes,
		})
	}

	for _, na := range mc.NodeAssignments {
		var total int64
		cuSet := map[ComputeUnitType]bool{}
		for _, t := range na.Tensors {
			total += t.SizeBytes
			if t.CUType != CUTypeNone {
				cuSet[t.CUType] = true
			}
		}
		na.TotalBytes = total

		if total > 0 {
			na.Kernels[-1] = "dot"
		}

		if na.Node.L >= 0 {
			cus := make([]ComputeUnitType, 0, len(cuSet))
			for cu := range cuSet {
				cus = append(cus, cu)
			}
			sort.Slice(cus, func(i, j int) bool { return cus[i] < cus[j] })
			na.ComputeUnits = cus
		}

		if na.Node.L >= 0 && total > mc.PerNodeBudget {
			return nil, fmt.Errorf("node %s: %.1f GB exceeds 128 GB budget",
				na.Node, float64(total)/1e9)
		}
	}

	return mc, nil
}
