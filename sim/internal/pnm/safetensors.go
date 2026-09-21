package pnm

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// TensorMeta describes one tensor in a safetensors archive.
type TensorMeta struct {
	Name   string   `json:"-"`
	File   string   `json:"-"`
	DType  string   `json:"dtype"`
	Shape  []int    `json:"shape"`
	Offset [2]int64 `json:"data_offsets"`
}

// SafetensorsIndex is the parsed model.safetensors.index.json.
type SafetensorsIndex struct {
	WeightMap map[string]string `json:"weight_map"`
}

// ModelConfig holds the fields we need from config.json.
type ModelConfig struct {
	TextConfig struct {
		HiddenSize          int      `json:"hidden_size"`
		IntermediateSize    int      `json:"intermediate_size"`
		MoEIntermediateSize int     `json:"moe_intermediate_size"`
		NumHiddenLayers     int      `json:"num_hidden_layers"`
		NumAttentionHeads   int      `json:"num_attention_heads"`
		NumKeyValueHeads    int     `json:"num_key_value_heads"`
		NumGlobalKVHeads    int     `json:"num_global_key_value_heads"`
		VocabSize           int      `json:"vocab_size"`
		NumExperts          int     `json:"num_experts"`
		TopKExperts         int     `json:"top_k_experts"`
		HeadDim             int     `json:"head_dim"`
		GlobalHeadDim       int     `json:"global_head_dim"`
		SlidingWindow       int     `json:"sliding_window"`
		LayerTypes          []string `json:"layer_types"`
		TieWordEmbeddings   bool     `json:"tie_word_embeddings"`
	} `json:"text_config"`
	TieWordEmbeddings bool `json:"tie_word_embeddings"`
}

// TensorShapeFor returns the parameter count for a known tensor name,
// using the model config to compute shapes that the index file doesn't store.
func TensorShapeFor(name string, cfg *ModelConfig) (params int64, shape []int, dtype string) {
	dtype = "BF16"
	tc := &cfg.TextConfig
	_ = tc

	// Global tensors
	if strings.HasSuffix(name, "embed_tokens.weight") {
		return int64(tc.VocabSize) * int64(tc.HiddenSize),
			[]int{tc.VocabSize, tc.HiddenSize}, dtype
	}
	if strings.HasSuffix(name, "norm.weight") && !strings.Contains(name, "layernorm") {
		return int64(tc.HiddenSize), []int{tc.HiddenSize}, dtype
	}

	// Per-layer tensors
	if !strings.Contains(name, "layers.") {
		return 0, nil, "unknown"
	}

	// Parse layer index
	after := name[strings.Index(name, "layers.")+7:]
	dot := strings.Index(after, ".")
	if dot < 0 {
		return 0, nil, "unknown"
	}
	_ = after[:dot] // layer index (we compute shapes generically)

	switch {
	case strings.HasSuffix(name, "input_layernorm.weight"),
		strings.HasSuffix(name, "post_attention_layernorm.weight"),
		strings.HasSuffix(name, "post_feedforward_layernorm.weight"),
		strings.HasSuffix(name, "post_feedforward_layernorm_1.weight"),
		strings.HasSuffix(name, "post_feedforward_layernorm_2.weight"),
		strings.HasSuffix(name, "pre_feedforward_layernorm.weight"),
		strings.HasSuffix(name, "pre_feedforward_layernorm_2.weight"),
		strings.HasSuffix(name, "q_norm.weight"),
		strings.HasSuffix(name, "k_norm.weight"):
		return int64(tc.HiddenSize), []int{tc.HiddenSize}, dtype

	case strings.HasSuffix(name, "layer_scalar"):
		return 1, []int{1}, dtype

	case strings.HasSuffix(name, "self_attn.q_proj.weight"),
		strings.HasSuffix(name, "self_attn.o_proj.weight"):
		return int64(tc.HiddenSize) * int64(tc.HiddenSize),
			[]int{tc.HiddenSize, tc.HiddenSize}, dtype

	case strings.HasSuffix(name, "self_attn.k_proj.weight"):
		return int64(tc.NumKeyValueHeads*tc.HeadDim) * int64(tc.HiddenSize),
			[]int{tc.NumKeyValueHeads * tc.HeadDim, tc.HiddenSize}, dtype

	case strings.HasSuffix(name, "self_attn.v_proj.weight"):
		return int64(tc.NumKeyValueHeads*tc.HeadDim) * int64(tc.HiddenSize),
			[]int{tc.NumKeyValueHeads * tc.HeadDim, tc.HiddenSize}, dtype

	case strings.HasSuffix(name, "mlp.gate_proj.weight"),
		strings.HasSuffix(name, "mlp.up_proj.weight"):
		return int64(tc.IntermediateSize) * int64(tc.HiddenSize),
			[]int{tc.IntermediateSize, tc.HiddenSize}, dtype

	case strings.HasSuffix(name, "mlp.down_proj.weight"):
		return int64(tc.HiddenSize) * int64(tc.IntermediateSize),
			[]int{tc.HiddenSize, tc.IntermediateSize}, dtype

	case strings.Contains(name, "experts.gate_up_proj"):
		// Each index entry (weight_0, weight_1, ...) is one expert shard
		return int64(2*tc.MoEIntermediateSize) * int64(tc.HiddenSize),
			[]int{2 * tc.MoEIntermediateSize, tc.HiddenSize}, dtype

	case strings.Contains(name, "experts.down_proj"):
		return int64(tc.HiddenSize) * int64(tc.MoEIntermediateSize),
			[]int{tc.HiddenSize, tc.MoEIntermediateSize}, dtype

	case strings.HasSuffix(name, "router.proj.weight"):
		return int64(tc.NumExperts) * int64(tc.HiddenSize),
			[]int{tc.NumExperts, tc.HiddenSize}, dtype

	case strings.HasSuffix(name, "router.scale"):
		return int64(tc.NumExperts), []int{tc.NumExperts}, dtype

	case strings.HasSuffix(name, "router.per_expert_scale"):
		return int64(tc.NumExperts), []int{tc.NumExperts}, dtype
	}

	return 0, nil, "unknown"
}

// BF16SizeBytes returns the byte size for a tensor with the given param count.
func BF16SizeBytes(params int64) int64 {
	return params * 2
}

// LoadSafetensorsIndex reads and parses model.safetensors.index.json from a
// directory that contains it (the HuggingFace cache or a local download).
func LoadSafetensorsIndex(dir string) (*SafetensorsIndex, error) {
	path := filepath.Join(dir, "model.safetensors.index.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading index: %w", err)
	}
	var idx SafetensorsIndex
	if err := json.Unmarshal(data, &idx); err != nil {
		return nil, fmt.Errorf("parsing index: %w", err)
	}
	return &idx, nil
}

// safetensorsFileHeader is the parsed header block of one .safetensors shard:
// the JSON metadata plus the byte offsets of every tensor in that shard.
type safetensorsFileHeader struct {
	Metadata map[string]string                      `json:"__metadata__"`
	Tensors  map[string]safetensorsTensorDescriptor `json:"-"`
}

// safetensorsTensorDescriptor gives the location and shape of one tensor
// within its shard (offset/size are in absolute file bytes).
type safetensorsTensorDescriptor struct {
	ShardFile string  `json:"-"`
	Offset    int64   `json:"-"`
	Size      int64   `json:"-"`
	DType     string  `json:"dtype"`
	Shape     []int64 `json:"shape"`
}

// ParseSafetensorsHeaders scans every shard referenced by the index and
// returns a tensor-descriptor catalog with per-tensor byte offsets.  This
// is what lets the co-sim pull REAL weight bytes out of a downloaded
// checkpoint instead of synthesizing them.
func ParseSafetensorsHeaders(dir string, idx *SafetensorsIndex) (map[string]*safetensorsTensorDescriptor, error) {
	// Collect the distinct shard files the index references.
	shards := map[string]bool{}
	for _, shard := range idx.WeightMap {
		shards[shard] = true
	}

	desc := map[string]*safetensorsTensorDescriptor{}
	var anyErr error
	for shard := range shards {
		path := filepath.Join(dir, shard)
		f, err := os.Open(path)
		if err != nil {
			anyErr = err
			continue // shard missing; caller decides (synthetic fallback)
		}
		func() {
			defer f.Close()
			hdr, err := readSafetensorsHeader(f)
			if err != nil {
				anyErr = err
				return
			}
			for name, spec := range hdr.Tensors {
				if want, ok := idx.WeightMap[name]; ok && want == shard {
					desc[name] = &safetensorsTensorDescriptor{
										ShardFile: shard,
										Offset:    spec.Offset,
										Size:      spec.Size,
										DType:     spec.DType,
										Shape:     spec.Shape,
									}
				}
			}
		}()
	}
	return desc, anyErr
}

// readSafetensorsHeader parses the 8-byte length-prefixed JSON header at the
// start of a .safetensors shard, returning tensor name -> {offset, size, dtype, shape}.
func readSafetensorsHeader(f *os.File) (*safetensorsFileHeader, error) {
	var lenBuf [8]byte
	if _, err := f.ReadAt(lenBuf[:], 0); err != nil {
		return nil, fmt.Errorf("reading shard header length: %w", err)
	}
	hdrLen := int64(binary.LittleEndian.Uint64(lenBuf[:]))
	if hdrLen <= 0 || hdrLen > 64<<20 {
		return nil, fmt.Errorf("implausible safetensors header length %d", hdrLen)
	}
	hdrJSON := make([]byte, hdrLen)
	if _, err := f.ReadAt(hdrJSON, 8); err != nil {
		return nil, fmt.Errorf("reading shard header: %w", err)
	}
	// data_offsets is per-tensor; decode raw so offsets stay exact.
	var rawT map[string]json.RawMessage
	if err := json.Unmarshal(hdrJSON, &rawT); err != nil {
		return nil, fmt.Errorf("parsing shard header JSON: %w", err)
	}
	hdr := &safetensorsFileHeader{
		Tensors: map[string]safetensorsTensorDescriptor{},
	}
	for name, rawSpec := range rawT {
		if name == "__metadata__" {
			continue
		}
		var spec struct {
			DType       string  `json:"dtype"`
			Shape       []int64 `json:"shape"`
			DataOffsets []int64 `json:"data_offsets"`
		}
		if err := json.Unmarshal(rawSpec, &spec); err != nil {
			continue
		}
		off := int64(0)
		if len(spec.DataOffsets) > 0 {
			off = spec.DataOffsets[0]
		}
		sz := int64(0)
		if len(spec.DataOffsets) > 1 {
			sz = spec.DataOffsets[1] - spec.DataOffsets[0]
		}
		hdr.Tensors[name] = safetensorsTensorDescriptor{
			Offset: 8 + hdrLen + off,
			Size:   sz,
			DType:  spec.DType,
			Shape:  spec.Shape,
		}
	}
	return hdr, nil
}

// ReadRealTensorBytes loads one tensor's raw bytes from its shard, following
// the descriptor catalog produced by ParseSafetensorsHeaders.
func ReadRealTensorBytes(dir string, desc *safetensorsTensorDescriptor) []byte {
	if desc == nil || desc.ShardFile == "" {
		return nil
	}
	path := filepath.Join(dir, desc.ShardFile)
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	buf := make([]byte, desc.Size)
	if _, err := f.ReadAt(buf, desc.Offset); err != nil {
		return nil
	}
	return buf
}

// ReadRealTensorRowRange reads only rows [r0, r1) of a [rows, cols] BF16
// tensor straight from the shard file (avoids materializing huge multi-GB
// expert matrices when only the top-k are dispatched).
func ReadRealTensorRowRange(dir string, desc *safetensorsTensorDescriptor, rows, cols, r0, r1 int) []byte {
	if desc == nil || desc.ShardFile == "" || r1 <= r0 {
		return nil
	}
	path := filepath.Join(dir, desc.ShardFile)
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	n := (r1 - r0) * cols
	buf := make([]byte, n*2)
	start := desc.Offset + int64(r0)*int64(cols)*2
	if _, err := f.ReadAt(buf, start); err != nil {
		return nil
	}
	return buf
}

// numElements returns the product of a tensor shape (0 for degenerate).
func numElements(shape []int64) int64 {
	n := int64(1)
	for _, d := range shape {
		if d <= 0 {
			return 0
		}
		n *= d
	}
	return n
}

// LoadModelConfig reads and parses config.json from a directory.
func LoadModelConfig(dir string) (*ModelConfig, error) {
	path := filepath.Join(dir, "config.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading config: %w", err)
	}
	var cfg ModelConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parsing config: %w", err)
	}
	return &cfg, nil
}

// CollectTensors merges the index and config to produce a full tensor catalog
// with computed shapes and sizes (since safetensors index files don't store shapes).
func CollectTensors(idx *SafetensorsIndex, cfg *ModelConfig) (map[string]*TensorMeta, int64) {
	tensors := make(map[string]*TensorMeta)
	var totalBytes int64

	for name, file := range idx.WeightMap {
		params, shape, dtype := TensorShapeFor(name, cfg)
		if params == 0 {
			// Vision tower or unknown tensor -- use a placeholder size
			params = 1000 // conservative placeholder
			dtype = "BF16"
		}
		sizeBytes := BF16SizeBytes(params)
		tensors[name] = &TensorMeta{
			Name:  name,
			File:  file,
			DType: dtype,
			Shape: shape,
		}
		totalBytes += sizeBytes
	}
	return tensors, totalBytes
}
