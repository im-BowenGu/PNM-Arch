package pnm

import (
	"fmt"
)

// ============================================================================
// KV Cache management for the PNM architecture.
//
// The KV cache stores Key and Value tensors for autoregressive inference.
// During prefill, each layer's attention node writes K/V projections into
// the per-direction KV cache bank.  During generation, the banks serve K/V
// reads with single-cycle latency (on-chip SRAM) or multi-cycle latency
// (offloaded to host DRAM via the spine).
//
// Offloading policy: when a bank is full, the oldest entries are evicted
// back to the host.  The firmware estimates re-access time using the
// compile-time latency budget and preloads entries likely to be needed soon.
// ============================================================================

// KVCacheConfig holds the parameters for KV cache sizing.
type KVCacheConfig struct {
	BankDepth    int // entries per bank (seq positions)
	EntryBytes   int // bytes per KV entry (2 * hidden_size * dtype_bytes)
	NumBanks     int // banks per layer (4: one per direction)
	MaxSeqLen    int // maximum sequence length
	OffloadThresh int // eviction threshold (% full)
}

// DefaultKVCacheConfig returns the default configuration for Gemma-4.
func DefaultKVCacheConfig(hiddenSize int) KVCacheConfig {
	// Each KV entry stores K + V projections for one seq position
	// K: hidden_size * head_dim * num_kv_heads (BF16)
	// V: hidden_size * head_dim * num_kv_heads (BF16)
	// Simplified: 2 * hidden_size * 2 bytes (BF16 for both K and V)
	entryBytes := hiddenSize * 4 // K(2B) + V(2B) per hidden dim

	return KVCacheConfig{
		BankDepth:    4096,  // 4K sequence positions per bank
		EntryBytes:   entryBytes,
		NumBanks:     4,     // X+, X-, Y+, Y-
		MaxSeqLen:    16384, // 16K context window
		OffloadThresh: 80,   // evict at 80% full
	}
}

// KVCacheBank models one direction's KV cache bank.
type KVCacheBank struct {
	Direction  string  // "X+", "X-", "Y+", "Y-"
	Depth      int     // max entries
	EntryBytes int     // bytes per entry
	Entries    [][]byte // stored KV entries (nil = empty slot)
	WritePtr   int     // next write position (FIFO)
	ReadPtr    int     // next read position
	Occupancy  int     // entries currently stored
	Full       bool
	Empty      bool
}

// NewKVCacheBank creates a new bank.
func NewKVCacheBank(dir string, depth, entryBytes int) *KVCacheBank {
	entries := make([][]byte, depth)
	return &KVCacheBank{
		Direction:  dir,
		Depth:      depth,
		EntryBytes: entryBytes,
		Entries:    entries,
		WritePtr:   0,
		ReadPtr:    0,
		Occupancy:  0,
		Full:       false,
		Empty:      true,
	}
}

// Store writes a KV entry into the bank. Returns false if full.
func (b *KVCacheBank) Store(entry []byte) bool {
	if b.Full {
		return false
	}
	if len(entry) > b.EntryBytes {
		entry = entry[:b.EntryBytes]
	}
	// Pad if shorter
	padded := make([]byte, b.EntryBytes)
	copy(padded, entry)

	b.Entries[b.WritePtr] = padded
	b.WritePtr = (b.WritePtr + 1) % b.Depth
	b.Occupancy++
	b.Full = (b.Occupancy == b.Depth)
	b.Empty = false
	return true
}

// Load reads a KV entry from the bank by position. Returns nil if the
// position is outside the valid range [WritePtr-Occupancy, WritePtr).
func (b *KVCacheBank) Load(seqPos int) []byte {
	if b.Empty || seqPos < 0 {
		return nil
	}
	// The entry at seqPos is stored at index (seqPos % depth) in the circular buffer.
	idx := seqPos % b.Depth
	if idx < 0 {
		idx += b.Depth
	}
	// Validate that idx is within the live window [ReadPtr, ReadPtr+Occupancy)
	dist := (idx - b.ReadPtr + b.Depth) % b.Depth
	if dist >= b.Occupancy {
		return nil // evicted or never written
	}
	return b.Entries[idx]
}

// Evict removes and returns the oldest entry for offloading. Returns nil if empty.
func (b *KVCacheBank) Evict() []byte {
	if b.Empty {
		return nil
	}
	entry := b.Entries[b.ReadPtr]
	b.Entries[b.ReadPtr] = nil // free memory
	b.ReadPtr = (b.ReadPtr + 1) % b.Depth
	b.Occupancy--
	b.Empty = (b.Occupancy == 0)
	b.Full = false
	return entry
}

// KVCacheLayer holds the 4 directional banks for one physical layer.
type KVCacheLayer struct {
	LayerID   int
	Banks     [4]*KVCacheBank
	Config    KVCacheConfig
	Evictions int
	Reloads   int
}

// NewKVCacheLayer creates a layer with 4 directional banks.
func NewKVCacheLayer(layerID int, cfg KVCacheConfig) *KVCacheLayer {
	dirs := [4]string{"X+", "X-", "Y+", "Y-"}
	kl := &KVCacheLayer{
		LayerID: layerID,
		Config:  cfg,
	}
	for i := 0; i < 4; i++ {
		kl.Banks[i] = NewKVCacheBank(dirs[i], cfg.BankDepth, cfg.EntryBytes)
	}
	return kl
}

// Store distributes a KV entry across banks (round-robin by seq position).
func (kl *KVCacheLayer) Store(seqPos int, entry []byte) bool {
	bankIdx := seqPos % kl.Config.NumBanks
	return kl.Banks[bankIdx].Store(entry)
}

// Load reads a KV entry from the appropriate bank by sequence position.
func (kl *KVCacheLayer) Load(seqPos int) []byte {
	bankIdx := seqPos % kl.Config.NumBanks
	// Position within this bank: entries are distributed round-robin across banks,
	// so the bank-local index is seqPos / numBanks.
	bankLocalPos := seqPos / kl.Config.NumBanks
	return kl.Banks[bankIdx].Load(bankLocalPos)
}

// NeedsOffload returns true if any bank is above the offload threshold.
func (kl *KVCacheLayer) NeedsOffload() bool {
	for _, b := range kl.Banks {
		threshold := b.Depth * kl.Config.OffloadThresh / 100
		if b.Occupancy >= threshold {
			return true
		}
	}
	return false
}

// EvictOldest evicts the oldest entry from the fullest bank.
func (kl *KVCacheLayer) EvictOldest() ([]byte, string) {
	maxOcc := 0
	maxBank := 0
	for i, b := range kl.Banks {
		if b.Occupancy > maxOcc {
			maxOcc = b.Occupancy
			maxBank = i
		}
	}
	entry := kl.Banks[maxBank].Evict()
	if entry != nil {
		kl.Evictions++
		return entry, kl.Banks[maxBank].Direction
	}
	return nil, ""
}

// ============================================================================
// KV Cache Manager: coordinates all layers' KV caches
// ============================================================================

// KVCache manages KV caches across all physical layers.
type KVCache struct {
	Layers   []*KVCacheLayer
	Config   KVCacheConfig
	Dims     Dims
	TotalEvictions int
	TotalReloads   int
}

// NewKVCache creates KV caches for all layers.
func NewKVCache(dims Dims, hiddenSize int) *KVCache {
	cfg := DefaultKVCacheConfig(hiddenSize)
	kc := &KVCache{
		Layers: make([]*KVCacheLayer, dims.Layers),
		Config: cfg,
		Dims:   dims,
	}
	for l := 0; l < dims.Layers; l++ {
		kc.Layers[l] = NewKVCacheLayer(l, cfg)
	}
	return kc
}

// Store writes a KV entry for a given layer and sequence position.
func (kc *KVCache) Store(layer, seqPos int, entry []byte) bool {
	if layer < 0 || layer >= len(kc.Layers) {
		return false
	}
	return kc.Layers[layer].Store(seqPos, entry)
}

// Load reads a KV entry for a given layer and sequence position.
func (kc *KVCache) Load(layer, seqPos int) []byte {
	if layer < 0 || layer >= len(kc.Layers) {
		return nil
	}
	return kc.Layers[layer].Load(seqPos)
}

// OffloadCycle checks all layers and evicts entries that exceed the threshold.
// Returns the number of entries evicted.
func (kc *KVCache) OffloadCycle() int {
	totalEvicted := 0
	for _, kl := range kc.Layers {
		for kl.NeedsOffload() {
			entry, dir := kl.EvictOldest()
			if entry == nil {
				break
			}
			_ = dir // in production, send to host via spine
			totalEvicted++
			kc.TotalEvictions++
		}
	}
	return totalEvicted
}

// Summary returns a human-readable summary of KV cache state.
func (kc *KVCache) Summary() string {
	totalCap := 0
	totalUsed := 0
	for _, kl := range kc.Layers {
		for _, b := range kl.Banks {
			totalCap += b.Depth
			totalUsed += b.Occupancy
		}
	}
	totalBytes := int64(totalUsed) * int64(kc.Config.EntryBytes)
	capBytes := int64(totalCap) * int64(kc.Config.EntryBytes)

	return fmt.Sprintf("KV Cache: %d layers × %d banks × %d entries = %d total, "+
		"%d used (%.1f%%), %.1f MB used / %.1f MB capacity, %d evictions, %d reloads",
		len(kc.Layers), kc.Config.NumBanks, kc.Config.BankDepth,
		totalCap, totalUsed,
		float64(totalUsed)*100/float64(totalCap),
		float64(totalBytes)/1e6, float64(capBytes)/1e6,
		kc.TotalEvictions, kc.TotalReloads)
}

// Verify checks that all banks are internally consistent.
func (kc *KVCache) Verify() error {
	for _, kl := range kc.Layers {
		for _, b := range kl.Banks {
			if b.Occupancy < 0 || b.Occupancy > b.Depth {
				return fmt.Errorf("layer %d bank %s: occupancy %d out of range [0, %d]",
					kl.LayerID, b.Direction, b.Occupancy, b.Depth)
			}
			if b.WritePtr < 0 || b.WritePtr >= b.Depth {
				return fmt.Errorf("layer %d bank %s: write_ptr %d out of range",
					kl.LayerID, b.Direction, b.WritePtr)
			}
			if b.ReadPtr < 0 || b.ReadPtr >= b.Depth {
				return fmt.Errorf("layer %d bank %s: read_ptr %d out of range",
					kl.LayerID, b.Direction, b.ReadPtr)
			}
		}
	}
	return nil
}
