package pnm

import (
	"fmt"
	"math"
	"sort"
	"strings"
)

// ============================================================================
// LLM Inference Client for the PNM Architecture
//
// The LLMClient orchestrates token-by-token autoregressive inference across
// the PNM fabric.  It supports FP16 and BF16 weight formats, dispatches
// through the MoE gating network, and manages the KV cache for long-context
// generation.
//
// Usage:
//
//	client, err := pnm.NewLLMClient(LLMConfig{
//	    ModelDir:  "/path/to/model",
//	    Dims:      pnm.Dims{Layers: 4, Bx: 4, By: 4},
//	    MaxTokens: 2048,
//	    DataType:  pnm.CUTypeBF16FMA,
//	})
//	tokens, err := client.Generate("Hello, world!")
// ============================================================================

// LLMConfig configures the LLM inference client.
type LLMConfig struct {
	ModelDir   string          // path to model directory (config.json + safetensors)
	Dims       Dims            // chassis dimensions
	MaxTokens  int             // max generation length
	Temperature float32        // sampling temperature (0 = greedy)
	TopP       float32         // nucleus sampling threshold
	DataType   ComputeUnitType // CUTypeBF16FMA or CUTypeFP16FMA
}

// LLMClient is the host-side inference client for LLM models on PNM.
type LLMClient struct {
	Config  LLMConfig
	Driver  *Driver
	FW      *Firmware
	Vocab   *Vocabulary
	Stats   InferenceStats
}

// InferenceStats tracks inference performance metrics.
type InferenceStats struct {
	TokensGenerated int
	PrefillTokens   int
	TotalLayers     int
	TotalDispatches int
	TotalFlits      int
	MoEDispatches   int
	DenseDispatches int
	KVStoreOps      int
	KVLoadOps       int
	KVEvictions     int
}

// Vocabulary maps token IDs to strings and vice versa.
// For co-simulation, this is a simplified BPE tokenizer.
type Vocabulary struct {
	TokenToID map[string]int
	IDToToken map[int]string
	Size      int
}

// NewVocabulary creates a vocabulary from a token list.
func NewVocabulary(tokens []string) *Vocabulary {
	v := &Vocabulary{
		TokenToID: make(map[string]int),
		IDToToken: make(map[int]string),
		Size:      len(tokens),
	}
	for i, tok := range tokens {
		v.TokenToID[tok] = i
		v.IDToToken[i] = tok
	}
	return v
}

// Encode converts text to token IDs (simplified whitespace tokenization).
func (v *Vocabulary) Encode(text string) []int {
	words := strings.Fields(text)
	ids := make([]int, len(words))
	for i, w := range words {
		if id, ok := v.TokenToID[w]; ok {
			ids[i] = id
		} else {
			// Unknown token: use a hash-based fallback
			ids[i] = simpleHash(w) % v.Size
		}
	}
	return ids
}

// Decode converts token IDs back to text.
func (v *Vocabulary) Decode(ids []int) string {
	var sb strings.Builder
	for i, id := range ids {
		if i > 0 {
			sb.WriteByte(' ')
		}
		if tok, ok := v.IDToToken[id]; ok {
			sb.WriteString(tok)
		} else {
			sb.WriteString(fmt.Sprintf("<%d>", id))
		}
	}
	return sb.String()
}

// simpleHash is a deterministic hash for unknown tokens.
func simpleHash(s string) int {
	h := 0
	for _, c := range s {
		h = h*31 + int(c)
	}
	if h < 0 {
		h = -h
	}
	return h
}

// NewLLMClient creates a new LLM inference client.
func NewLLMClient(cfg LLMConfig) (*LLMClient, error) {
	if cfg.MaxTokens == 0 {
		cfg.MaxTokens = 2048
	}
	// Temperature=0 is valid for greedy decoding (argmax)
	if cfg.TopP == 0 {
		cfg.TopP = 0.9
	}
	if cfg.DataType == CUTypeNone {
		cfg.DataType = CUTypeBF16FMA
	}

	drv, err := NewDriver(DriverConfig{ModelDir: cfg.ModelDir, Dims: cfg.Dims})
	if err != nil {
		return nil, fmt.Errorf("llm client: driver init: %w", err)
	}

	// Build a simple vocabulary from the model config
	tc := &drv.Config.TextConfig
	tokens := make([]string, tc.VocabSize)
	for i := 0; i < tc.VocabSize && i < len(tokens); i++ {
		tokens[i] = fmt.Sprintf("token_%d", i)
	}

	// Boot firmware
	fw := drv.FW
	for fw.State != FWStateReady {
		if _, err := fw.BootPhase(); err != nil {
			return nil, fmt.Errorf("llm client: boot phase %d: %w", fw.State, err)
		}
	}

	return &LLMClient{
		Config: cfg,
		Driver: drv,
		FW:     fw,
		Vocab:  NewVocabulary(tokens),
	}, nil
}

// Generate produces tokens autoregressively from a prompt.
func (c *LLMClient) Generate(prompt string) ([]int, error) {
	promptIDs := c.Vocab.Encode(prompt)
	if len(promptIDs) == 0 {
		return nil, fmt.Errorf("llm client: empty prompt")
	}

	c.Stats.PrefillTokens = len(promptIDs)

	// Prefill phase: process all prompt tokens
	for _, id := range promptIDs {
		tokenBytes := encodeTokenID(id, c.Config.DataType)
		if _, err := c.FW.PlanInference(tokenBytes); err != nil {
			return nil, fmt.Errorf("llm client: prefill: %w", err)
		}
		c.Stats.TotalLayers++
	}

	// Generation phase: produce tokens one at a time
	generated := make([]int, 0, c.Config.MaxTokens)
	for len(generated) < c.Config.MaxTokens {
		// Use last generated token (or last prompt token for first step)
		var lastToken int
		if len(generated) > 0 {
			lastToken = generated[len(generated)-1]
		} else {
			lastToken = promptIDs[len(promptIDs)-1]
		}

		tokenBytes := encodeTokenID(lastToken, c.Config.DataType)
		records, err := c.FW.PlanInference(tokenBytes)
		if err != nil {
			return nil, fmt.Errorf("llm client: generate step %d: %w", len(generated), err)
		}

		// Collect stats
		c.Stats.TotalDispatches += len(records)
		c.Stats.TotalFlits += len(records) // approximate
		for _, r := range records {
			switch r.Phase {
			case "moe":
				c.Stats.MoEDispatches++
			case "dense":
				c.Stats.DenseDispatches++
			case "kv_offload":
				c.Stats.KVEvictions++
			}
			if r.KVAction == "store" {
				c.Stats.KVStoreOps++
			} else if r.KVAction == "load" {
				c.Stats.KVLoadOps++
			}
		}

		// In a real system, the result would come back from the fabric.
		// For co-simulation, we generate a deterministic next token.
		nextToken := c.predictNextToken(lastToken, len(generated))
		generated = append(generated, nextToken)
		c.Stats.TokensGenerated++

		// Stop on EOS token (convention: token 2)
		if nextToken == 2 {
			break
		}
	}

	return generated, nil
}

// predictNextToken produces a deterministic next-token prediction.
// In production, this would read the output from the MoE fabric.
func (c *LLMClient) predictNextToken(prevToken, step int) int {
	// Deterministic pseudo-generation for co-simulation testing
	h := prevToken*31 + step*17 + c.Config.Dims.Layers*7
	h = h ^ (h >> 13)
	h = h * 0x5bd1e995
	h = h ^ (h >> 15)
	token := h % c.Driver.Config.TextConfig.VocabSize
	if token < 0 {
		token = -token
	}
	return token
}

// GenerateWithSampling produces tokens with temperature and top-p sampling.
func (c *LLMClient) GenerateWithSampling(prompt string, logits []float32) ([]int, error) {
	promptIDs := c.Vocab.Encode(prompt)
	if len(promptIDs) == 0 {
		return nil, fmt.Errorf("llm client: empty prompt")
	}

	c.Stats.PrefillTokens = len(promptIDs)

	// Prefill
	for _, id := range promptIDs {
		tokenBytes := encodeTokenID(id, c.Config.DataType)
		if _, err := c.FW.PlanInference(tokenBytes); err != nil {
			return nil, fmt.Errorf("llm client: prefill: %w", err)
		}
	}

	// Generation with sampling
	generated := make([]int, 0, c.Config.MaxTokens)
	for len(generated) < c.Config.MaxTokens {
		var lastToken int
		if len(generated) > 0 {
			lastToken = generated[len(generated)-1]
		} else {
			lastToken = promptIDs[len(promptIDs)-1]
		}

		tokenBytes := encodeTokenID(lastToken, c.Config.DataType)
		if _, err := c.FW.PlanInference(tokenBytes); err != nil {
			return nil, fmt.Errorf("llm client: generate: %w", err)
		}

		// Sample from logits (simplified: if logits provided, use them)
		var nextToken int
		if logits != nil && len(generated) < len(logits) {
			nextToken = sampleFromLogits(logits, c.Config.Temperature, c.Config.TopP)
		} else {
			nextToken = c.predictNextToken(lastToken, len(generated))
		}

		generated = append(generated, nextToken)
		c.Stats.TokensGenerated++

		if nextToken == 2 {
			break
		}
	}

	return generated, nil
}

// sampleFromLogits applies temperature scaling and top-p sampling.
func sampleFromLogits(logits []float32, temperature, topP float32) int {
	if len(logits) == 0 {
		return 0
	}

	// Greedy decoding: return argmax
	if temperature == 0 {
		best := 0
		for i := 1; i < len(logits); i++ {
			if logits[i] > logits[best] {
				best = i
			}
		}
		return best
	}

	// Apply temperature
	scaled := make([]float32, len(logits))
	for i, l := range logits {
		scaled[i] = l / temperature
	}

	// Softmax
	maxLogit := scaled[0]
	for _, l := range scaled {
		if l > maxLogit {
			maxLogit = l
		}
	}
	sumExp := float32(0)
	probs := make([]float32, len(scaled))
	for i, l := range scaled {
		probs[i] = float32(math.Exp(float64(l - maxLogit)))
		sumExp += probs[i]
	}
	for i := range probs {
		probs[i] /= sumExp
	}

	// Sort by probability descending for top-p
	type idxProb struct {
		idx  int
		prob float32
	}
	sorted := make([]idxProb, len(probs))
	for i, p := range probs {
		sorted[i] = idxProb{i, p}
	}
	sort.Slice(sorted, func(i, j int) bool {
		return sorted[i].prob > sorted[j].prob
	})

	// Nucleus sampling
	cumProb := float32(0)
	for _, ip := range sorted {
		cumProb += ip.prob
		if cumProb >= topP {
			return ip.idx
		}
	}
	return sorted[len(sorted)-1].idx
}

// encodeTokenID converts a token ID to wire-format bytes.
func encodeTokenID(id int, dtype ComputeUnitType) []byte {
	switch dtype {
	case CUTypeBF16FMA, CUTypeBF16Array:
		// BF16: 16-bit, big-endian
		return []byte{byte(id >> 8), byte(id & 0xFF)}
	case CUTypeFP16FMA, CUTypeFP16Array:
		// FP16: 16-bit, big-endian
		return []byte{byte(id >> 8), byte(id & 0xFF)}
	case CUTypeFP32FMA, CUTypeFP32ALU:
		// FP32: 32-bit, big-endian
		return []byte{byte(id >> 24), byte(id >> 16), byte(id >> 8), byte(id)}
	case CUTypeFP64FMA:
		// FP64: 64-bit, big-endian
		return []byte{0, 0, 0, 0, byte(id >> 24), byte(id >> 16), byte(id >> 8), byte(id)}
	default:
		return []byte{byte(id)}
	}
}

// Summary returns a human-readable summary of the inference run.
func (c *LLMClient) Summary() string {
	s := fmt.Sprintf("LLM Client Summary\n")
	s += fmt.Sprintf("  Data type:     %s\n", c.Config.DataType)
	s += fmt.Sprintf("  Chassis:       %dx%dx%d\n", c.Config.Dims.Layers, c.Config.Dims.Bx, c.Config.Dims.By)
	s += fmt.Sprintf("  Prefill tokens: %d\n", c.Stats.PrefillTokens)
	s += fmt.Sprintf("  Generated:     %d tokens\n", c.Stats.TokensGenerated)
	s += fmt.Sprintf("  Dense dispatches: %d\n", c.Stats.DenseDispatches)
	s += fmt.Sprintf("  MoE dispatches:   %d\n", c.Stats.MoEDispatches)
	s += fmt.Sprintf("  KV store ops:     %d\n", c.Stats.KVStoreOps)
	s += fmt.Sprintf("  KV load ops:      %d\n", c.Stats.KVLoadOps)
	s += fmt.Sprintf("  KV evictions:     %d\n", c.Stats.KVEvictions)

	// CU summary
	cuSummary := c.Driver.MC.ComputeUnitSummary()
	if len(cuSummary) > 0 {
		s += fmt.Sprintf("  Compute units:\n")
		for cu, count := range cuSummary {
			s += fmt.Sprintf("    %-15s %d nodes\n", cu, count)
		}
	}

	return s
}
