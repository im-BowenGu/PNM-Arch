package pnm

import (
	"crypto/sha256"
	"encoding/binary"
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
// Features:
//   - Paged attention: virtual-to-physical page mapping for non-contiguous
//     KV storage, enabling memory-efficient attention across sequences.
//   - Prefix caching: hash-based sharing of common KV prefixes across
//     requests, reducing redundant computation for repeated prompts.
//   - Sliding window attention: per-layer window enforcement for models
//     like Gemma-4 that mix full and sliding attention layers.
//   - GQA/MQA support: proper head grouping with repeat_kv for models
//     where num_kv_heads < num_attention_heads.
//
// Offloading policy: when a bank is full, the oldest entries are evicted
// back to the host.  The firmware estimates re-access time using the
// compile-time latency budget and preloads entries likely to be needed soon.
// ============================================================================

// EvictionMode controls where evicted KV cache entries are routed.
//
// In production, entries that exceed the on-chip budget must go somewhere:
// discard them (lossy, simple), DMA them back to the host BMC (moderate
// bandwidth, round-trip latency), or write them to NVMe (high bandwidth,
// persists across reboots but requires flash controller).
//
// The compile-time parameter on kv_offload.v mirrors this: an
// EVICTION_TARGET localparam selects the hardware path at synthesis.
type EvictionMode int

const (
	// EvictNone discards evicted entries — the default for small context
	// windows that fit entirely in on-chip SRAM.
	EvictNone EvictionMode = iota
	// EvictDmaBmc routes evicted entries to the host BMC via DMA
	// over the spine fabric. Requires a DMA controller on the BMC side.
	EvictDmaBmc
	// EvictNvme routes evicted entries to an attached NVMe device via
	// the orchestrator chip's PCIe bridge. Provides persistent, high-bandwidth
	// overflow storage.
	EvictNvme
)

// ============================================================================
// Paged Attention: virtual-to-physical page table
// ============================================================================

// PageSize is the number of KV entries per page (power of 2 for fast indexing).
const PageSize = 16

// PageTableEntry maps a virtual page to a physical page in SRAM.
type PageTableEntry struct {
	PhysicalPage int  // physical page index in SRAM (-1 = not resident)
	RefCount     int  // number of sequences sharing this page (for prefix caching)
	Dirty        bool // true if modified since last evict
}

// PageTable manages virtual-to-physical address translation for paged attention.
// Each sequence gets a virtual address space; the page table maps virtual pages
// to physical SRAM pages, enabling non-contiguous KV storage and page-level
// sharing across sequences (prefix caching).
type PageTable struct {
	Entries   []PageTableEntry // virtual page -> physical page mapping
	NumPages  int              // total virtual pages
	PhysPages int              // total physical SRAM pages
	FreeList  []int            // stack of free physical pages
	Allocated int              // pages currently allocated
}

// NewPageTable creates a page table with the given capacities.
func NewPageTable(virtPages, physPages int) *PageTable {
	pt := &PageTable{
		Entries:   make([]PageTableEntry, virtPages),
		NumPages:  virtPages,
		PhysPages: physPages,
		FreeList:  make([]int, physPages),
	}
	// Initialize free list (all physical pages available)
	for i := 0; i < physPages; i++ {
		pt.FreeList[i] = physPages - 1 - i // stack order: pop gives lowest index
	}
	// Initialize all virtual pages as not resident
	for i := range pt.Entries {
		pt.Entries[i].PhysicalPage = -1
	}
	return pt
}

// AllocPage allocates a physical page for a virtual page.
// Returns the physical page index, or -1 if no pages available.
func (pt *PageTable) AllocPage(virtPage int) int {
	if virtPage < 0 || virtPage >= pt.NumPages {
		return -1
	}
	if pt.Entries[virtPage].PhysicalPage >= 0 {
		return pt.Entries[virtPage].PhysicalPage // already allocated
	}
	if len(pt.FreeList) == 0 {
		return -1 // out of physical pages
	}
	physPage := pt.FreeList[len(pt.FreeList)-1]
	pt.FreeList = pt.FreeList[:len(pt.FreeList)-1]
	pt.Entries[virtPage].PhysicalPage = physPage
	pt.Entries[virtPage].RefCount = 1
	pt.Allocated++
	return physPage
}

// FreePage frees a physical page, returning it to the free list.
func (pt *PageTable) FreePage(virtPage int) {
	if virtPage < 0 || virtPage >= pt.NumPages {
		return
	}
	pe := &pt.Entries[virtPage]
	if pe.PhysicalPage < 0 {
		return // already free
	}
	pe.RefCount--
	if pe.RefCount <= 0 {
		pt.FreeList = append(pt.FreeList, pe.PhysicalPage)
		pt.Allocated--
		pe.PhysicalPage = -1
		pe.RefCount = 0
	}
}

// Translate maps a virtual page to a physical page.
func (pt *PageTable) Translate(virtPage int) int {
	if virtPage < 0 || virtPage >= pt.NumPages {
		return -1
	}
	return pt.Entries[virtPage].PhysicalPage
}

// SharePage increments the refcount on a virtual page (for prefix caching).
func (pt *PageTable) SharePage(virtPage int) {
	if virtPage >= 0 && virtPage < pt.NumPages {
		if pt.Entries[virtPage].PhysicalPage >= 0 {
			pt.Entries[virtPage].RefCount++
		}
	}
}

// ============================================================================
// Prefix Caching: hash-based KV prefix sharing
// ============================================================================

// PrefixCacheEntry stores a cached prefix's metadata.
type PrefixCacheEntry struct {
	PrefixHash [32]byte // SHA-256 hash of the prefix token sequence
	Layer      int      // model layer index
	VirtPages  []int    // virtual pages holding this prefix's KV data
	HitCount   int      // number of cache hits
}

// PrefixCache manages hash-based prefix sharing across requests.
type PrefixCache struct {
	Entries map[[32]byte]*PrefixCacheEntry // hash -> cache entry
	MaxSize int                            // max entries before LRU eviction
	Hits    int                            // total cache hits
	Misses  int                            // total cache misses
}

// NewPrefixCache creates a new prefix cache.
func NewPrefixCache(maxSize int) *PrefixCache {
	if maxSize <= 0 {
		maxSize = 1024
	}
	return &PrefixCache{
		Entries: make(map[[32]byte]*PrefixCacheEntry),
		MaxSize: maxSize,
	}
}

// HashPrefix computes the SHA-256 hash of a token sequence.
func HashPrefix(tokens []int) [32]byte {
	buf := make([]byte, len(tokens)*4)
	for i, t := range tokens {
		binary.LittleEndian.PutUint32(buf[i*4:], uint32(t))
	}
	return sha256.Sum256(buf)
}

// Lookup checks if a prefix is cached. Returns the entry or nil.
func (pc *PrefixCache) Lookup(tokens []int) *PrefixCacheEntry {
	hash := HashPrefix(tokens)
	if entry, ok := pc.Entries[hash]; ok {
		pc.Hits++
		entry.HitCount++
		return entry
	}
	pc.Misses++
	return nil
}

// Store adds a prefix to the cache. Evicts LRU if full.
func (pc *PrefixCache) Store(tokens []int, layer int, virtPages []int) {
	hash := HashPrefix(tokens)
	if existing, ok := pc.Entries[hash]; ok {
		existing.HitCount++
		return
	}
	pc.Entries[hash] = &PrefixCacheEntry{
		PrefixHash: hash,
		Layer:      layer,
		VirtPages:  virtPages,
		HitCount:   1,
	}
	// Simple eviction: if over capacity, remove the entry with lowest hit count,
	// skipping the entry we just added so a full cache isn't thrash-evicted.
	if len(pc.Entries) > pc.MaxSize {
		var minHash [32]byte
		minHits := int(^uint(0) >> 1) // max int
		for h, e := range pc.Entries {
			if h == hash {
				continue // never evict the just-added entry
			}
			if e.HitCount < minHits {
				minHits = e.HitCount
				minHash = h
			}
		}
		delete(pc.Entries, minHash)
	}
}

// ============================================================================
// KV Cache Configuration
// ============================================================================

// KVCacheConfig holds the parameters for KV cache sizing.
type KVCacheConfig struct {
	BankDepth     int          // entries per bank (seq positions)
	EntryBytes    int          // bytes per KV entry (2 * kv_hidden_size * dtype_bytes)
	NumBanks      int          // banks per layer (4: one per direction)
	MaxSeqLen     int          // maximum sequence length
	OffloadThresh int          // eviction threshold (% full)
	EvictMode     EvictionMode // where evicted entries go
	NVMeBase      uint32       // base address of NVMe controller (0xC0000000)
	NVMeLBAStart  uint64       // first LBA for KV overflow region
	NVMeLBAEnd    uint64       // last LBA (exclusive) for KV overflow region
	SlidingWindow int          // sliding window length (0 = full attention for all layers)
	// Paged attention parameters
	PageSize     int  // entries per page (must be power of 2)
	EnablePaging bool // enable paged attention (virtual-to-physical mapping)
	EnablePrefix bool // enable prefix caching
	MaxPages     int  // max physical pages per layer
	MaxVirtPages int  // max virtual pages per sequence
	// GQA parameters
	NumAttentionHeads int // number of Q heads
	NumKeyValueHeads  int // number of KV heads (for GQA: < num_attention_heads)
	HeadDim           int // dimension per head
}

// DefaultKVCacheConfig returns the default configuration.
// entryBytes is pinned to the RTL frame: the co-sim instantiates
// kv_cache_bank with ENTRY_BYTES(512) / BANK_DEPTH(1024) (gen_topology.go),
// so the Go accounting must use the identical per-entry size for any
// model — a hiddenSize-derived frame (2*K+V projections * hiddenSize *
// dtype_bytes) only coincides with silicon for hidden 128, and silently
// inflating EntryBytes would overstate paper capacity numbers. Callers
// that need model-accurate GQA frames set EntryBytes explicitly.
func DefaultKVCacheConfig(hiddenSize int) KVCacheConfig {
	// Each KV entry stores K + V projections for one seq position.
	// RTL kv_cache_bank uses ENTRY_BYTES=512 (fixed frame size),
	// BANK_DEPTH=1024 (SRAM capacity per direction bank).
	entryBytes := 512 // must match RTL kv_cache_bank ENTRY_BYTES parameter
	_ = hiddenSize    // model-derived sizing is the caller's explicit choice

	return KVCacheConfig{
		BankDepth:     1024, // must match RTL kv_cache_bank BANK_DEPTH parameter
		EntryBytes:    entryBytes,
		NumBanks:      4,          // X+, X-, Y+, Y-
		MaxSeqLen:     16384,      // 16K context window
		OffloadThresh: 80,         // evict at 80% full
		EvictMode:     EvictNone,  // default: discard
		NVMeBase:      0xC0000000, // PCIe NVMe BAR
		NVMeLBAStart:  0,
		NVMeLBAEnd:    1048576, // 512 GB at 512B blocks
		SlidingWindow: 0,       // 0 = full attention (overridden per-model)
		PageSize:      PageSize,
		EnablePaging:  true,
		EnablePrefix:  true,
		MaxPages:      256,  // 256 physical pages * 16 entries * 512 bytes = 2 MB per layer
		MaxVirtPages:  1024, // 1024 virtual pages = 16K entries max sequence length
	}
}

// KVCacheEntryConfig holds per-model KV cache parameters derived from the model config.
type KVCacheEntryConfig struct {
	NumAttentionHeads int      // number of Q heads
	NumKeyValueHeads  int      // number of KV heads (for GQA: < num_attention_heads)
	HeadDim           int      // dimension per head
	SlidingWindow     int      // sliding window length (0 = full attention)
	LayerTypes        []string // per-model-layer attention type ("full_attention" or "sliding_attention")
}

// ============================================================================
// KV Cache Bank (physical SRAM page)
// ============================================================================

// KVCacheBank models one direction's KV cache bank.
type KVCacheBank struct {
	Direction  string   // "X+", "X-", "Y+", "Y-"
	Depth      int      // max entries
	EntryBytes int      // bytes per entry
	Entries    [][]byte // stored KV entries (nil = empty slot)
	EntrySeq   []int    // seqPos stored at each index (-1 = empty)
	WritePtr   int      // next write position (FIFO)
	ReadPtr    int      // next read position
	Occupancy  int      // entries currently stored
	Full       bool
	Empty      bool
	// Paged attention support
	PageTable *PageTable // virtual-to-physical page mapping
}

// NewKVCacheBank creates a new bank.
func NewKVCacheBank(dir string, depth, entryBytes int) *KVCacheBank {
	entries := make([][]byte, depth)
	entrySeq := make([]int, depth)
	for i := range entrySeq {
		entrySeq[i] = -1
	}
	return &KVCacheBank{
		Direction:  dir,
		Depth:      depth,
		EntryBytes: entryBytes,
		Entries:    entries,
		EntrySeq:   entrySeq,
		WritePtr:   0,
		ReadPtr:    0,
		Occupancy:  0,
		Full:       false,
		Empty:      true,
	}
}

// Store writes a KV entry into the bank. Returns false if full.
func (b *KVCacheBank) Store(entry []byte, seqPos int) bool {
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
	b.EntrySeq[b.WritePtr] = seqPos
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
	// Verify the stored seqPos matches (prevents stale data after wrap-around)
	if b.EntrySeq[idx] != seqPos {
		return nil // stale entry, evicted and overwritten
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

// PeekOldest returns the oldest entry without removing it. Returns nil if empty.
// Used by offload to persist an entry before dropping it, so a failed write does
// not silently lose cache data.
func (b *KVCacheBank) PeekOldest() []byte {
	if b.Empty {
		return nil
	}
	return b.Entries[b.ReadPtr]
}

// ============================================================================
// KV Cache Layer (with paged attention support)
// ============================================================================

// KVCacheLayer holds the 4 directional banks for one physical layer.
type KVCacheLayer struct {
	LayerID       int
	Banks         [4]*KVCacheBank
	Config        KVCacheConfig
	Evictions     int
	Reloads       int
	SlidingWindow int  // 0 = full attention, >0 = sliding window size
	IsSliding     bool // true if this layer uses sliding window attention
	// Paged attention state
	PageTable *PageTable // per-layer page table
	// GQA state
	NumAttentionHeads int // number of Q heads
	NumKeyValueHeads  int // number of KV heads
	HeadDim           int // dimension per head
	GroupSize         int // NumAttentionHeads / NumKeyValueHeads (for repeat_kv)
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
	// Initialize page table if paging enabled
	if cfg.EnablePaging {
		kl.PageTable = NewPageTable(cfg.MaxVirtPages, cfg.MaxPages)
	}
	return kl
}

// SetSlidingWindow configures this layer's sliding window attention.
func (kl *KVCacheLayer) SetSlidingWindow(windowSize int) {
	kl.SlidingWindow = windowSize
	kl.IsSliding = (windowSize > 0)
}

// SetGQA configures GQA parameters for this layer.
func (kl *KVCacheLayer) SetGQA(numAttnHeads, numKVHeads, headDim int) {
	kl.NumAttentionHeads = numAttnHeads
	kl.NumKeyValueHeads = numKVHeads
	kl.HeadDim = headDim
	if numKVHeads > 0 {
		kl.GroupSize = numAttnHeads / numKVHeads
	}
}

// Store distributes a KV entry across banks (round-robin by seq position).
func (kl *KVCacheLayer) Store(seqPos int, entry []byte) bool {
	bankIdx, bankLocalPos := kl.splitPos(seqPos)
	if bankIdx < 0 {
		return false
	}
	return kl.Banks[bankIdx].Store(entry, bankLocalPos)
}

// splitPos maps a sequence position to (bankIdx, bankLocalPos), returning a
// negative bankIdx for invalid (negative) positions so callers can bail out
// before indexing the bank slice.
func (kl *KVCacheLayer) splitPos(seqPos int) (int, int) {
	if seqPos < 0 {
		return -1, 0
	}
	return seqPos % kl.Config.NumBanks, seqPos / kl.Config.NumBanks
}

// StorePaged stores a KV entry using paged attention (virtual-to-physical mapping).
func (kl *KVCacheLayer) StorePaged(virtPage, pageOffset int, entry []byte) bool {
	if kl.PageTable == nil {
		return kl.Store(virtPage*kl.Config.PageSize+pageOffset, entry)
	}
	physPage := kl.PageTable.Translate(virtPage)
	if physPage < 0 {
		physPage = kl.PageTable.AllocPage(virtPage)
		if physPage < 0 {
			return false // out of physical pages
		}
	}
	// Map physical page + offset to a bank entry
	globalIdx := physPage*kl.Config.PageSize + pageOffset
	bankIdx, bankEntryIdx := kl.splitPos(globalIdx)
	if bankIdx < 0 {
		return false
	}
	return kl.Banks[bankIdx].Store(entry, bankEntryIdx)
}

// Load reads a KV entry from the appropriate bank by sequence position.
func (kl *KVCacheLayer) Load(seqPos int) []byte {
	bankIdx, bankLocalPos := kl.splitPos(seqPos)
	if bankIdx < 0 {
		return nil
	}
	return kl.Banks[bankIdx].Load(bankLocalPos)
}

// LoadPaged reads a KV entry using paged attention.
func (kl *KVCacheLayer) LoadPaged(virtPage, pageOffset int) []byte {
	if kl.PageTable == nil {
		return kl.Load(virtPage*kl.Config.PageSize + pageOffset)
	}
	physPage := kl.PageTable.Translate(virtPage)
	if physPage < 0 {
		return nil // page not resident
	}
	globalIdx := physPage*kl.Config.PageSize + pageOffset
	return kl.Load(globalIdx)
}

// LoadWindow reads KV entries within the sliding window [seqPos-window+1, seqPos].
func (kl *KVCacheLayer) LoadWindow(seqPos, windowSize int) [][]byte {
	if windowSize <= 0 {
		// Full attention: load all entries
		var all [][]byte
		for i := 0; i <= seqPos; i++ {
			entry := kl.Load(i)
			if entry != nil {
				all = append(all, entry)
			}
		}
		return all
	}
	// Sliding window: load only entries within the window
	start := seqPos - windowSize + 1
	if start < 0 {
		start = 0
	}
	var window [][]byte
	for i := start; i <= seqPos; i++ {
		entry := kl.Load(i)
		if entry != nil {
			window = append(window, entry)
		}
	}
	return window
}

// RepeatKV expands KV heads to match Q heads for GQA.
// For group_size=G, each KV head is repeated G times.
func (kl *KVCacheLayer) RepeatKV(kvEntry []byte) []byte {
	if kl.GroupSize <= 1 {
		return kvEntry // MQA or MHA: no repetition needed
	}
	// Each KV entry contains all KV heads concatenated.
	// Split into per-head chunks, then repeat each chunk GroupSize times.
	// Guard HeadDim/NumKeyValueHeads against zero (a malformed GQA config
	// would otherwise divide by zero here and panic).
	if kl.HeadDim <= 0 || kl.NumKeyValueHeads <= 0 {
		return kvEntry
	}
	// All KV heads share the single EntryBytes frame, so each head occupies
	// EntryBytes/NumKeyValueHeads bytes. The previous expression derived the
	// per-head size from HeadDim but divided it through an integer quotient
	// of the frame (EntryBytes/(NumKVHeads*HeadDim*2)); whenever the frame did
	// not hold a clean multiple of all heads (e.g. EntryBytes=512 with 8 KV
	// heads of HeadDim=64), that quotient truncated to zero and RepeatKV
	// silently returned the un-expanded entry, disabling GQA. Use the direct
	// frame split instead.
	kvBytesPerHead := kl.Config.EntryBytes / kl.NumKeyValueHeads
	if kvBytesPerHead <= 0 {
		return kvEntry
	}
	result := make([]byte, 0, len(kvEntry)*kl.GroupSize)
	for h := 0; h < kl.NumKeyValueHeads; h++ {
		start := h * kvBytesPerHead
		end := start + kvBytesPerHead
		if end > len(kvEntry) {
			break
		}
		chunk := kvEntry[start:end]
		for g := 0; g < kl.GroupSize; g++ {
			result = append(result, chunk...)
		}
	}
	return result
}

// fullestBank returns the index of the most-filled bank, and whether that
// bank is above the offload threshold. It is shared by NeedsOffload and the
// offload path so both agree on which bank to drain.
func (kl *KVCacheLayer) fullestBank() (int, bool) {
	maxOcc := 0
	maxBank := -1
	for i, b := range kl.Banks {
		if b.Occupancy > maxOcc {
			maxOcc = b.Occupancy
			maxBank = i
		}
	}
	if maxBank < 0 {
		return -1, false
	}
	threshold := kl.Banks[maxBank].Depth * kl.Config.OffloadThresh / 100
	return maxBank, kl.Banks[maxBank].Occupancy >= threshold
}

// NeedsOffload returns true if any bank is above the offload threshold.
func (kl *KVCacheLayer) NeedsOffload() bool {
	_, over := kl.fullestBank()
	return over
}

// OffloadPeek returns the oldest entry of the fullest (over-threshold) bank
// without removing it, plus its direction. Returns nil if nothing to offload.
func (kl *KVCacheLayer) OffloadPeek() ([]byte, string, *KVCacheBank) {
	idx, over := kl.fullestBank()
	if !over {
		return nil, "", nil
	}
	b := kl.Banks[idx]
	return b.PeekOldest(), b.Direction, b
}

// EvictOldest evicts the oldest entry from the fullest bank.
func (kl *KVCacheLayer) EvictOldest() ([]byte, string) {
	idx, _ := kl.fullestBank()
	if idx < 0 {
		return nil, ""
	}
	entry := kl.Banks[idx].Evict()
	if entry != nil {
		kl.Evictions++
		return entry, kl.Banks[idx].Direction
	}
	return nil, ""
}

// ============================================================================
// KV Cache Manager: coordinates all layers' KV caches
// ============================================================================

// EvictionStats tracks where evicted entries went.
type EvictionStats struct {
	Discarded  int   // entries discarded (EvictNone)
	DmaToBMC   int   // entries DMA'd to host BMC (EvictDmaBmc)
	NvmeWrites int   // entries written to NVMe (EvictNvme)
	NvmeBlocks int   // NVMe 512B blocks consumed
	BMCBytes   int64 // total bytes DMA'd to BMC
	NvmeBytes  int64 // total bytes written to NVMe
	Errors     int   // failed evictions (NVMe full, DMA timeout)
}

// KVCache manages KV caches across all physical layers.
type KVCache struct {
	Layers         []*KVCacheLayer
	Config         KVCacheConfig
	Dims           Dims
	TotalEvictions int
	TotalReloads   int
	Stats          EvictionStats
	// EvictLBA is the next NVMe LBA for overflow writes (circular).
	EvictLBA uint64
	// NVMe is the optional NVMe device (nil when EvictMode != EvictNvme).
	NVMe *NVMeDev
	// Prefix cache for cross-request KV sharing
	PrefixCache *PrefixCache
}

// NewKVCache creates KV caches for all layers.
// If nvme is non-nil, it will be used for EvictNvme mode.
func NewKVCache(dims Dims, hiddenSize int, nvme *NVMeDev) *KVCache {
	cfg := DefaultKVCacheConfig(hiddenSize)
	kc := &KVCache{
		Layers:      make([]*KVCacheLayer, dims.Layers),
		Config:      cfg,
		Dims:        dims,
		NVMe:        nvme,
		EvictLBA:    cfg.NVMeLBAStart,
		PrefixCache: NewPrefixCache(1024),
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

// StorePaged stores a KV entry using paged attention.
func (kc *KVCache) StorePaged(layer, virtPage, pageOffset int, entry []byte) bool {
	if layer < 0 || layer >= len(kc.Layers) {
		return false
	}
	return kc.Layers[layer].StorePaged(virtPage, pageOffset, entry)
}

// Load reads a KV entry for a given layer and sequence position.
func (kc *KVCache) Load(layer, seqPos int) []byte {
	if layer < 0 || layer >= len(kc.Layers) {
		return nil
	}
	return kc.Layers[layer].Load(seqPos)
}

// LoadPaged reads a KV entry using paged attention.
func (kc *KVCache) LoadPaged(layer, virtPage, pageOffset int) []byte {
	if layer < 0 || layer >= len(kc.Layers) {
		return nil
	}
	return kc.Layers[layer].LoadPaged(virtPage, pageOffset)
}

// LoadWindow reads KV entries within the sliding window for a layer.
func (kc *KVCache) LoadWindow(layer, seqPos int) [][]byte {
	if layer < 0 || layer >= len(kc.Layers) {
		return nil
	}
	kl := kc.Layers[layer]
	if kl.IsSliding {
		return kl.LoadWindow(seqPos, kl.SlidingWindow)
	}
	return kl.LoadWindow(seqPos, 0) // full attention
}

// RepeatKV expands KV heads to match Q heads for GQA.
func (kc *KVCache) RepeatKV(layer int, kvEntry []byte) []byte {
	if layer < 0 || layer >= len(kc.Layers) {
		return kvEntry
	}
	return kc.Layers[layer].RepeatKV(kvEntry)
}

// ConfigureSlidingWindow sets per-layer sliding window attention from model config.
func (kc *KVCache) ConfigureSlidingWindow(slidingWindow int, layerTypes []string) {
	if slidingWindow <= 0 {
		return
	}
	kc.Config.SlidingWindow = slidingWindow
	for ml, ltype := range layerTypes {
		if ml >= len(kc.Layers) {
			break
		}
		if ltype == "sliding_attention" {
			kc.Layers[ml].SetSlidingWindow(slidingWindow)
		}
	}
}

// ConfigureGQA sets GQA parameters for all layers.
func (kc *KVCache) ConfigureGQA(numAttnHeads, numKVHeads, headDim int) {
	kc.Config.NumAttentionHeads = numAttnHeads
	kc.Config.NumKeyValueHeads = numKVHeads
	kc.Config.HeadDim = headDim
	for _, kl := range kc.Layers {
		kl.SetGQA(numAttnHeads, numKVHeads, headDim)
	}
}

// LookupPrefix checks the prefix cache for a token sequence.
func (kc *KVCache) LookupPrefix(tokens []int) *PrefixCacheEntry {
	if kc.PrefixCache == nil {
		return nil
	}
	return kc.PrefixCache.Lookup(tokens)
}

// StorePrefix caches a prefix's KV data.
func (kc *KVCache) StorePrefix(tokens []int, layer int, virtPages []int) {
	if kc.PrefixCache != nil {
		kc.PrefixCache.Store(tokens, layer, virtPages)
	}
}

// OffloadCycle checks all layers and evicts entries that exceed the threshold.
func (kc *KVCache) OffloadCycle() int {
	totalEvicted := 0
offload:
	for _, kl := range kc.Layers {
		for kl.NeedsOffload() {
			// Peek first so a failed persist (e.g. NVMe write error) does not
			// silently drop the entry; only remove it once it is safely stored.
			entry, dir, bank := kl.OffloadPeek()
			if entry == nil || bank == nil {
				break
			}
			_ = dir

			switch kc.Config.EvictMode {
			case EvictDmaBmc:
				bank.Evict()
				totalEvicted++
				kc.TotalEvictions++
				kc.Stats.DmaToBMC++
				kc.Stats.BMCBytes += int64(len(entry))

			case EvictNvme:
				if kc.NVMe != nil {
					nBlocks := (len(entry) + NVMEBlockSize - 1) / NVMEBlockSize
					err := kc.NVMe.WriteBlocks(kc.EvictLBA, uint16(nBlocks-1), 0, entry)
					if err != nil {
						// Persistent sink failure: keep the entry in the cache and
						// stop offloading this cycle so we do not cascade-drain
						// (and lose) the rest of the KV data.
						kc.Stats.Errors++
						continue offload
					}
					kc.EvictLBA += uint64(nBlocks)
					if kc.EvictLBA >= kc.Config.NVMeLBAEnd {
						kc.EvictLBA = kc.Config.NVMeLBAStart
					}
					bank.Evict()
					totalEvicted++
					kc.TotalEvictions++
					kc.Stats.NvmeWrites++
					kc.Stats.NvmeBlocks += nBlocks
					kc.Stats.NvmeBytes += int64(len(entry))
				} else {
					bank.Evict()
					totalEvicted++
					kc.TotalEvictions++
					kc.Stats.Discarded++
				}

			default: // EvictNone
				bank.Evict()
				totalEvicted++
				kc.TotalEvictions++
				kc.Stats.Discarded++
			}
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

	s := fmt.Sprintf("KV Cache: %d layers x %d banks x %d entries = %d total, "+
		"%d used (%.1f%%), %.1f MB used / %.1f MB capacity, %d evictions, %d reloads, "+
		"evict_mode=%s, sliding_window=%d",
		len(kc.Layers), kc.Config.NumBanks, kc.Config.BankDepth,
		totalCap, totalUsed,
		float64(totalUsed)*100/float64(totalCap),
		float64(totalBytes)/1e6, float64(capBytes)/1e6,
		kc.TotalEvictions, kc.TotalReloads,
		evictionModeName(kc.Config.EvictMode),
		kc.Config.SlidingWindow)
	if kc.Config.EnablePaging {
		s += fmt.Sprintf(", paged=true, pages=%d/%d", kc.Config.MaxPages, kc.Config.MaxVirtPages)
	}
	if kc.Config.NumKeyValueHeads > 0 && kc.Config.NumKeyValueHeads < kc.Config.NumAttentionHeads {
		s += fmt.Sprintf(", gqa=%d/%d", kc.Config.NumKeyValueHeads, kc.Config.NumAttentionHeads)
	}
	if kc.PrefixCache != nil {
		s += fmt.Sprintf(", prefix_hits=%d/misses=%d", kc.PrefixCache.Hits, kc.PrefixCache.Misses)
	}
	return s
}

func evictionModeName(m EvictionMode) string {
	switch m {
	case EvictDmaBmc:
		return "dma_bmc"
	case EvictNvme:
		return "nvme"
	default:
		return "none"
	}
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
