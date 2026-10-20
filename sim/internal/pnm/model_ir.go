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

// WeightFormat selects the on-disk encoding the compiler lowers weight ops to.
// WeightsBF16 is the reference; WeightsTernary is BitNet b1.58 (2-bit codes
// {+1,0,-1} packed four per byte), lowered to CUTypeTernaryAcc ops so the node
// streams ~1/10 the weight bytes (Paper §3.6).
type WeightFormat int

const (
	WeightsBF16 WeightFormat = iota
	WeightsTernary
)

// CompileOption customizes lowering.
type CompileOption func(*compileSettings)

type compileSettings struct {
	weightFormat WeightFormat
}

// WithWeightFormat lowers weight ops to the given format (default BF16).
func WithWeightFormat(f WeightFormat) CompileOption {
	return func(s *compileSettings) { s.weightFormat = f }
}

// TernaryBytes is the packed size of n ternary weights (2 bits each, 4/byte).
func TernaryBytes(n int64) int64 { return (n*2 + 7) / 8 }

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
func CompileModelIR(cfg *ModelConfig, idx *SafetensorsIndex, opts ...CompileOption) (*ModelIR, error) {
	if cfg == nil {
		return nil, fmt.Errorf("nil model config")
	}
	if idx == nil {
		return nil, fmt.Errorf("nil safetensors index")
	}
	var settings compileSettings
	for _, o := range opts {
		o(&settings)
	}
	// weightOp lowers one weight-bearing op; ternary re-tags it to the select-add
	// accumulator and 2-bit packing, norms/layernorms stay BF16 (never quantized).
	weightOp := func(ml int, role string, exp int, cu ComputeUnitType, numel int64) ModelOp {
		if settings.weightFormat == WeightsTernary {
			return ModelOp{ModelLayer: ml, Role: role, ExpertIdx: exp,
				CUType: CUTypeTernaryAcc, DType: "TERNARY", SizeBytes: TernaryBytes(numel)}
		}
		return ModelOp{ModelLayer: ml, Role: role, ExpertIdx: exp,
			CUType: cu, DType: "BF16", SizeBytes: numel * 2}
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
			weightOp(ml, "attn_q", -1, CUTypeBF16Array, h*h),
			weightOp(ml, "attn_k", -1, CUTypeBF16Array, kvDim*h),
			weightOp(ml, "attn_v", -1, CUTypeBF16Array, kvDim*h),
			weightOp(ml, "attn_o", -1, CUTypeBF16Array, h*h),
			weightOp(ml, "dense_gate", -1, CUTypeBF16FMA, inter*h),
			weightOp(ml, "dense_up", -1, CUTypeBF16FMA, inter*h),
			weightOp(ml, "dense_down", -1, CUTypeBF16FMA, inter*h),
			ModelOp{ModelLayer: ml, Role: "input_layernorm", ExpertIdx: -1, CUType: CUTypeFP32ALU, DType: "BF16", SizeBytes: h * 2},
			ModelOp{ModelLayer: ml, Role: "post_attention_layernorm", ExpertIdx: -1, CUType: CUTypeFP32ALU, DType: "BF16", SizeBytes: h * 2},
			weightOp(ml, "orchestrator_weights", -1, CUTypeBF16FMA, int64(tc.NumExperts)*h),
		)
		for e := 0; e < tc.NumExperts; e++ {
			ir.Ops = append(ir.Ops,
				weightOp(ml, "expert_gate_up", e, CUTypeBF16FMA, 2*moeInter*h),
				weightOp(ml, "expert_down", e, CUTypeBF16FMA, moeInter*h),
			)
		}
	}

	ir.Ops = append(ir.Ops,
		weightOp(-1, "embedding", -1, CUTypeBF16FMA, int64(tc.VocabSize)*h),
		ModelOp{ModelLayer: -1, Role: "final_norm", ExpertIdx: -1, CUType: CUTypeFP32ALU, DType: "BF16", SizeBytes: h * 2},
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

	orchestratorNID := NodeID{L: -1, X: -1, Y: -1}

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
		case "orchestrator_weights":
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
		case op.Role == "orchestrator_weights":
			place(orchestratorNID, op)
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
	// Per-entry bytes are pinned to the RTL/co-sim frame (kv_cache_bank
	// ENTRY_BYTES=512, DefaultKVCacheConfig, PNM_KV_ENTRY_BYTES in the C
	// twin).  A hiddenSize-derived frame (2*K+V*hidden*2) only coincides
	// with silicon at hidden 128 and would silently inflate the schema's
	// entry count beyond what the frame can hold.
	kvEntryBytes := int64(512)
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
