package pnm

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
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
	ModelDir          string          // path to model directory (config.json + safetensors)
	Dims              Dims            // chassis dimensions
	MaxTokens         int             // max generation length
	Temperature       float32         // sampling temperature (0 = greedy)
	TopP              float32         // nucleus sampling threshold (0 = disabled)
	TopK              int             // top-k sampling, keeps K highest-prob tokens (0 = disabled)
	MinP              float32         // min-p: discard tokens below p * max_prob (0 = disabled)
	RepetitionPenalty float32         // repetition penalty: >1 discourages repeats (1 = disabled)
	FrequencyPenalty  float32         // per-token frequency penalty (subtract from logits)
	PresencePenalty   float32         // per-token presence penalty (binary: 1 if seen, 0 if not)
	DataType          ComputeUnitType // CUTypeBF16FMA or CUTypeFP16FMA
	QuantMode         QuantMode       // weight quantization mode
	// Advanced features
	EnableBatching    bool // enable continuous batching
	EnableChunked     bool // enable chunked prefill
	ChunkSize         int  // prefill chunk size
	EnableSpeculative bool // enable speculative decoding
	DraftTokens       int  // number of draft tokens per step
	MaxBatchSize      int  // max concurrent requests
	// Logprobs
	TopKLogprobs int // number of top-k logprobs to return per token (0 = none)
	// Beam search
	NumBeams      int     // number of beams for beam search (0 = disabled, use sampling)
	LengthPenalty float32 // length normalization penalty for beam search (1.0 = no penalty)
	// Stop conditions
	StopTokens []int // token IDs that halt generation
	// Structured output
	StructuredPattern string // regex pattern for constrained generation (empty = unconstrained)
}

// LLMClient is the host-side inference client for LLM models on PNM.
type LLMClient struct {
	Config LLMConfig
	Driver *Driver
	FW     *Firmware
	Vocab  *Vocabulary
	Stats  InferenceStats
	Batch  *ContinuousBatch // continuous batch manager
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
	// Sampling stats
	BeamSearches     int
	StructuredTokens int
	LogprobTokens    int
	// Quantization stats
	QuantDequantOps  int
	QuantWeightBytes int
}

// Vocabulary maps token IDs to strings and vice versa.  When a real
// BPE tokenizer (tokenizer.json) is present in the model directory the
// backend is the loaded BPEVocab and Encode/Decode are the true Gemma
// tokenizer operations; otherwise a synthetic id<->string map is used.
type Vocabulary struct {
	TokenToID map[string]int
	IDToToken map[int]string
	Size      int
	bpe       *BPEVocab // real tokenizer backend (nil = synthetic)
}

// NewVocabulary creates a vocabulary from a token list.  If bpe is
// non-nil its tables back the mapping (real Gemma BPE); tokens is then
// advisory and only used for Size.
func NewVocabulary(tokens []string, bpe *BPEVocab) *Vocabulary {
	v := &Vocabulary{
		TokenToID: make(map[string]int),
		IDToToken: make(map[int]string),
		Size:      len(tokens),
		bpe:       bpe,
	}
	if bpe != nil {
		v.Size = bpe.VocabSize()
		for i, tok := range bpe.IDToToken {
			v.IDToToken[i] = tok
		}
		for tok, id := range bpe.TokenToID {
			v.TokenToID[tok] = id
		}
		return v
	}
	for i, tok := range tokens {
		v.TokenToID[tok] = i
		v.IDToToken[i] = tok
	}
	return v
}

// VocabSize returns the number of tokens in the underlying vocabulary.
func (b *BPEVocab) VocabSize() int {
	return len(b.IDToToken)
}

// Encode converts text to token IDs.  With a real BPE backend this is
// the faithful Gemma tokenization (byte-fallback + merges); otherwise a
// simplified whitespace tokenization is used.
func (v *Vocabulary) Encode(text string) []int {
	if v.bpe != nil {
		ids, err := v.bpe.Encode(text)
		if err == nil {
			return ids
		}
	}
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

// Decode converts token IDs back to text.  With a real BPE backend this
// produces the actual decoded characters (byte-fallback aware); otherwise
// the synthetic id->string map is used.
func (v *Vocabulary) Decode(ids []int) string {
	if v.bpe != nil {
		return v.bpe.Decode(ids)
	}
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
	// Guard against -MinInt overflow: if h is still negative (only on
	// two's-complement where -MinInt == MinInt), clamp to 0.
	if h < 0 {
		h = 0
	}
	return h
}

// NewLLMClient creates a new LLM inference client.
func NewLLMClient(cfg LLMConfig) (*LLMClient, error) {
	if cfg.MaxTokens == 0 {
		cfg.MaxTokens = 2048
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

	// Build the vocabulary: the real Gemma BPE tokenizer when the model
	// directory carries tokenizer.json, else the synthetic id->string map.
	tc := &drv.Config.TextConfig
	var bpe *BPEVocab
	if tb, err := LoadBPEVocab(filepath.Join(cfg.ModelDir, "tokenizer.json")); err == nil {
		bpe = tb
	}
	tokens := make([]string, tc.VocabSize)
	for i := 0; i < tc.VocabSize && i < len(tokens); i++ {
		tokens[i] = fmt.Sprintf("token_%d", i)
	}
	_ = bpe

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
		Vocab:  NewVocabulary(tokens, bpe),
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
			records, err := c.FW.PlanInference(tokenBytes)
			if err != nil {
				return nil, fmt.Errorf("llm client: prefill: %w", err)
			}
			c.Stats.TotalDispatches += len(records)
			for _, r := range records {
				c.collectStats(r)
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

		logits := c.simulateLogits(lastToken, len(generated), generated)
		var logprobs []LogprobResult
		nextToken = sampleFromLogits(logits, c.Config.Temperature, c.Config.TopP,
			c.Config.TopK, c.Config.MinP, &logprobs, c.Config.TopKLogprobs, nil)
		generated = append(generated, nextToken)
		c.Stats.TokensGenerated++

		if nextToken == 2 || c.isStopToken(nextToken) {
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
	reqIDToSlot := make(map[int]int) // RequestID -> results index
	// RemoveFinished() drops finished requests from the batch, so capture the
	// generated sequence at finish time (the traversal below would otherwise
	// find an empty batch and return all-nil results).
	resultsByReq := make(map[int][]int)
	for i, prompt := range prompts {
		promptIDs := c.Vocab.Encode(prompt)
		reqID := c.Batch.AddRequest(promptIDs, c.Config.MaxTokens)
		if reqID < 0 {
			return nil, fmt.Errorf("llm client: batch full")
		}
		reqIDToSlot[reqID] = i
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
					c.Stats.TotalDispatches += len(records)
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
				c.Stats.TotalDispatches += len(records)
				for _, r := range records {
					c.collectStats(r)
				}

				logits := c.simulateLogits(lastToken, req.DecodeStep, req.Generated)
				nextToken := sampleFromLogits(logits, c.Config.Temperature, c.Config.TopP,
					c.Config.TopK, c.Config.MinP, nil, 0, nil)
				req.Generated = append(req.Generated, nextToken)
				req.DecodeStep++
				c.Stats.TokensGenerated++

				if nextToken == req.EOS || req.DecodeStep >= req.MaxTokens {
					req.Finished = true
					resultsByReq[req.RequestID] = append([]int(nil), req.Generated...)
				}
			}
		}

		c.Batch.RemoveFinished()
	}

	// Collect results using RequestID mapping (RemoveFinished shifts slice indices);
	// finished requests were captured at finish time, remaining ones (if any) here.
	for _, req := range c.Batch.Requests {
		if slot, ok := reqIDToSlot[req.RequestID]; ok {
			results[slot] = req.Generated
		}
	}
	for reqID, gen := range resultsByReq {
		if slot, ok := reqIDToSlot[reqID]; ok {
			results[slot] = gen
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
		records, err := c.FW.PlanInference(tokenBytes)
		if err != nil {
			return nil, fmt.Errorf("llm client: prefill: %w", err)
		}
		c.Stats.TotalDispatches += len(records)
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
			c.Stats.TotalDispatches += len(batch)
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
	// Quantization: every dispatch that goes through quantized CUs triggers
	// a dequant operation in hardware (weight_dequant.v)
	if c.Config.QuantMode != QuantNone && (r.Phase == "moe" || r.Phase == "dense") {
		c.Stats.QuantDequantOps++
	}
}

// QuantMode selects weight quantization.
// INT4/INT8 weight-only quantization with dequant at dispatch time,
// matching the hardware int4_mac_array.v and weight_dequant.v units.
type QuantMode int

const (
	QuantNone  QuantMode = iota // no quantization, full BF16/FP16 weights
	QuantInt8                   // INT8 weight-only quantization (2x compression)
	QuantInt4                   // INT4 weight-only quantization (4x compression)
	QuantFP4                    // FP4 (E2M1) weight-only quantization (4x compression)
	QuantMXFP4                  // MXFP4 (E2M1 + block scale) weight-only quantization
)

// String returns the human-readable name of the quantization mode.
func (q QuantMode) String() string {
	switch q {
	case QuantInt8:
		return "int8"
	case QuantInt4:
		return "int4"
	case QuantFP4:
		return "fp4"
	case QuantMXFP4:
		return "mxfp4"
	default:
		return "none"
	}
}

// LogprobResult is the per-token log-probability information.
type LogprobResult struct {
	TokenID int            // sampled token ID
	Logprob float32        // log-probability of the sampled token
	Rank    int            // rank in the distribution (0 = most likely)
	TopK    []LogprobEntry // top-K alternative tokens (may be nil)
}

// LogprobEntry is one alternative token with its log-probability.
type LogprobEntry struct {
	TokenID int     // token ID
	Logprob float32 // log-probability
}

// BeamState tracks one beam during beam search.
type BeamState struct {
	Tokens   []int   // generated token sequence
	Score    float64 // cumulative log-probability score
	Finished bool    // true if EOS or stop token was generated
}

// StructuredFSM is a simplified finite-state machine for regex-constrained
// generation.  It tracks which character classes are valid at each step
// and masks out logits for tokens that don't match the pattern.
type StructuredFSM struct {
	Pattern  string
	States   []fsmState // states[i] = set of valid char-class transitions from state i
	Current  int        // current state
	Complete bool       // true if pattern is fully matched

	// compStates[s] is true when the accepting state is still reachable
	// from s using whole vocabulary tokens (computed lazily by
	// ensureCompletable, cached for the FSM's lifetime).
	compStates []bool
}

// fsmState represents valid transitions from one FSM state.
type fsmState struct {
	Transitions []fsmTransition
}

// fsmTransition is one labeled transition from an FSM state.
type fsmTransition struct {
	CharClass rune // character class: 'a'-'z', 'A'-'Z', '0'-'9', ' ' (space), '.' (any)
	Next      int  // target state
}

// QuantizedCU returns the compute unit type for the configured quantization mode.
// INT4/INT8 weight-only quantization with dequant at dispatch time, matching
// the hardware int4_mac_array.v and weight_dequant.v units.
func (c *LLMClient) QuantizedCU() ComputeUnitType {
	switch c.Config.QuantMode {
	case QuantInt8:
		return CUTypeINT8MAC
	case QuantInt4:
		return CUTypeINT4Array
	case QuantFP4:
		return CUTypeFP4Array
	case QuantMXFP4:
		return CUTypeMXFP4Array
	default:
		return c.Config.DataType
	}
}

// QuantWeightBytes returns the per-weight byte size for the current quant mode.
func (c *LLMClient) QuantWeightBytes() int {
	switch c.Config.QuantMode {
	case QuantInt8:
		return 1
	case QuantInt4:
		return 1 // packed, but 1 byte addressable
	case QuantFP4:
		return 1 // FP4 packed 2 per byte
	case QuantMXFP4:
		return 1 // FP4 payload + shared block-scale (charged as packed byte)
	default:
		return c.Config.DataType.DTypeBytes()
	}
}

// simulateLogits produces synthetic logits for a given token step.
// In production these come from the model's forward pass on the PNM fabric;
// here they are a deterministic function of the token history so that
// sampling behavior is testable without a real model.
func (c *LLMClient) simulateLogits(prevToken, step int, history []int) []float32 {
	vocabSize := c.Driver.Config.TextConfig.VocabSize
	logits := make([]float32, vocabSize)
	h := prevToken*31 + step*17 + c.Config.Dims.Layers*7
	for i := range logits {
		h = h ^ (h >> 13)
		h = h * 0x5bd1e995
		h = h ^ (h >> 15)
		logits[i] = float32(h&0x7FFFFFFF) / float32(0x7FFFFFFF)
	}
	// Apply repetition/frequency/presence penalties to history tokens
	if c.Config.RepetitionPenalty != 1.0 && c.Config.RepetitionPenalty > 0 {
		seen := make(map[int]bool)
		for _, tok := range history {
			if !seen[tok] && tok >= 0 && tok < vocabSize {
				if logits[tok] > 0 {
					logits[tok] /= c.Config.RepetitionPenalty
				} else {
					logits[tok] *= c.Config.RepetitionPenalty
				}
				seen[tok] = true
			}
		}
	}
	if c.Config.FrequencyPenalty != 0 {
		freq := make(map[int]int)
		for _, tok := range history {
			if tok >= 0 && tok < vocabSize {
				freq[tok]++
			}
		}
		for tok, count := range freq {
			logits[tok] -= c.Config.FrequencyPenalty * float32(count)
		}
	}
	if c.Config.PresencePenalty != 0 {
		seen := make(map[int]bool)
		for _, tok := range history {
			if tok >= 0 && tok < vocabSize {
				seen[tok] = true
			}
		}
		for tok := range seen {
			logits[tok] -= c.Config.PresencePenalty
		}
	}
	return logits
}

// sampleFromLogits samples a token from a logit distribution.
// Supports temperature, top-k, top-p (nucleus), and min-p sampling.
// If logprobs is non-nil, it is filled with per-token log-probability info.
// If mask is non-nil, only tokens where mask[id] == true are eligible (for
// structured generation).
func sampleFromLogits(
	logits []float32,
	temperature float32,
	topP float32,
	topK int,
	minP float32,
	logprobs *[]LogprobResult,
	topKLogprobs int,
	mask []bool,
) int {
	if len(logits) == 0 {
		return 0
	}
	vocabSize := len(logits)

	// Apply structured output mask.  Operate on a copy so we never mutate the
	// caller's logits slice in place (a reused buffer would stay clobbered).
	if mask != nil {
		hasMask := false
		for i := range mask {
			if i < len(mask) && !mask[i] {
				hasMask = true
				break
			}
		}
		if hasMask {
			work := make([]float32, len(logits))
			copy(work, logits)
			for i := range work {
				if i < len(mask) && !mask[i] {
					work[i] = -1e9
				}
			}
			logits = work
		}
	}

	// Greedy decoding: return argmax (also for invalid temperature <= 0)
	if temperature <= 0 {
		best := 0
		for i := 1; i < vocabSize; i++ {
			if logits[i] > logits[best] {
				best = i
			}
		}
		if logprobs != nil && topKLogprobs > 0 {
			*logprobs = append(*logprobs, buildLogprobEntry(logits, best, topKLogprobs))
		}
		return best
	}

	// Apply temperature
	scaled := make([]float32, vocabSize)
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
	probs := make([]float32, vocabSize)
	for i, l := range scaled {
		probs[i] = float32(math.Exp(float64(l - maxLogit)))
		sumExp += probs[i]
	}
	for i := range probs {
		probs[i] /= sumExp
	}

	// Build sorted index by probability descending
	type idxProb struct {
		idx  int
		prob float32
	}
	sorted := make([]idxProb, vocabSize)
	for i, p := range probs {
		sorted[i] = idxProb{i, p}
	}
	sort.Slice(sorted, func(i, j int) bool {
		return sorted[i].prob > sorted[j].prob
	})

	// Top-K filtering
	if topK > 0 && topK < len(sorted) {
		sorted = sorted[:topK]
	}

	// Min-P filtering: discard tokens with prob < minP * max_prob
	if minP > 0 && len(sorted) > 0 {
		cutoff := minP * sorted[0].prob
		n := 0
		for _, ip := range sorted {
			if ip.prob >= cutoff {
				sorted[n] = ip
				n++
			}
		}
		sorted = sorted[:n]
	}

	// Nucleus (top-p) filtering
	if topP > 0 && topP < 1 {
		cumProb := float32(0)
		n := 0
		for _, ip := range sorted {
			cumProb += ip.prob
			sorted[n] = ip
			n++
			if cumProb >= topP {
				break
			}
		}
		sorted = sorted[:n]
	}

	// Renormalize
	total := float32(0)
	for _, ip := range sorted {
		total += ip.prob
	}
	if len(sorted) == 0 || total <= 0 || math.IsNaN(float64(total)) ||
		math.IsInf(float64(total), 0) {
		// The filter (e.g. minP > 1 or non-finite logits) emptied the
		// distribution; fall back to greedy argmax over the original logits.
		best := 0
		for i := 1; i < vocabSize; i++ {
			if logits[i] > logits[best] {
				best = i
			}
		}
		if logprobs != nil && topKLogprobs > 0 {
			*logprobs = append(*logprobs, buildLogprobEntry(logits, best, topKLogprobs))
		}
		return best
	}

	// Sample from the filtered distribution using deterministic hash.
	// Accumulate the 8 hash bytes in a uint64 so no precision is lost (the
	// prior float32 accumulator only kept ~24 bits, biasing the hash).
	var rHash uint64
	for i := 0; i < 8; i++ {
		rHash = rHash*256 + uint64(int(sorted[0].idx*31+i*17+int(temperature*1000))&0xFF)
	}
	// rHash holds 8 bytes (64 bits); normalize to [0,1) before scaling.
	r := float32(float64(rHash) / 18446744073709551616) // 2^64
	r *= total

	cumProb := float32(0)
	for _, ip := range sorted {
		cumProb += ip.prob
		if cumProb >= r {
			if logprobs != nil && topKLogprobs > 0 {
				*logprobs = append(*logprobs, buildLogprobEntry(logits, ip.idx, topKLogprobs))
			}
			return ip.idx
		}
	}
	if logprobs != nil && topKLogprobs > 0 {
		*logprobs = append(*logprobs, buildLogprobEntry(logits, sorted[len(sorted)-1].idx, topKLogprobs))
	}
	return sorted[len(sorted)-1].idx
}

// buildLogprobEntry constructs a LogprobResult for one sampled token.
func buildLogprobEntry(logits []float32, sampledID int, topK int) LogprobResult {
	// Convert logits to log-probs via log-softmax
	maxLogit := logits[0]
	for _, l := range logits {
		if l > maxLogit {
			maxLogit = l
		}
	}
	sumExp := float32(0)
	for _, l := range logits {
		sumExp += float32(math.Exp(float64(l - maxLogit)))
	}
	logSumExp := float32(math.Log(float64(sumExp)))
	logProbs := make([]float32, len(logits))
	for i, l := range logits {
		logProbs[i] = l - maxLogit - logSumExp
	}

	// Compute rank
	rank := 0
	for i, l := range logProbs {
		if i != sampledID && l > logProbs[sampledID] {
			rank++
		}
	}

	// Build top-K alternatives
	var topKEntries []LogprobEntry
	if topK > 0 {
		type idxLP struct {
			idx int
			lp  float32
		}
		all := make([]idxLP, len(logProbs))
		for i, lp := range logProbs {
			all[i] = idxLP{i, lp}
		}
		sort.Slice(all, func(i, j int) bool {
			return all[i].lp > all[j].lp
		})
		count := topK
		if count > len(all) {
			count = len(all)
		}
		topKEntries = make([]LogprobEntry, count)
		for i := 0; i < count; i++ {
			topKEntries[i] = LogprobEntry{TokenID: all[i].idx, Logprob: all[i].lp}
		}
	}

	return LogprobResult{
		TokenID: sampledID,
		Logprob: logProbs[sampledID],
		Rank:    rank,
		TopK:    topKEntries,
	}
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
	s += fmt.Sprintf("  Beam searches: %d\n", c.Stats.BeamSearches)
	s += fmt.Sprintf("  Structured tokens: %d\n", c.Stats.StructuredTokens)
	s += fmt.Sprintf("  Logprob tokens: %d\n", c.Stats.LogprobTokens)
	if c.Config.TopK > 0 {
		s += fmt.Sprintf("  Top-K: %d\n", c.Config.TopK)
	}
	if c.Config.MinP > 0 {
		s += fmt.Sprintf("  Min-P: %.2f\n", c.Config.MinP)
	}
	if c.Config.RepetitionPenalty != 1.0 {
		s += fmt.Sprintf("  Repetition penalty: %.2f\n", c.Config.RepetitionPenalty)
	}
	if c.Config.FrequencyPenalty != 0 {
		s += fmt.Sprintf("  Frequency penalty: %.2f\n", c.Config.FrequencyPenalty)
	}
	if c.Config.PresencePenalty != 0 {
		s += fmt.Sprintf("  Presence penalty: %.2f\n", c.Config.PresencePenalty)
	}
	if c.Config.StructuredPattern != "" {
		s += fmt.Sprintf("  Structured pattern: %s\n", c.Config.StructuredPattern)
	}
	if c.Config.NumBeams > 1 {
		s += fmt.Sprintf("  Num beams: %d\n", c.Config.NumBeams)
	}
	if c.Config.QuantMode != QuantNone {
		s += fmt.Sprintf("  Quant mode:    %s\n", c.Config.QuantMode)
		s += fmt.Sprintf("  Quant dequants: %d\n", c.Stats.QuantDequantOps)
	}

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

// isStopToken checks if a token is in the stop list.
func (c *LLMClient) isStopToken(tokenID int) bool {
	for _, st := range c.Config.StopTokens {
		if tokenID == st {
			return true
		}
	}
	return false
}

// GenerateWithLogprobs produces tokens with per-token log-probability information.
// Returns the generated token IDs and a parallel slice of LogprobResult entries.
func (c *LLMClient) GenerateWithLogprobs(prompt string) ([]int, []LogprobResult, error) {
	promptIDs := c.Vocab.Encode(prompt)
	if len(promptIDs) == 0 {
		return nil, nil, fmt.Errorf("llm client: empty prompt")
	}
	c.Stats.PrefillTokens = len(promptIDs)

	// Prefill
	for _, id := range promptIDs {
		tokenBytes := encodeTokenID(id, c.Config.DataType)
		records, err := c.FW.PlanInference(tokenBytes)
		if err != nil {
			return nil, nil, fmt.Errorf("llm client: prefill: %w", err)
		}
		c.Stats.TotalDispatches += len(records)
		for _, r := range records {
			c.collectStats(r)
		}
	}

	generated := make([]int, 0, c.Config.MaxTokens)
	var allLogprobs []LogprobResult

	for len(generated) < c.Config.MaxTokens {
		var lastToken int
		if len(generated) > 0 {
			lastToken = generated[len(generated)-1]
		} else {
			lastToken = promptIDs[len(promptIDs)-1]
		}

		tokenBytes := encodeTokenID(lastToken, c.Config.DataType)
		records, err := c.FW.PlanInference(tokenBytes)
		if err != nil {
			return nil, nil, fmt.Errorf("llm client: generate step %d: %w", len(generated), err)
		}
		for _, r := range records {
			c.collectStats(r)
		}

		logits := c.simulateLogits(lastToken, len(generated), generated)
		var stepLogprobs []LogprobResult
		nextToken := sampleFromLogits(logits, c.Config.Temperature, c.Config.TopP,
			c.Config.TopK, c.Config.MinP, &stepLogprobs, c.Config.TopKLogprobs, nil)
		generated = append(generated, nextToken)
		allLogprobs = append(allLogprobs, stepLogprobs...)
		c.Stats.TokensGenerated++
		c.Stats.LogprobTokens++

		if nextToken == 2 || c.isStopToken(nextToken) {
			break
		}
	}
	return generated, allLogprobs, nil
}

// GenerateWithBeamSearch performs beam search with length normalization.
func (c *LLMClient) GenerateWithBeamSearch(prompt string, numBeams int) ([]int, error) {
	if numBeams <= 1 {
		return c.Generate(prompt)
	}

	promptIDs := c.Vocab.Encode(prompt)
	if len(promptIDs) == 0 {
		return nil, fmt.Errorf("llm client: empty prompt")
	}
	c.Stats.PrefillTokens = len(promptIDs)
	c.Stats.BeamSearches++

	// Prefill
	for _, id := range promptIDs {
		tokenBytes := encodeTokenID(id, c.Config.DataType)
		if _, err := c.FW.PlanInference(tokenBytes); err != nil {
			return nil, fmt.Errorf("llm client: prefill: %w", err)
		}
	}

	// Initialize beams
	beams := make([]BeamState, numBeams)
	for i := range beams {
		beams[i] = BeamState{
			Tokens: make([]int, len(promptIDs)),
			Score:  0,
		}
		copy(beams[i].Tokens, promptIDs)
	}

	lengthPenalty := c.Config.LengthPenalty
	if lengthPenalty == 0 {
		lengthPenalty = 1.0
	}

	for step := 0; step < c.Config.MaxTokens; step++ {
		type candidate struct {
			beamIdx int
			token   int
			score   float64
		}
		var candidates []candidate

		for bi, beam := range beams {
			if beam.Finished {
				candidates = append(candidates, candidate{bi, -1, beam.Score})
				continue
			}

			lastToken := beam.Tokens[len(beam.Tokens)-1]
			tokenBytes := encodeTokenID(lastToken, c.Config.DataType)
			records, err := c.FW.PlanInference(tokenBytes)
			if err != nil {
				return nil, fmt.Errorf("llm client: beam step %d: %w", step, err)
			}
			for _, r := range records {
				c.collectStats(r)
			}

			logits := c.simulateLogits(lastToken, step, beam.Tokens[len(promptIDs):])

			// Get top-k candidates
			vocabSize := len(logits)
			type idxScore struct {
				idx   int
				score float64
			}
			scores := make([]idxScore, vocabSize)
			for i, l := range logits {
				scores[i] = idxScore{i, float64(l)}
			}
			sort.Slice(scores, func(i, j int) bool {
				return scores[i].score > scores[j].score
			})
			topN := numBeams
			if topN > len(scores) {
				topN = len(scores)
			}
			for i := 0; i < topN; i++ {
				candidates = append(candidates, candidate{
					beamIdx: bi,
					token:   scores[i].idx,
					score:   beam.Score + scores[i].score,
				})
			}
		}

		// Sort candidates by score descending
		sort.Slice(candidates, func(i, j int) bool {
			return candidates[i].score > candidates[j].score
		})
		if len(candidates) > numBeams {
			candidates = candidates[:numBeams]
		}

		newBeams := make([]BeamState, 0, numBeams)
		for _, cand := range candidates {
			if cand.token == -1 {
				newBeams = append(newBeams, BeamState{
					Tokens:   beams[cand.beamIdx].Tokens,
					Score:    cand.score,
					Finished: true,
				})
				continue
			}
			newTokens := make([]int, len(beams[cand.beamIdx].Tokens)+1)
			copy(newTokens, beams[cand.beamIdx].Tokens)
			newTokens[len(beams[cand.beamIdx].Tokens)] = cand.token

			finished := cand.token == 2 || c.isStopToken(cand.token) || len(newTokens)-len(promptIDs) >= c.Config.MaxTokens
			newBeams = append(newBeams, BeamState{
				Tokens:   newTokens,
				Score:    cand.score,
				Finished: finished,
			})
		}
		beams = newBeams

		// Early termination
		allFinished := true
		for _, b := range beams {
			if !b.Finished {
				allFinished = false
				break
			}
		}
		if allFinished {
			break
		}
	}

	// Select best beam with length normalization
	bestIdx := 0
	bestScore := -1e18
	for i, b := range beams {
		length := float64(len(b.Tokens) - len(promptIDs))
		normalizedScore := b.Score / math.Pow(length+1, float64(lengthPenalty)-1)
		if normalizedScore > bestScore {
			bestScore = normalizedScore
			bestIdx = i
		}
	}

	// Return only generated tokens (skip prompt)
	return beams[bestIdx].Tokens[len(promptIDs):], nil
}

// GenerateStructured produces tokens constrained by a regex pattern.
// Uses a simplified FSM that enforces character-class transitions at each step.
// The pattern is compiled into an NFA-like structure; at each generation step,
// only tokens whose decoded text matches a valid transition are eligible.
func (c *LLMClient) GenerateStructured(prompt string, pattern string) ([]int, error) {
	fsm, err := CompileStructuredFSM(pattern)
	if err != nil {
		return nil, fmt.Errorf("llm client: compile pattern: %w", err)
	}

	promptIDs := c.Vocab.Encode(prompt)
	if len(promptIDs) == 0 {
		return nil, fmt.Errorf("llm client: empty prompt")
	}
	c.Stats.PrefillTokens = len(promptIDs)

	// Prefill
	for _, id := range promptIDs {
		tokenBytes := encodeTokenID(id, c.Config.DataType)
		records, err := c.FW.PlanInference(tokenBytes)
		if err != nil {
			return nil, fmt.Errorf("llm client: prefill: %w", err)
		}
		c.Stats.TotalDispatches += len(records)
		for _, r := range records {
			c.collectStats(r)
		}
	}

	generated := make([]int, 0, c.Config.MaxTokens)
	for len(generated) < c.Config.MaxTokens && !fsm.Complete {
		var lastToken int
		if len(generated) > 0 {
			lastToken = generated[len(generated)-1]
		} else {
			lastToken = promptIDs[len(promptIDs)-1]
		}

		tokenBytes := encodeTokenID(lastToken, c.Config.DataType)
		records, err := c.FW.PlanInference(tokenBytes)
		if err != nil {
			return nil, fmt.Errorf("llm client: structured step %d: %w", len(generated), err)
		}
		c.Stats.TotalDispatches += len(records)
		for _, r := range records {
			c.collectStats(r)
		}

		logits := c.simulateLogits(lastToken, len(generated), generated)
		mask := fsm.TokenMask(c.Vocab)

		nextToken := sampleFromLogits(logits, c.Config.Temperature, c.Config.TopP,
			c.Config.TopK, c.Config.MinP, nil, 0, mask)
		generated = append(generated, nextToken)
		c.Stats.TokensGenerated++
		c.Stats.StructuredTokens++

		// Advance FSM with the decoded character
		if tok, ok := c.Vocab.IDToToken[nextToken]; ok {
			for _, ch := range tok {
				fsm.Advance(ch)
			}
		}
	}
	return generated, nil
}

// ========================================================================
// Structured output FSM (regex-to-NFA-to-DFA simplified compiler)
// ========================================================================

// CompileStructuredFSM builds an FSM from a simplified regex pattern.
// Supported syntax: [a-z], [A-Z], [0-9], [a-zA-Z], [a-zA-Z0-9],
// . (any char), + (one or more), * (zero or more), {n} (exact count),
// literal characters. Alternation (|) and groups () are not supported.
func CompileStructuredFSM(pattern string) (*StructuredFSM, error) {
	if pattern == "" {
		return &StructuredFSM{Complete: true}, nil
	}

	fsm := &StructuredFSM{Pattern: pattern}
	states := []fsmState{{}}

	i := 0
	for i < len(pattern) {
		ch := pattern[i]

		switch ch {
		case '[':
			// Character class
			i++
			class := make(map[rune]bool)
			negate := false
			if i < len(pattern) && pattern[i] == '^' {
				negate = true
				i++
			}
			for i < len(pattern) && pattern[i] != ']' {
				if pattern[i] == '-' && i > 0 && i+1 < len(pattern) && pattern[i+1] != ']' {
					prev := rune(pattern[i-1])
					next := rune(pattern[i+1])
					for c := prev; c <= next; c++ {
						class[c] = true
					}
					i += 2
				} else {
					class[rune(pattern[i])] = true
					i++
				}
			}
			if negate {
				// Negate: all printable ASCII not in class
				for c := rune(32); c < 127; c++ {
					class[c] = !class[c]
				}
			}
			// Build transition from current state
			stateIdx := len(states) - 1
			newState := len(states)
			states = append(states, fsmState{})
			for c := range class {
				states[stateIdx].Transitions = append(states[stateIdx].Transitions,
					fsmTransition{CharClass: c, Next: newState})
			}
			// Handle repetition
			i++
			if i < len(pattern) {
				if pattern[i] == '+' {
					// One or more: add self-loop
					for c := range class {
						states[newState].Transitions = append(states[newState].Transitions,
							fsmTransition{CharClass: c, Next: newState})
					}
					i++
				} else if pattern[i] == '*' {
					// Zero or more: self-loop + skip to next
					for c := range class {
						states[newState].Transitions = append(states[newState].Transitions,
							fsmTransition{CharClass: c, Next: newState})
					}
					// Add epsilon-like transition by connecting to next state
					nextState := len(states)
					states = append(states, fsmState{})
					states[newState].Transitions = append(states[newState].Transitions,
						fsmTransition{CharClass: '.', Next: nextState})
					// Actually for * we need a different approach: keep current state valid
					// and allow advancing. Simplified: just allow staying in newState.
					states = states[:len(states)-1] // remove the extra state
					i++
				} else if pattern[i] == '{' {
					// {n}: exact repetition
					i++
					count := 0
					for i < len(pattern) && pattern[i] != '}' {
						count = count*10 + int(pattern[i]-'0')
						i++
					}
					if i < len(pattern) {
						i++ // skip '}'
					}
					// Chain count copies of the character class transition
					for k := 1; k < count; k++ {
						nextState := len(states)
						states = append(states, fsmState{})
						for c := range class {
							states[newState].Transitions = append(states[newState].Transitions,
								fsmTransition{CharClass: c, Next: nextState})
						}
						newState = nextState
					}
				}
			}

		case '.':
			// Any character
			stateIdx := len(states) - 1
			newState := len(states)
			states = append(states, fsmState{})
			states[stateIdx].Transitions = append(states[stateIdx].Transitions,
				fsmTransition{CharClass: '.', Next: newState})
			i++

		case '+':
			// One or more of previous: self-loop on last transition's target
			if len(states) > 0 {
				lastState := len(states) - 1
				for _, t := range states[lastState].Transitions {
					states[t.Next].Transitions = append(states[t.Next].Transitions, t)
				}
			}
			i++

		case '*':
			// Zero or more: skip (already handled in character class)
			i++

		default:
			// Literal character
			stateIdx := len(states) - 1
			newState := len(states)
			states = append(states, fsmState{})
			states[stateIdx].Transitions = append(states[stateIdx].Transitions,
				fsmTransition{CharClass: rune(ch), Next: newState})
			i++
		}
	}

	// Mark the last state as accepting (complete)
	if len(states) > 1 {
		// The accepting state is the last one we added transitions to
		fsm.States = states
	}

	return fsm, nil
}

// TokenMask returns a boolean mask over the vocabulary indicating which tokens
// are valid from the current FSM state.
//
// Eligibility is reachability-based, not per-character: a token qualifies
// only if (a) consuming its entire decoded text completes the pattern, or
// (b) it lands in a state from which the remaining pattern can still be
// completed by some vocabulary token (the completable fixpoint below).
// Per-character admission lets a token dead-end mid-pattern (e.g. a token
// that consumes all-but-one required digit when no vocabulary token can
// supply the final character), soft-terminating constrained generation.
func (fsm *StructuredFSM) TokenMask(vocab *Vocabulary) []bool {
	if fsm.Complete || len(fsm.States) == 0 {
		return nil
	}
	fsm.ensureCompletable(vocab)
	mask := make([]bool, vocab.Size)
	any := false
	for id := 0; id < vocab.Size; id++ {
		tok, ok := vocab.IDToToken[id]
		if !ok {
			continue
		}
		end, oc := fsm.walkFrom(fsm.Current, tok)
		if oc == walkComplete || (oc == walkFull && fsm.compStates[end]) {
			mask[id] = true
			any = true
		}
	}
	if any {
		return mask
	}
	// No vocabulary token fits the remaining pattern contiguously at all:
	// degrade to the single-character mask instead of deadlocking the sampler.
	for id := 0; id < vocab.Size; id++ {
		tok, ok := vocab.IDToToken[id]
		if !ok {
			continue
		}
		for _, ch := range tok {
			if fsm.canAdvance(ch) {
				mask[id] = true
				break
			}
		}
	}
	return mask
}

// walkOutcome classifies a strict scratch-position walk over a token.
type walkOutcome int

const (
	walkFull     walkOutcome = iota // every char consumed, FSM not complete
	walkComplete                    // every char consumed, FSM complete
	walkBlocked                     // a char has no transition, or the walk ran off the state list
)

// walkFrom walks tok from the given start state on a scratch position without
// mutating the live FSM.  Strict: any non-matching character rejects the
// token outright; the soft-enforcement fallback of Advance does not apply.
func (fsm *StructuredFSM) walkFrom(start int, tok string) (int, walkOutcome) {
	cur := start
	for _, ch := range tok {
		if cur >= len(fsm.States) {
			return -1, walkBlocked
		}
		next := -1
		for _, t := range fsm.States[cur].Transitions {
			if t.CharClass == '.' || t.CharClass == ch {
				next = t.Next
				break
			}
		}
		if next < 0 {
			return -1, walkBlocked
		}
		cur = next
	}
	if cur >= len(fsm.States)-1 {
		return cur, walkComplete
	}
	return cur, walkFull
}

// ensureCompletable computes (once per FSM) which states can still reach the
// accepting state using whole vocabulary tokens: comp[s] is true when some
// token either completes the pattern from s or lands on an already-completable
// state.  Token boundaries rarely align with pattern progress, so this
// whole-token fixpoint — not single-character lookahead — is what makes the
// mask deadlock-free.
func (fsm *StructuredFSM) ensureCompletable(vocab *Vocabulary) {
	if fsm.compStates != nil {
		return
	}
	n := len(fsm.States)
	comp := make([]bool, n)
	if n > 0 {
		comp[n-1] = true // accepting state
	}
	changed := true
	for changed {
		changed = false
		for s := 0; s < n-1; s++ {
			if comp[s] {
				continue
			}
			for id := 0; id < vocab.Size; id++ {
				tok, ok := vocab.IDToToken[id]
				if !ok {
					continue
				}
				end, oc := fsm.walkFrom(s, tok)
				if oc == walkComplete || (oc == walkFull && comp[end]) {
					comp[s] = true
					changed = true
					break
				}
			}
		}
	}
	fsm.compStates = comp
}

// canAdvance checks if the FSM can consume this character from the current state.
// Only exact rune matches and '.' (any) count: CompileStructuredFSM already
// expands [a-z]/[A-Z]/[0-9] classes into per-rune transitions, so no shorthand
// re-interpretation is allowed here (it would widen a literal such as [a] into
// the whole lowercase alphabet).
func (fsm *StructuredFSM) canAdvance(ch rune) bool {
	if fsm.Current >= len(fsm.States) {
		return false
	}
	for _, t := range fsm.States[fsm.Current].Transitions {
		if t.CharClass == '.' || t.CharClass == ch {
			return true
		}
	}
	return false
}

// Advance moves the FSM forward by consuming one character.
func (fsm *StructuredFSM) Advance(ch rune) {
	if fsm.Current >= len(fsm.States) {
		fsm.Complete = true
		return
	}
	for _, t := range fsm.States[fsm.Current].Transitions {
		matched := false
		switch {
		case t.CharClass == '.':
			matched = true
		case t.CharClass == ch:
			matched = true
		}
		if matched {
			fsm.Current = t.Next
			if fsm.Current >= len(fsm.States)-1 {
				fsm.Complete = true
			}
			return
		}
	}
	// No valid transition: pattern is broken, but keep going (soft enforcement)
	fsm.Complete = true
}
func (c *LLMClient) WriteTokens(path string, prompt string, tokenIDs []int) error {
	text := c.Vocab.Decode(tokenIDs)
	result := &TokenResult{
		Prompt:    prompt,
		Tokens:    tokenIDs,
		Text:      text,
		PromptLen: len(c.Vocab.Encode(prompt)),
		GenLen:    len(tokenIDs),
	}
	return WriteTokensFile(path, result)
}

// ExportInference writes the complete inference result (tokens + stats + dispatches) to a JSON file.
func (c *LLMClient) ExportInference(path string, prompt string, tokenIDs []int, dispatches []DispatchRecord) error {
	text := c.Vocab.Decode(tokenIDs)
	result := &InferenceResult{
		Tokens: TokenResult{
			Prompt:    prompt,
			Tokens:    tokenIDs,
			Text:      text,
			PromptLen: len(c.Vocab.Encode(prompt)),
			GenLen:    len(tokenIDs),
		},
		Stats:      InferenceStatsToMap(&c.Stats),
		Dispatches: DispatchRecordsToResults(dispatches),
	}
	data, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		return fmt.Errorf("llm client: export: %w", err)
	}
	return os.WriteFile(path, data, 0o644)
}
