package pnm

import (
	"bytes"
	"testing"
)

// TestScenarioKV_DeterministicStream: same seed → bit-identical wire streams
// (the paper's Table 3 / §3.5 determinism guarantee applies to KV co-sim).
func TestScenarioKV_DeterministicStream(t *testing.T) {
	a := ScenarioKV(3, 4, 4, 1)
	b := ScenarioKV(3, 4, 4, 1)
	if len(a.Stream) != len(b.Stream) {
		t.Fatalf("stream lengths differ: %d vs %d", len(a.Stream), len(b.Stream))
	}
	for i := range a.Stream {
		if a.Stream[i] != b.Stream[i] {
			t.Fatalf("stream byte %d differs", i)
		}
	}
	if !a.KVCache || a.KV == nil {
		t.Fatalf("program does not carry the KV plan")
	}
	if got := len(a.KV.Banks); got != 5 {
		t.Fatalf("expected 5 target banks (4 layer-0 columns + 1 layer-1), got %d", got)
	}
}

// TestKVExpected_TwinServesPlan: the software twin serves exactly the
// non-corrupt, in-window loads with bias-transformed responses of the
// promised shape (runs without iverilog).
func TestKVExpected_TwinServesPlan(t *testing.T) {
	p := ScenarioKV(3, 4, 4, 1)
	exp, served := kvExpected(p, []int{0, 1, 2})
	wantServed := 0
	for _, bank := range p.KV.Banks {
		for _, l := range bank.Loads {
			if !l.Corrupt {
				wantServed++
			}
		}
	}
	if served != wantServed {
		t.Fatalf("twin served %d loads, plan expects %d", served, wantServed)
	}
	per := 4 + KV_ENTRY_BYTES + 2
	for n, want := range exp {
		if len(want)%per != 0 || len(want) == 0 {
			t.Fatalf("%s: twin produced %d bytes (not a multiple of %d)", n, len(want), per)
		}
		// response framing: mod|0x80|LEN_LO|LEN_HI then payload + CRC
		resp := want[:per]
		if resp[0] != byte((n.X<<4)|n.Y) {
			t.Fatalf("%s: response dest byte %02x, expected %02x", n, resp[0], (n.X<<4)|n.Y)
		}
		if resp[1] != 0x80 {
			t.Fatalf("%s: response CTRL %02x, expected 0x80", n, resp[1])
		}
		if len(resp) != per {
			t.Fatalf("%s: response length %d, expected %d", n, len(resp), per)
		}
		if len(resp) != 4+int(resp[2])|(int(resp[3])<<8)+2 {
			t.Fatalf("%s: response body length inconsistent with LEN field", n)
		}
	}
}

// TestKVResponseCRC: the twin's response CRC recomputes to the trailing bytes
// (node doorbell acceptance in the co-sim).
func TestKVResponseCRC(t *testing.T) {
	entry := []byte("the quick brown fox jumps over the lazy dog 0123456789")
	entry = bytes.Repeat(entry, 16)
	entry = entry[:KV_ENTRY_BYTES]
	resp := kvResponse(0x23, entry)
	body := resp[:len(resp)-2]
	hi, lo := crcBytes(body)
	if resp[len(resp)-2] != hi || resp[len(resp)-1] != lo {
		t.Fatalf("kvResponse CRC mismatch: wire %02x%02x expected %02x%02x",
			resp[len(resp)-2], resp[len(resp)-1], hi, lo)
	}
}

// TestKVFlow_TwinCircularWindow: the kvflow twin replays fill → auto-evict →
// reload with hardware semantics (eviction at capacity, serialized by the
// NoB hijack), so the three loads must serve the circular window e2,e3,e4.
func TestKVFlow_TwinCircularWindow(t *testing.T) {
	p := ScenarioKVFlow(1, 4, 4, 1)
	exp, served := kvExpected(p, []int{0})
	if served != 3 {
		t.Fatalf("flow twin served %d loads, want 3", served)
	}
	n := NodeID{L: 0, X: 0, Y: 1}
	want := exp[n]
	per := 4 + KV_ENTRY_BYTES + 2
	if len(want) != 3*per {
		t.Fatalf("flow responses %d bytes, want %d", len(want), 3*per)
	}
	// e2, e3, e4 in order: recover entries by undoing the bias
	bias := p.Manifest[n].Bias
	var ids [][4]byte
	for r := 0; r < 3; r++ {
		payload := want[4+r*per : 4+r*per+4]
		var id [4]byte
		for i := 0; i < 4; i++ {
			id[i] = payload[i] - byte(bias)
		}
		ids = append(ids, id)
	}
	// store payloads in injection order
	var stores [][4]byte
	for _, pkt := range p.Manifest[n].Packets {
		if pkt.Corrupt || len(pkt.DMA) != 4+KV_ENTRY_BYTES+2 {
			continue
		}
		var id [4]byte
		copy(id[:], pkt.DMA[4:8])
		stores = append(stores, id)
	}
	if stores[2] != ids[0] {
		t.Errorf("load idx0 served store %x, want e2 %x", ids[0], stores[2])
	}
	if stores[3] != ids[1] {
		t.Errorf("load idx1 served store %x, want e3 %x", ids[1], stores[3])
	}
	if stores[4] != ids[2] {
		t.Errorf("load idx2 served store %x, want e4 %x", ids[2], stores[4])
	}
}
