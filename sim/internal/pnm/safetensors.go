package pnm

import (
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
