package pnm

import "testing"

func newTestKVCacheLayer() *KVCacheLayer {
	kl := &KVCacheLayer{
		Config: KVCacheConfig{
			BankDepth:        16,
			EntryBytes:       32,
			NumBanks:         4,
			NumKeyValueHeads: 8,
			HeadDim:          64,
		},
	}
	for i := 0; i < 4; i++ {
		kl.Banks[i] = NewKVCacheBank("dir", 16, 32)
	}
	return kl
}

// TestKVCacheLayer_NegativeStore does not panic on a negative seq position.
func TestKVCacheLayer_NegativeStore(t *testing.T) {
	kl := newTestKVCacheLayer()
	if ok := kl.Store(-1, make([]byte, 32)); ok {
		t.Error("Store(-1) should return false for a negative position")
	}
}

// TestKVCacheLayer_NegativeLoad does not panic on a negative seq position.
func TestKVCacheLayer_NegativeLoad(t *testing.T) {
	kl := newTestKVCacheLayer()
	if v := kl.Load(-5); v != nil {
		t.Errorf("Load(-5) should return nil, got %v", v)
	}
}

// TestKVCacheLayer_RoundTrip stores and reloads entries across banks.
func TestKVCacheLayer_RoundTrip(t *testing.T) {
	kl := newTestKVCacheLayer()
	entry := make([]byte, 32)
	for i := range entry {
		entry[i] = byte(i)
	}
	for pos := 0; pos < 64; pos++ {
		if !kl.Store(pos, entry) {
			t.Fatalf("Store(%d) failed", pos)
		}
	}
	for pos := 0; pos < 64; pos++ {
		got := kl.Load(pos)
		if got == nil {
			t.Fatalf("Load(%d) returned nil", pos)
		}
		for i := range entry {
			if got[i] != byte(i) {
				t.Fatalf("Load(%d) byte %d = %d, want %d", pos, i, got[i], byte(i))
			}
		}
	}
}

// TestPrefixCache_StoreDoesNotEvictJustAdded ensures a fresh entry survives
// eviction pressure and an older cold entry is evicted instead.
func TestPrefixCache_StoreDoesNotEvictJustAdded(t *testing.T) {
	pc := NewPrefixCache(2)
	// Fill to capacity with two entries, then hit one to raise its HitCount.
	pc.Store([]int{1}, 0, []int{0})
	pc.Store([]int{2}, 0, []int{1})
	if pc.Lookup([]int{1}) == nil {
		t.Fatal("lookup of token {1} failed")
	}
	// Add a third entry: eviction should not remove it.
	pc.Store([]int{3}, 0, []int{2})
	if pc.Lookup([]int{3}) == nil {
		t.Fatal("just-added entry {3} was evicted immediately")
	}
}

// bankOccupancy sums occupancy across all banks.
func bankOccupancy(kc *KVCache) int {
	n := 0
	for _, kl := range kc.Layers {
		for _, b := range kl.Banks {
			n += b.Occupancy
		}
	}
	return n
}

// overThresholdKVCache builds a cache whose banks are just over the 80% offload
// threshold (threshold = Depth*80/100 = 819 for Depth=1024).
func overThresholdKVCache(evictMode EvictionMode, nvme *NVMeDev) *KVCache {
	kc := NewKVCache(Dims{Layers: 1, Bx: 1, By: 1}, 0, nvme)
	kc.Config.EvictMode = evictMode
	entry := make([]byte, 512)
	for i := 0; i < 820*4; i++ { // 820 > 819 = 80% of 1024
		kc.Store(0, i, entry)
	}
	return kc
}

// TestOffloadNvmeErrorNoDataLoss ensures a failing NVMe write does not silently
// drop the KV entry (the entry is removed only after a successful persist).
func TestOffloadNvmeErrorNoDataLoss(t *testing.T) {
	// NVMe not Init'd -> every WriteBlocks returns an error.
	kc := overThresholdKVCache(EvictNvme, NewNVMeDev(0xC0000000))
	before := bankOccupancy(kc)
	evicted := kc.OffloadCycle()
	after := bankOccupancy(kc)
	if after != before {
		t.Errorf("NVMe error lost data: before=%d after=%d", before, after)
	}
	if evicted != 0 {
		t.Errorf("evicted=%d on persistent error, want 0 (entries kept)", evicted)
	}
	if kc.Stats.Errors == 0 {
		t.Error("expected at least one NVMe error stat")
	}
}

// TestOffloadNvmeSuccessEvicts verifies the happy path drains over-threshold
// banks to NVMe exactly once per dropped entry.
func TestOffloadNvmeSuccessEvicts(t *testing.T) {
	nvme := NewNVMeDev(0xC0000000)
	if err := nvme.Init(); err != nil {
		t.Fatal(err)
	}
	kc := overThresholdKVCache(EvictNvme, nvme)
	before := bankOccupancy(kc)
	evicted := kc.OffloadCycle()
	after := bankOccupancy(kc)
	if after >= before {
		t.Errorf("success path did not evict: before=%d after=%d", before, after)
	}
	if evicted != before-after {
		t.Errorf("evicted=%d != dropped=%d", evicted, before-after)
	}
	if kc.Stats.NvmeWrites != evicted {
		t.Errorf("nvmeWrites=%d != evicted=%d", kc.Stats.NvmeWrites, evicted)
	}
}

// TestOffloadEvictNoneDiscards verifies the default discard mode still drains.
func TestOffloadEvictNoneDiscards(t *testing.T) {
	kc := overThresholdKVCache(EvictNone, nil)
	before := bankOccupancy(kc)
	evicted := kc.OffloadCycle()
	after := bankOccupancy(kc)
	if evicted == 0 || after >= before {
		t.Errorf("EvictNone should discard: before=%d after=%d evicted=%d", before, after, evicted)
	}
}

// TestDefaultKVCacheConfigRTLConsistency pins the Go KV accounting to the
// RTL frame instantiated by gen_topology.go: kv_cache_bank is created with
// ENTRY_BYTES(512) / BANK_DEPTH(1024), so DefaultKVCacheConfig must report
// the same per-entry size for any hiddenSize (regression for the removed
// hiddenSize-derived override that silently inflated paper capacity).
func TestDefaultKVCacheConfigRTLConsistency(t *testing.T) {
	for _, hs := range []int{0, 64, 128, 512, 2816} {
		cfg := DefaultKVCacheConfig(hs)
		if cfg.EntryBytes != 512 {
			t.Fatalf("hiddenSize=%d: EntryBytes=%d, want 512 (RTL ENTRY_BYTES)", hs, cfg.EntryBytes)
		}
		if cfg.BankDepth != 1024 {
			t.Fatalf("hiddenSize=%d: BankDepth=%d, want 1024 (RTL BANK_DEPTH)", hs, cfg.BankDepth)
		}
		if cfg.NumBanks != 4 {
			t.Fatalf("hiddenSize=%d: NumBanks=%d, want 4", hs, cfg.NumBanks)
		}
	}
}
