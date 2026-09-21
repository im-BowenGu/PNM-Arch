package pnm

import (
	"fmt"
	"sort"
)

// KVCache is defined in kv_cache.go

// ============================================================================
// Firmware for the PNM central orchestrator chip.
//
// The firmware models the orchestrator chip's boot sequence and runtime dispatch
// loop.  In production, this runs as microcode on the orchestrator chip's embedded
// processor.  In co-simulation, it orchestrates the Go-side driver to feed
// flits into the Verilog fabric in the correct order.
//
// Boot sequence (paper section 2.5):
//   Phase 1: POST Discovery — ping fabric, collect TOPOLOGY_RDY, build inventory
//   Phase 2: Routing Table Load — program lxy_repeaters and HFRs with bitmaps
//   Phase 3: Weight Upload — stream weight blobs through the fabric to node LPDDR6
//   Phase 4: MoE Gating Load — program on-chip SRAM with router.proj weights
//   Phase 5: Ready — begin inference dispatch
//
// Runtime dispatch (paper section 2.8):
//   For each token:
//     For each layer l = 0..num_layers-1:
//       1. Dense path: dispatch to attention node for layer l
//       2. MoE gating: orchestrator_weights[l] . hidden_state -> logits
//       3. Top-K selection: experts = argmax(logits, k)
//       4. For each expert: dispatch to the node holding that expert's weights
//       5. Combine: weighted sum of expert outputs -> hidden_state for next layer
//
// Advanced features:
//   - Flash attention: tiled fused QK^T softmax V kernel (reduces memory bandwidth)
//   - Sliding window: per-layer window enforcement for efficient attention
//   - GQA/MQA: grouped query attention with repeat_kv
//   - Chunked prefill: split long prompts into chunks for pipelining
//   - Continuous batching: interleave prefill and decode across requests
//   - Speculative decoding: draft model + verification for faster generation
// ============================================================================

// FirmwareState represents the current state of the orchestrator chip firmware.
type FirmwareState int

const (
	FWStateReset     FirmwareState = iota // power-on reset
	FWStatePOSTDiscovery                  // Phase 1: topology discovery
	FWStateRoutingTable                   // Phase 2: load routing tables
	FWStateWeightUpload                   // Phase 3: upload weights to nodes
	FWStateMoELoad                        // Phase 4: load gating weights
	FWStateReady                          // Phase 5: inference dispatch
)

// NodeInventory is one discovered node's metadata.
type NodeInventory struct {
	Node      NodeID
	ModuleID  byte
	Bandwidth int  // link bandwidth (GB/s)
	Status    int  // 0=down, 1=ready
}

// ============================================================================
// Flash Attention: tiled fused attention kernel
// ============================================================================

// FlashAttnConfig configures the flash attention tile sizes.
type FlashAttnConfig struct {
	TileSizeQ int // Q tile size (number of rows)
	TileSizeKV int // KV tile size (number of columns)
	Enabled   bool // enable flash attention dispatch
}

// DefaultFlashAttnConfig returns flash attention config for PNM nodes.
func DefaultFlashAttnConfig() FlashAttnConfig {
	return FlashAttnConfig{
		TileSizeQ:  64,  // 64 Q rows per tile
		TileSizeKV: 256, // 256 KV entries per tile
		Enabled:    true,
	}
}

// ============================================================================
// Chunked Prefill
// ============================================================================

// ChunkedPrefillConfig configures chunked prefill parameters.
type ChunkedPrefillConfig struct {
	ChunkSize   int  // tokens per prefill chunk
	Enabled     bool // enable chunked prefill
}

// DefaultChunkedPrefillConfig returns default chunked prefill config.
func DefaultChunkedPrefillConfig() ChunkedPrefillConfig {
	return ChunkedPrefillConfig{
		ChunkSize: 128, // process 128 tokens per chunk
		Enabled:   true,
	}
}

// ============================================================================
// Continuous Batching
// ============================================================================

// RequestState represents one inference request in the continuous batch.
type RequestState struct {
	RequestID   int
	PromptIDs   []int
	Generated   []int
	PrefillPos  int  // next prefill position
	DecodeStep  int  // current decode step
	MaxTokens   int
	Finished    bool
	EOS         int  // end-of-sequence token ID
}

// ContinuousBatch manages multiple concurrent inference requests.
type ContinuousBatch struct {
	Requests    []*RequestState
	MaxBatch    int
	NextReqID   int
}

// NewContinuousBatch creates a continuous batch manager.
func NewContinuousBatch(maxBatch int) *ContinuousBatch {
	if maxBatch <= 0 {
		maxBatch = 8
	}
	return &ContinuousBatch{
		Requests:  make([]*RequestState, 0, maxBatch),
		MaxBatch:  maxBatch,
		NextReqID: 1,
	}
}

// AddRequest adds a new request to the batch.
func (cb *ContinuousBatch) AddRequest(promptIDs []int, maxTokens int) int {
	if len(cb.Requests) >= cb.MaxBatch {
		return -1 // batch full
	}
	reqID := cb.NextReqID
	cb.NextReqID++
	cb.Requests = append(cb.Requests, &RequestState{
		RequestID:  reqID,
		PromptIDs:  promptIDs,
		Generated:  make([]int, 0, maxTokens),
		PrefillPos: 0,
		DecodeStep: 0,
		MaxTokens:  maxTokens,
		Finished:   false,
		EOS:        2,
	})
	return reqID
}

// RemoveFinished removes completed requests from the batch.
func (cb *ContinuousBatch) RemoveFinished() {
	active := cb.Requests[:0]
	for _, req := range cb.Requests {
		if !req.Finished {
			active = append(active, req)
		}
	}
	cb.Requests = active
}

// HasActive returns true if there are active requests.
func (cb *ContinuousBatch) HasActive() bool {
	for _, req := range cb.Requests {
		if !req.Finished {
			return true
		}
	}
	return false
}

// ============================================================================
// Speculative Decoding
// ============================================================================

// SpeculativeConfig configures speculative decoding parameters.
type SpeculativeConfig struct {
	DraftTokens  int  // number of tokens to draft per step
	Enabled      bool // enable speculative decoding
	VerifyAll    bool // verify all drafted tokens (vs. early exit)
}

// DefaultSpeculativeConfig returns default speculative decoding config.
func DefaultSpeculativeConfig() SpeculativeConfig {
	return SpeculativeConfig{
		DraftTokens: 4,   // draft 4 tokens ahead
		Enabled:     false, // disabled by default (paper avoids speculation)
		VerifyAll:   true,
	}
}

// ============================================================================
// Firmware
// ============================================================================

// Firmware is the orchestrator chip's runtime model.
type Firmware struct {
	Driver *Driver
	State  FirmwareState

	// POST discovery results
	Inventory []NodeInventory
	NodeCount int

	// KV cache management
	KV *KVCache

	// Dispatch counters
	DispatchCount int
	WeightCount   int
	ErrorCount    int

	// Advanced feature configs
	FlashAttn       FlashAttnConfig
	ChunkedPrefill  ChunkedPrefillConfig
	Batch           *ContinuousBatch
	Speculative     SpeculativeConfig
	// Sequence positions per model layer (for KV cache addressing)
	SeqPositions    map[int]int // model_layer -> next sequence position
}

// NewFirmware creates a Firmware bound to a Driver.
func NewFirmware(d *Driver) *Firmware {
	hiddenSize := d.Config.TextConfig.HiddenSize
	fw := &Firmware{
		Driver:          d,
		State:           FWStateReset,
		KV:              NewKVCache(d.Dims, hiddenSize, nil),
		FlashAttn:       DefaultFlashAttnConfig(),
		ChunkedPrefill:  DefaultChunkedPrefillConfig(),
		Batch:           NewContinuousBatch(8),
		Speculative:     DefaultSpeculativeConfig(),
		SeqPositions:    make(map[int]int),
	}
	// Configure sliding window attention from model config.  Called even
	// without per-model layer_types (Mistral/Gemma-1 style configs): the KV
	// layer is then marked sliding for every physical layer.
	if d.Config.TextConfig.SlidingWindow > 0 {
		fw.KV.ConfigureSlidingWindow(d.Config.TextConfig.SlidingWindow, d.Config.TextConfig.LayerTypes)
	}
	// Configure GQA from model config
	tc := &d.Config.TextConfig
	if tc.NumKeyValueHeads > 0 && tc.NumAttentionHeads > 0 {
		fw.KV.ConfigureGQA(tc.NumAttentionHeads, tc.NumKeyValueHeads, tc.HeadDim)
	}
	return fw
}

// ============================================================================
// Boot sequence
// ============================================================================

// BootPhase runs one phase of the boot sequence.  Returns the flit commands
// generated during this phase (to be injected into the fabric) and any error.
func (fw *Firmware) BootPhase() ([]WeightUploadCommand, error) {
	switch fw.State {
	case FWStateReset:
		return fw.bootPOSTDiscovery()
	case FWStatePOSTDiscovery:
		return fw.bootRoutingTable()
	case FWStateRoutingTable:
		return fw.bootWeightUpload()
	case FWStateWeightUpload:
		return fw.bootMoELoad()
	case FWStateMoELoad:
		fw.State = FWStateReady
		return nil, nil
	default:
		return nil, fmt.Errorf("firmware: unexpected boot phase %d", fw.State)
	}
}

// bootPOSTDiscovery: ping the fabric and discover all nodes.
func (fw *Firmware) bootPOSTDiscovery() ([]WeightUploadCommand, error) {
	fw.Inventory = nil
	fw.NodeCount = 0

	dims := fw.Driver.Dims
	for l := 0; l < dims.Layers; l++ {
		for x := 0; x < dims.Bx; x++ {
			for y := 0; y < dims.By; y++ {
				nid := NodeID{L: l, X: x, Y: y}
				moduleID := byte((x << 4) | y)
				fw.Inventory = append(fw.Inventory, NodeInventory{
					Node:      nid,
					ModuleID:  moduleID,
					Bandwidth: 256, // LPDDR6 CAMM2: 256 GB/s per node
					Status:    1,
				})
				fw.NodeCount++
			}
		}
	}

	fw.State = FWStatePOSTDiscovery
	return nil, nil
}

// bootRoutingTable: generate the commands to program routing bitmaps.
func (fw *Firmware) bootRoutingTable() ([]WeightUploadCommand, error) {
	fw.State = FWStateRoutingTable
	return nil, nil
}

// bootWeightUpload: generate weight upload commands for all nodes.
func (fw *Firmware) bootWeightUpload() ([]WeightUploadCommand, error) {
	cmds, err := fw.Driver.BuildWeightCommands()
	if err != nil {
		return nil, fmt.Errorf("firmware: weight upload: %w", err)
	}
	fw.WeightCount = len(cmds)
	fw.State = FWStateWeightUpload
	return cmds, nil
}

// bootMoELoad: generate commands to load MoE gating weights into the router
// chip's on-chip SRAM.
func (fw *Firmware) bootMoELoad() ([]WeightUploadCommand, error) {
	fw.State = FWStateMoELoad
	return nil, nil
}

// ============================================================================
// Inference dispatch
// ============================================================================

// DispatchRecord is one step in the inference dispatch sequence.
type DispatchRecord struct {
	Layer      int              // model layer index
	Phase      string           // "dense", "moe", "kv_offload", "flash_attn"
	TargetNode NodeID           // destination node
	ExpertIdx  int              // -1 for dense, >= 0 for MoE
	FlitBytes  int              // flit wire length
	KVAction   string           // "store", "load", "evict", or "" (none)
	CUType     ComputeUnitType  // compute unit to use on target node
	TensorRole string           // tensor role for dispatch routing
	// Flash attention metadata
	FlashTileQ  int  // Q tile index
	FlashTileKV int  // KV tile index
	FlashNumTiles int // total KV tiles
	// Chunked prefill metadata
	ChunkIndex  int  // prefill chunk index
	ChunkTotal  int  // total prefill chunks
	// GQA metadata
	RepeatKV    bool // true if KV heads need repetition for GQA
	GroupSize   int  // GQA group size
	// Sliding window metadata
	WindowStart int  // sliding window start position (-1 = full attention)
	WindowEnd   int  // sliding window end position
}

// PlanInference computes the full dispatch sequence for one token through
// all transformer layers.  Returns the sequence of dispatch records and the
// weight flit commands to inject.  After each layer's attention step, the
// firmware checks whether KV offloading is needed.
func (fw *Firmware) PlanInference(token []byte) ([]DispatchRecord, error) {
	if fw.State != FWStateReady {
		return nil, fmt.Errorf("firmware: not ready (state=%d)", fw.State)
	}

	tc := &fw.Driver.Config.TextConfig
	dims := fw.Driver.Dims
	nodesPerLayer := dims.Bx * dims.By

	var records []DispatchRecord

	for ml := 0; ml < tc.NumHiddenLayers; ml++ {
		pl := fw.physLayerOf(ml)

		// Step 1: Dense path — dispatch to attention node
		attnNodeIdx := ml % nodesPerLayer
		attnX := attnNodeIdx / dims.By
		attnY := attnNodeIdx % dims.By
		attnNode := NodeID{L: pl, X: attnX, Y: attnY}

		// Per-model-layer sliding window (not the physical layer's collapsed flag)
		isSliding, slidingWin := fw.layerIsSliding(ml)
		kl := fw.KV.Layers[pl]
		windowStart := -1
		windowEnd := -1
		seqPos := fw.SeqPositions[ml]

		if isSliding && slidingWin > 0 {
			windowEnd = seqPos
			windowStart = seqPos - slidingWin + 1
			if windowStart < 0 {
				windowStart = 0
			}
		}

		// Check if GQA repeat_kv is needed
		needRepeatKV := kl.GroupSize > 1

		// Flash attention: dispatch tiled QK^T softmax V
		if fw.FlashAttn.Enabled {
			numKVTiles := (seqPos + fw.FlashAttn.TileSizeKV) / fw.FlashAttn.TileSizeKV
			if numKVTiles < 1 {
				numKVTiles = 1
			}
			for kvTile := 0; kvTile < numKVTiles; kvTile++ {
				flit := Flit(pl+1, (attnX<<4)|attnY, CTRL_COMPUTE_SPINE, token, false)
				records = append(records, DispatchRecord{
					Layer:       ml,
					Phase:       "flash_attn",
					TargetNode:  attnNode,
					ExpertIdx:   -1,
					FlitBytes:   len(flit),
					KVAction:    "store",
					CUType:      CUTypeBF16Array,
					TensorRole:  "attn_q",
					FlashTileQ:  0,
					FlashTileKV: kvTile,
					FlashNumTiles: numKVTiles,
					RepeatKV:    needRepeatKV,
					GroupSize:   kl.GroupSize,
					WindowStart: windowStart,
					WindowEnd:   windowEnd,
				})
			}
			// KV cache load for the tiled attention
			records = append(records, DispatchRecord{
				Layer:       ml,
				Phase:       "flash_attn",
				TargetNode:  attnNode,
				ExpertIdx:   -1,
				FlitBytes:   0,
				KVAction:    "load",
				CUType:      CUTypeBF16Array,
				TensorRole:  "attn_kv_load",
				RepeatKV:    needRepeatKV,
				GroupSize:   kl.GroupSize,
				WindowStart: windowStart,
				WindowEnd:   windowEnd,
			})
		} else {
			// Standard attention dispatch
			flit := Flit(pl+1, (attnX<<4)|attnY, CTRL_COMPUTE_SPINE, token, false)
			records = append(records, DispatchRecord{
				Layer:       ml,
				Phase:       "dense",
				TargetNode:  attnNode,
				ExpertIdx:   -1,
				FlitBytes:   len(flit),
				KVAction:    "store",
				CUType:      CUTypeBF16Array,
				TensorRole:  "attn_q",
				RepeatKV:    needRepeatKV,
				GroupSize:   kl.GroupSize,
				WindowStart: windowStart,
				WindowEnd:   windowEnd,
			})
			// KV cache load
			records = append(records, DispatchRecord{
				Layer:       ml,
				Phase:       "dense",
				TargetNode:  attnNode,
				ExpertIdx:   -1,
				FlitBytes:   0,
				KVAction:    "load",
				CUType:      CUTypeBF16Array,
				TensorRole:  "attn_kv_load",
				RepeatKV:    needRepeatKV,
				GroupSize:   kl.GroupSize,
				WindowStart: windowStart,
				WindowEnd:   windowEnd,
			})
		}

		// Step 2: KV cache check — offload if needed
		if fw.KV != nil && fw.KV.Layers[pl].NeedsOffload() {
			records = append(records, DispatchRecord{
				Layer:      ml,
				Phase:      "kv_offload",
				TargetNode: attnNode,
				ExpertIdx:  -1,
				FlitBytes:  0,
				KVAction:   "evict",
				CUType:     CUTypeNone,
			})
			fw.KV.OffloadCycle()
		}

		// Step 3: MoE gating — dispatch to top-k experts.  Gating scores every
		// expert for this (token, layer) and routes to the top-k by global expert
		// index, so routing is token-dependent and the full expert population
		// (not just experts 0..TopK-1) is reachable.  The candidate population
		// is the layer's actual expert indices from the map (may be sparse); we
		// score by those global indices, mirroring the C firmware.
		var population []int
		for mk := range fw.Driver.MoeMap {
			if mk.ModelLayer == ml {
				population = append(population, mk.ExpertIdx)
			}
		}
		sort.Ints(population)
		for _, expIdx := range selectTopExperts(token, ml, population, tc.TopKExperts) {
			key := MoeKey{ModelLayer: ml, ExpertIdx: expIdx}
			expertNode, ok := fw.Driver.MoeMap[key]
			if !ok {
				continue
			}

			flit := Flit(expertNode.L+1, (expertNode.X<<4)|expertNode.Y,
				CTRL_COMPUTE_SPINE, token, false)
			records = append(records, DispatchRecord{
				Layer:      ml,
				Phase:      "moe",
				TargetNode: expertNode,
				ExpertIdx:  expIdx,
				FlitBytes:  len(flit),
				CUType:     CUTypeBF16FMA,
				TensorRole: "expert_gate_up",
			})
		}

		// Update sequence position for this layer
		fw.SeqPositions[ml] = seqPos + 1
	}

	fw.DispatchCount += len(records)
	return records, nil
}

// selectTopExperts returns the top-k global expert indices for a token and
// model layer, chosen by a deterministic gating score.  The score is seeded
// from the token bytes and the model layer, and each expert in the layer's
// actual population is scored so that routing varies across tokens and layers
// while remaining reproducible for a given input (paper determinism).
//
// experts holds the layer's actual global expert indices (the candidate
// population).  Each candidate is scored by its GLOBAL index, mirroring the C
// firmware's select_topk (fw/pnm_fw.c) which scores by the actual expert_idx
// in the map -- so both twins agree even for sparse per-layer populations
// where the candidate set is not exactly 0..N-1.
func selectTopExperts(token []byte, ml int, experts []int, topK int) []int {
	if len(experts) <= 0 {
		return nil
	}
	if topK > len(experts) {
		topK = len(experts)
	}
	// Deterministic per-token per-layer seed (FNV-1a over token plus layer).
	h := uint64(14695981039346656037)
	for _, b := range token {
		h ^= uint64(b)
		h *= 1099511628211
	}
	h ^= uint64(ml) * 0x9E3779B97F4A7C15
	h = (h * 1099511628211) >> 0

	// Score every expert in the population, keyed by global index, with a
	// stable (score, expert) tiebreak.
	type scored struct {
		score  uint64
		expert int
	}
	scores := make([]scored, len(experts))
	for i, ex := range experts {
		sh := h ^ uint64(ex)*0x2545F4914F6CDD1D
		sh ^= sh >> 33
		sh *= 0xFF51AFD7ED558CCD
		sh ^= sh >> 33
		scores[i] = scored{score: sh, expert: ex}
	}
	sort.Slice(scores, func(i, j int) bool {
		if scores[i].score != scores[j].score {
			return scores[i].score > scores[j].score
		}
		return scores[i].expert < scores[j].expert
	})
	out := make([]int, topK)
	for i := 0; i < topK; i++ {
		out[i] = scores[i].expert
	}
	return out
}

// layerIsSliding reports whether the given model layer uses sliding window
// attention.  It consults the model's per-layer type list when present,
// falling back to the physical layer's KV-cache flag for models without one.
func (fw *Firmware) layerIsSliding(ml int) (bool, int) {
	tc := &fw.Driver.Config.TextConfig
	if len(tc.LayerTypes) > 0 && ml >= 0 && ml < len(tc.LayerTypes) {
		sliding := tc.LayerTypes[ml] == "sliding_attention"
		if sliding {
			if tc.SlidingWindow > 0 {
				return true, tc.SlidingWindow
			}
			return true, fw.KV.Layers[fw.physLayerOf(ml)].SlidingWindow
		}
		return false, 0
	}
	pl := fw.physLayerOf(ml)
	kl := fw.KV.Layers[pl]
	return kl.IsSliding, kl.SlidingWindow
}

// physLayerOf maps a model layer index to its physical layer on the chassis.
func (fw *Firmware) physLayerOf(ml int) int {
	tc := &fw.Driver.Config.TextConfig
	dims := fw.Driver.Dims
	perPhysical := (tc.NumHiddenLayers + dims.Layers - 1) / dims.Layers
	pl := ml / perPhysical
	if pl >= dims.Layers {
		pl = dims.Layers - 1
	}
	return pl
}

// PlanInferenceChunked computes the dispatch sequence for a prefill chunk.
// Splits the prompt into chunks of ChunkSize tokens and returns dispatch records.
func (fw *Firmware) PlanInferenceChunked(promptIDs []int) ([][]DispatchRecord, error) {
	if fw.State != FWStateReady {
		return nil, fmt.Errorf("firmware: not ready (state=%d)", fw.State)
	}

	chunkSize := fw.ChunkedPrefill.ChunkSize
	if chunkSize <= 0 {
		chunkSize = len(promptIDs)
	}

	var chunks [][]DispatchRecord
	for start := 0; start < len(promptIDs); start += chunkSize {
		end := start + chunkSize
		if end > len(promptIDs) {
			end = len(promptIDs)
		}
		chunk := promptIDs[start:end]
		_ = chunk // in production, dispatch this chunk's tokens

		// For each token in the chunk, plan inference
		var chunkRecords []DispatchRecord
		for i, id := range chunk {
			_ = i
			tokenBytes := encodeTokenID(id, CUTypeBF16FMA)
			records, err := fw.PlanInference(tokenBytes)
			if err != nil {
				return nil, fmt.Errorf("firmware: chunked prefill at offset %d: %w", start+i, err)
			}
			chunkRecords = append(chunkRecords, records...)
		}
		chunks = append(chunks, chunkRecords)
	}
	return chunks, nil
}

// PlanInferenceSpeculative performs speculative decoding: draft multiple tokens
// with a lightweight model, then verify all at once with the main model.
// Returns only the tokens that match between draft and main model (up to first mismatch).
func (fw *Firmware) PlanInferenceSpeculative(prevToken int) ([][]DispatchRecord, []int, error) {
	if fw.State != FWStateReady {
		return nil, nil, fmt.Errorf("firmware: not ready (state=%d)", fw.State)
	}

	draftCount := fw.Speculative.DraftTokens
	if draftCount <= 0 {
		draftCount = 1
	}

	// Phase 1: Draft tokens (lightweight model — uses same dispatch but with fewer layers)
	// Save SeqPositions so the draft phase doesn't advance them (only the final accepted tokens should).
	savedPositions := make(map[int]int)
	for k, v := range fw.SeqPositions {
		savedPositions[k] = v
	}
	var draftRecords [][]DispatchRecord
	drafted := make([]int, 0, draftCount)
	currentToken := prevToken
	for i := 0; i < draftCount; i++ {
		tokenBytes := encodeTokenID(currentToken, CUTypeBF16FMA)
		records, err := fw.PlanInference(tokenBytes)
		if err != nil {
			return nil, nil, err
		}
		draftRecords = append(draftRecords, records)
		nextToken := fw.predictDraftToken(currentToken, i)
		drafted = append(drafted, nextToken)
		currentToken = nextToken
	}
	// Restore positions — draft phase was speculative, not committed.  Rebuild
	// the map from scratch so any model-layer keys the draft phase created (that
	// were not present before) are fully removed, not just re-valued.
	fw.SeqPositions = make(map[int]int, len(savedPositions))
	for k, v := range savedPositions {
		fw.SeqPositions[k] = v
	}

	// Base positions after the (rolled-back) draft phase.  The verify phase
	// below advances positions once per drafted token, but only the accepted
	// prefix should be committed, so we rewrite positions to base + accepted
	// per model layer after acceptance is determined.
	basePositions := make(map[int]int, len(fw.SeqPositions))
	for k, v := range fw.SeqPositions {
		basePositions[k] = v
	}

	// Phase 2: Verify all drafted tokens at once (main model)
	// In real speculative decoding, the main model processes the entire sequence
	// and we compare its predictions against draft tokens.
	var verifyRecords [][]DispatchRecord
	for _, tok := range drafted {
		tokenBytes := encodeTokenID(tok, CUTypeBF16FMA)
		records, err := fw.PlanInference(tokenBytes)
		if err != nil {
			return nil, nil, err
		}
		verifyRecords = append(verifyRecords, records)
	}

	// Phase 3: Accept tokens until first mismatch
	// The draft model is a lightweight stub; the main model is the real inference.
	// We compare by re-running the draft model's prediction and checking if it
	// matches what the main model would predict. In this simulation, we use
	// the draft model's own prediction as the "main model" output since both
	// are deterministic stubs. In production, you'd compare actual logits.
	accepted := make([]int, 0, len(drafted))
	acceptedRecords := make([][]DispatchRecord, 0, len(draftRecords))

	// Chain the token stream through verification (matching draft phase)
	verifyToken := prevToken
	for i, draftTok := range drafted {
		// Simulate main model prediction (in production, this comes from actual logits)
		mainPrediction := fw.predictDraftToken(verifyToken, i)

		// Accept if draft matches main model prediction
		if draftTok == mainPrediction {
			accepted = append(accepted, draftTok)
			acceptedRecords = append(acceptedRecords, draftRecords[i])
			verifyToken = draftTok
		} else {
			// Mismatch: reject this and all subsequent draft tokens
			// Add the main model's correct prediction instead
			accepted = append(accepted, mainPrediction)
			acceptedRecords = append(acceptedRecords, verifyRecords[i])
			break
		}
	}

	// Commit positions: only the accepted tokens advance the sequence
	// positions.  The verify phase advanced basePositions once per drafted
	// token; rewrite so each model layer reflects exactly len(accepted) new
	// tokens rather than len(drafted).
	for k := range fw.SeqPositions {
		fw.SeqPositions[k] = basePositions[k] + len(accepted)
	}

	return acceptedRecords, accepted, nil
}

// predictDraftToken produces a draft token prediction (lightweight model).
func (fw *Firmware) predictDraftToken(prevToken, step int) int {
	h := prevToken*31 + step*17 + fw.Driver.Dims.Layers*7
	h = h ^ (h >> 13)
	h = h * 0x5bd1e995
	h = h ^ (h >> 15)
	token := h % fw.Driver.Config.TextConfig.VocabSize
	if token < 0 {
		token = -token
	}
	return token
}

// ============================================================================
// Verification helpers
// ============================================================================

// VerifyWeightUpload checks that the weight upload commands match the
// AOT compilation: correct targets, correct sizes, no budget overflow.
func (fw *Firmware) VerifyWeightUpload(cmds []WeightUploadCommand) error {
	nodeBytes := map[NodeID]int64{}
	for _, cmd := range cmds {
		nid := NodeID{
			L: cmd.TargetLayer,
			X: int(cmd.TargetModule >> 4),
			Y: int(cmd.TargetModule & 0x0F),
		}
		nodeBytes[nid] += cmd.SizeBytes
	}

	for nid, total := range nodeBytes {
		if total > fw.Driver.MC.PerNodeBudget {
			return fmt.Errorf("firmware: node %s: %.1f GB exceeds %.1f GB budget",
				nid, float64(total)/1e9, float64(fw.Driver.MC.PerNodeBudget)/1e9)
		}
	}

	for nid, na := range fw.Driver.MC.NodeAssignments {
		if nid.L < 0 || na.TotalBytes == 0 {
			continue
		}
		if _, ok := nodeBytes[nid]; !ok {
			return fmt.Errorf("firmware: node %s has %d bytes assigned but received 0",
				nid, na.TotalBytes)
		}
	}

	return nil
}

// VerifyDispatch checks that the dispatch sequence covers all required targets.
func (fw *Firmware) VerifyDispatch(records []DispatchRecord) error {
	type layerTarget struct {
		layer  int
		target NodeID
	}
	seen := map[layerTarget]bool{}
	for _, r := range records {
		if r.Phase != "kv_offload" {
			seen[layerTarget{r.Layer, r.TargetNode}] = true
		}
	}

	tc := &fw.Driver.Config.TextConfig
	dims := fw.Driver.Dims
	nodesPerLayer := dims.Bx * dims.By
	modelLayersPerPhysical := (tc.NumHiddenLayers + dims.Layers - 1) / dims.Layers

	for ml := 0; ml < tc.NumHiddenLayers; ml++ {
		pl := ml / modelLayersPerPhysical
		if pl >= dims.Layers {
			pl = dims.Layers - 1
		}
		attnNodeIdx := ml % nodesPerLayer
		attnX := attnNodeIdx / dims.By
		attnY := attnNodeIdx % dims.By
		key := layerTarget{ml, NodeID{L: pl, X: attnX, Y: attnY}}
		if !seen[key] {
			return fmt.Errorf("dispatch: layer %d attention node %s not covered", ml, key.target)
		}
	}

	return nil
}

// ============================================================================
// Summary
// ============================================================================

// Summary returns a human-readable summary of the firmware state.
func (fw *Firmware) Summary() string {
	return fmt.Sprintf("Firmware: state=%d nodes=%d dispatches=%d weights=%d errors=%d, "+
		"flash_attn=%v, chunked_prefill=%v(batch=%d), speculative=%v(draft=%d)",
		fw.State, fw.NodeCount, fw.DispatchCount, fw.WeightCount, fw.ErrorCount,
		fw.FlashAttn.Enabled, fw.ChunkedPrefill.Enabled, fw.ChunkedPrefill.ChunkSize,
		fw.Speculative.Enabled, fw.Speculative.DraftTokens)
}

// DispatchSummary returns the dispatch plan as a formatted string.
func (fw *Firmware) DispatchSummary(records []DispatchRecord) string {
	var s string
	s += "# Firmware dispatch plan\n"
	s += fmt.Sprintf("# Total dispatches: %d\n", len(records))
	s += fmt.Sprintf("# KV cache: %s\n", fw.KV.Summary())
	s += fmt.Sprintf("# Flash attention: tile_q=%d tile_kv=%d\n", fw.FlashAttn.TileSizeQ, fw.FlashAttn.TileSizeKV)
	s += fmt.Sprintf("# Chunked prefill: chunk_size=%d\n", fw.ChunkedPrefill.ChunkSize)
	s += fmt.Sprintf("# Speculative: draft_tokens=%d\n", fw.Speculative.DraftTokens)
	s += "#\n"
	s += "# Layer | Phase     | Target       | Expert | FlitBytes | CU            | KV      | Window     | GQA\n"
	s += "#-------+-----------+--------------+--------+-----------+---------------+---------+------------+----\n"

	currentLayer := -1
	for _, r := range records {
		if r.Layer != currentLayer {
			s += fmt.Sprintf("#\n")
			currentLayer = r.Layer
		}
		expertStr := "dense"
		if r.ExpertIdx >= 0 {
			expertStr = fmt.Sprintf("exp_%d", r.ExpertIdx)
		}
		kvStr := r.KVAction
		if kvStr == "" {
			kvStr = "-"
		}
		windowStr := "full"
		if r.WindowStart >= 0 {
			windowStr = fmt.Sprintf("[%d:%d]", r.WindowStart, r.WindowEnd)
		}
		gqaStr := "-"
		if r.RepeatKV {
			gqaStr = fmt.Sprintf("x%d", r.GroupSize)
		}
		s += fmt.Sprintf("#   %2d  | %-9s | %-12s | %-6s | %9d | %-13s | %-7s | %-10s | %s\n",
			r.Layer, r.Phase, r.TargetNode, expertStr, r.FlitBytes, r.CUType, kvStr, windowStr, gqaStr)
	}

	return s
}

// ============================================================================
// Sort helper
// ============================================================================

func sortedNodes(m map[NodeID]*NodeAssignment) []NodeID {
	var nodes []NodeID
	for nid := range m {
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
	return nodes
}
