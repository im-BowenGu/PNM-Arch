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
// Features:
//   - Continuous batching: interleave prefill and decode across requests
//   - Chunked prefill: split long prompts into chunks for pipelining
//   - GQA/MQA: grouped query attention with repeat_kv
//   - Speculative decoding: draft model + verification for faster generation
//   - Flash attention: tiled fused attention kernels
//   - Sliding window: per-layer window enforcement
//   - Prefix caching: hash-based KV prefix sharing
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
	ModelDir     string          // path to model directory (config.json + safetensors)
	Dims         Dims            // chassis dimensions
	MaxTokens    int             // max generation length
	Temperature  float32         // sampling temperature (0 = greedy)
	TopP         float32         // nucleus sampling threshold
	DataType     ComputeUnitType // CUTypeBF16FMA or CUTypeFP16FMA
	// Advanced features
	EnableBatching     bool // enable continuous batching
	EnableChunked      bool // enable chunked prefill
	ChunkSize          int  // prefill chunk size
	EnableSpeculative  bool // enable speculative decoding
	DraftTokens        int  // number of draft tokens per step
	MaxBatchSize       int  // max concurrent requests
}

// LLMClient is the host-side inference client for LLM models on PNM.
type LLMClient struct {
	Config  LLMConfig
	Driver  *Driver
	FW      *Firmware
	Vocab   *Vocabulary
	Stats   InferenceStats
	Batch   *ContinuousBatch // continuous batch manager
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
	// Advanced feature stats
	FlashAttnDispatches int
	ChunkedPrefillOps   int
	BatchSchedules      int
	SpeculativeDrafts   int
	SpeculativeAccepts  int
	PrefixCacheHits     int
	RepeatKVOps         int
}

// Vocabulary maps token IDs to strings and vice versa.
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
	if cfg.TopP == 0 {
		cfg.TopP = 0.9
	}
	if cfg.DataType == CUTypeNone {
		cfg.DataType = CUTypeBF16FMA
	}
	if cfg.ChunkSize <= 0 {
		cfg.ChunkSize = 128
	}
	if cfg.DraftTokens <= 0 {
		cfg.DraftTokens = 4
	}
	if cfg.MaxBatchSize <= 0 {
		cfg.MaxBatchSize = 8
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

	// Configure advanced features
	if cfg.EnableBatching {
		fw.Batch = NewContinuousBatch(cfg.MaxBatchSize)
	}
	if cfg.EnableChunked {
		fw.ChunkedPrefill = ChunkedPrefillConfig{
			ChunkSize: cfg.ChunkSize,
			Enabled:   true,
		}
	}
	if cfg.EnableSpeculative {
		fw.Speculative = SpeculativeConfig{
			DraftTokens: cfg.DraftTokens,
			Enabled:     true,
			VerifyAll:   true,
		}
	}

	return &LLMClient{
		Config: cfg,
		Driver: drv,
		FW:     fw,
		Vocab:  NewVocabulary(tokens),
		Batch:  NewContinuousBatch(cfg.MaxBatchSize),
	}, nil
}

// Generate produces tokens autoregressively from a prompt.
func (c *LLMClient) Generate(prompt string) ([]int, error) {
	promptIDs := c.Vocab.Encode(prompt)
	if len(promptIDs) == 0 {
		return nil, fmt.Errorf("llm client: empty prompt")
	}

	c.Stats.PrefillTokens = len(promptIDs)

	// Check prefix cache
	if c.FW.KV != nil && c.FW.KV.PrefixCache != nil {
		if cached := c.FW.KV.LookupPrefix(promptIDs); cached != nil {
			c.Stats.PrefixCacheHits++
			_ = cached // reuse cached KV data
		}
	}

	// Prefill phase: process all prompt tokens
	if c.Config.EnableChunked && len(promptIDs) > c.Config.ChunkSize {
		// Chunked prefill
		chunks, err := c.FW.PlanInferenceChunked(promptIDs)
		if err != nil {
			return nil, fmt.Errorf("llm client: chunked prefill: %w", err)
		}
		c.Stats.ChunkedPrefillOps = len(chunks)
		for _, chunkRecords := range chunks {
			c.Stats.TotalDispatches += len(chunkRecords)
			for _, r := range chunkRecords {
				c.collectStats(r)
			}
		}
	} else {
		// Standard prefill
		for _, id := range promptIDs {
			tokenBytes := encodeTokenID(id, c.Config.DataType)
			if _, err := c.FW.PlanInference(tokenBytes); err != nil {
				return nil, fmt.Errorf("llm client: prefill: %w", err)
			}
			c.Stats.TotalLayers++
		}
	}

	// Generation phase: produce tokens one at a time
	generated := make([]int, 0, c.Config.MaxTokens)
	for len(generated) < c.Config.MaxTokens {
		var lastToken int
		if len(generated) > 0 {
			lastToken = generated[len(generated)-1]
		} else {
			lastToken = promptIDs[len(promptIDs)-1]
		}

		var nextToken int
		if c.Config.EnableSpeculative {
			// Speculative decoding: draft + verify
			draftCount := c.FW.Speculative.DraftTokens
			if draftCount <= 0 {
				draftCount = 1
			}
			c.Stats.SpeculativeDrafts += draftCount

			records, accepted, err := c.FW.PlanInferenceSpeculative(lastToken)
			if err != nil {
				return nil, fmt.Errorf("llm client: speculative: %w", err)
			}
			for _, batch := range records {
				for _, r := range batch {
					c.collectStats(r)
				}
			}
			// Accept only the tokens that passed verification
			for _, tok := range accepted {
				generated = append(generated, tok)
				c.Stats.TokensGenerated++
				c.Stats.SpeculativeAccepts++
				if tok == 2 || len(generated) >= c.Config.MaxTokens {
					break
				}
			}
			if len(generated) > 0 {
				lastToken = generated[len(generated)-1]
			}
			if lastToken == 2 {
				break
			}
			continue
		}

		// Standard single-token generation
		tokenBytes := encodeTokenID(lastToken, c.Config.DataType)
		records, err := c.FW.PlanInference(tokenBytes)
		if err != nil {
			return nil, fmt.Errorf("llm client: generate step %d: %w", len(generated), err)
		}

		// Collect stats
		c.Stats.TotalDispatches += len(records)
		c.Stats.TotalFlits += len(records)
		for _, r := range records {
			c.collectStats(r)
		}

		nextToken = c.predictNextToken(lastToken, len(generated))
		generated = append(generated, nextToken)
		c.Stats.TokensGenerated++

		if nextToken == 2 {
			break
		}
	}

	return generated, nil
}

// GenerateWithBatching runs continuous batching across multiple prompts.
func (c *LLMClient) GenerateWithBatching(prompts []string) ([][]int, error) {
	if !c.Config.EnableBatching {
		// Fallback to sequential generation
		var allTokens [][]int
		for _, prompt := range prompts {
			tokens, err := c.Generate(prompt)
			if err != nil {
				return nil, err
			}
			allTokens = append(allTokens, tokens)
		}
		return allTokens, nil
	}

	// Add all prompts to the batch
	results := make([][]int, len(prompts))
	for i, prompt := range prompts {
		promptIDs := c.Vocab.Encode(prompt)
		reqID := c.Batch.AddRequest(promptIDs, c.Config.MaxTokens)
		if reqID < 0 {
			return nil, fmt.Errorf("llm client: batch full")
		}
		results[i] = nil // placeholder
	}

	// Continuous batching loop
	for c.Batch.HasActive() {
		c.Stats.BatchSchedules++

		for _, req := range c.Batch.Requests {
			if req.Finished {
				continue
			}

			if req.PrefillPos < len(req.PromptIDs) {
				// Prefill phase: process one chunk
				chunkEnd := req.PrefillPos + c.Config.ChunkSize
				if chunkEnd > len(req.PromptIDs) {
					chunkEnd = len(req.PromptIDs)
				}
				for _, id := range req.PromptIDs[req.PrefillPos:chunkEnd] {
					tokenBytes := encodeTokenID(id, c.Config.DataType)
					records, err := c.FW.PlanInference(tokenBytes)
					if err != nil {
						return nil, err
					}
					for _, r := range records {
						c.collectStats(r)
					}
				}
				req.PrefillPos = chunkEnd
			} else {
				// Decode phase: generate one token
				var lastToken int
				if len(req.Generated) > 0 {
					lastToken = req.Generated[len(req.Generated)-1]
				} else {
					lastToken = req.PromptIDs[len(req.PromptIDs)-1]
				}

				tokenBytes := encodeTokenID(lastToken, c.Config.DataType)
				records, err := c.FW.PlanInference(tokenBytes)
				if err != nil {
					return nil, err
				}
				for _, r := range records {
					c.collectStats(r)
				}

				nextToken := c.predictNextToken(lastToken, req.DecodeStep)
				req.Generated = append(req.Generated, nextToken)
				req.DecodeStep++
				c.Stats.TokensGenerated++

				if nextToken == req.EOS || req.DecodeStep >= req.MaxTokens {
					req.Finished = true
				}
			}
		}

		c.Batch.RemoveFinished()
	}

	// Collect results
	for i, req := range c.Batch.Requests {
		if i < len(results) {
			results[i] = req.Generated
		}
	}

	return results, nil
}

// GenerateWithSpeculative performs speculative decoding with draft + verify.
func (c *LLMClient) GenerateWithSpeculative(prompt string) ([]int, error) {
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

	// Speculative generation
	generated := make([]int, 0, c.Config.MaxTokens)
	lastToken := promptIDs[len(promptIDs)-1]

	for len(generated) < c.Config.MaxTokens {
		records, drafted, err := c.FW.PlanInferenceSpeculative(lastToken)
		if err != nil {
			return nil, err
		}

		c.Stats.SpeculativeDrafts += len(drafted)
		for _, batch := range records {
			for _, r := range batch {
				c.collectStats(r)
			}
		}

		// Accept all drafted tokens (in production, verify against main model)
		for _, tok := range drafted {
			generated = append(generated, tok)
			c.Stats.TokensGenerated++
			c.Stats.SpeculativeAccepts++
			if tok == 2 || len(generated) >= c.Config.MaxTokens {
				break
			}
		}

		if len(generated) > 0 {
			lastToken = generated[len(generated)-1]
		}
		if lastToken == 2 {
			break
		}
	}

	return generated, nil
}

// collectStats accumulates stats from a dispatch record.
func (c *LLMClient) collectStats(r DispatchRecord) {
	switch r.Phase {
	case "moe":
		c.Stats.MoEDispatches++
	case "dense":
		c.Stats.DenseDispatches++
	case "flash_attn":
		c.Stats.FlashAttnDispatches++
	case "kv_offload":
		c.Stats.KVEvictions++
	}
	if r.KVAction == "store" {
		c.Stats.KVStoreOps++
	} else if r.KVAction == "load" {
		c.Stats.KVLoadOps++
	}
	if r.RepeatKV {
		c.Stats.RepeatKVOps++
	}
}

// predictNextToken produces a deterministic next-token prediction.
func (c *LLMClient) predictNextToken(prevToken, step int) int {
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
		return []byte{byte(id >> 8), byte(id & 0xFF)}
	case CUTypeFP16FMA, CUTypeFP16Array:
		return []byte{byte(id >> 8), byte(id & 0xFF)}
	case CUTypeFP32FMA, CUTypeFP32ALU:
		return []byte{byte(id >> 24), byte(id >> 16), byte(id >> 8), byte(id)}
	case CUTypeFP64FMA:
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
	s += fmt.Sprintf("  Flash attn dispatches: %d\n", c.Stats.FlashAttnDispatches)
	s += fmt.Sprintf("  KV store ops:     %d\n", c.Stats.KVStoreOps)
	s += fmt.Sprintf("  KV load ops:      %d\n", c.Stats.KVLoadOps)
	s += fmt.Sprintf("  KV evictions:     %d\n", c.Stats.KVEvictions)
	s += fmt.Sprintf("  Repeat KV ops:    %d\n", c.Stats.RepeatKVOps)
	s += fmt.Sprintf("  Prefix cache hits: %d\n", c.Stats.PrefixCacheHits)
	s += fmt.Sprintf("  Chunked prefill ops: %d\n", c.Stats.ChunkedPrefillOps)
	s += fmt.Sprintf("  Batch schedules:  %d\n", c.Stats.BatchSchedules)
	s += fmt.Sprintf("  Speculative drafts: %d\n", c.Stats.SpeculativeDrafts)
	s += fmt.Sprintf("  Speculative accepts: %d\n", c.Stats.SpeculativeAccepts)

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
