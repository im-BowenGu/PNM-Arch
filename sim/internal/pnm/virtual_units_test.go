package pnm

import (
	"testing"
)

// ============================================================================
// VirtualUnit tests — doorbell discipline, kernels, decode
// ============================================================================

func TestDecode_ValidPacket(t *testing.T) {
	// Build a valid packet: DEST=0x12, CTRL=0x40, LEN=2, payload=[0xAA,0xBB]
	body := []byte{0x12, 0x40, 0x02, 0x00, 0xAA, 0xBB}
	hi, lo := crcBytes(body)
	full := append(body, hi, lo)

	p := decode(full)
	if p.Dest != 0x12 {
		t.Errorf("Dest = 0x%02X, want 0x12", p.Dest)
	}
	if p.Ctrl != 0x40 {
		t.Errorf("Ctrl = 0x%02X, want 0x40", p.Ctrl)
	}
	if p.Length != 2 {
		t.Errorf("Length = %d, want 2", p.Length)
	}
	if len(p.Payload) != 2 || p.Payload[0] != 0xAA || p.Payload[1] != 0xBB {
		t.Errorf("Payload = %v, want [0xAA 0xBB]", p.Payload)
	}
	if p.CRC != [2]byte{hi, lo} {
		t.Errorf("CRC = %v, want [%02X %02X]", p.CRC, hi, lo)
	}
}

func TestDecode_EmptyPayload(t *testing.T) {
	body := []byte{0x01, 0x40, 0x00, 0x00}
	hi, lo := crcBytes(body)
	full := append(body, hi, lo)

	p := decode(full)
	if p.Length != 0 {
		t.Errorf("Length = %d, want 0", p.Length)
	}
	if p.Payload != nil {
		t.Errorf("Payload = %v, want nil", p.Payload)
	}
}

func TestDecode_ShortInput(t *testing.T) {
	// Should not panic on short input
	p := decode([]byte{0x01})
	if p.Dest != 0x01 {
		t.Errorf("Dest = 0x%02X, want 0x01", p.Dest)
	}
	if p.Payload != nil {
		t.Errorf("Payload = %v, want nil for short input", p.Payload)
	}
}

func TestDecode_EmptyInput(t *testing.T) {
	p := decode(nil)
	if p.Dest != 0 {
		t.Errorf("Dest = 0x%02X, want 0 for nil input", p.Dest)
	}
	if p.Payload != nil {
		t.Errorf("Payload = %v, want nil", p.Payload)
	}
}

func TestDecode_TwoBytes(t *testing.T) {
	p := decode([]byte{0x12, 0x34})
	if p.Dest != 0x12 {
		t.Errorf("Dest = 0x%02X, want 0x12", p.Dest)
	}
	if p.Ctrl != 0x34 {
		t.Errorf("Ctrl = 0x%02X, want 0x34", p.Ctrl)
	}
}

// ============================================================================
// Kernel tests
// ============================================================================

func TestKEcho(t *testing.T) {
	pkt := &Pkt{Payload: []byte{1, 2, 3, 4, 5}}
	state := &UnitState{}
	result := kEcho(pkt, state)
	payload, ok := result.([]byte)
	if !ok {
		t.Fatalf("kEcho returned %T, want []byte", result)
	}
	for i, v := range payload {
		if v != pkt.Payload[i] {
			t.Errorf("kEcho[%d] = %d, want %d", i, v, pkt.Payload[i])
		}
	}
}

func TestKSum(t *testing.T) {
	pkt := &Pkt{Payload: []byte{1, 2, 3, 4}}
	state := &UnitState{}
	result := kSum(pkt, state)
	sum, ok := result.(uint64)
	if !ok {
		t.Fatalf("kSum returned %T, want uint64", result)
	}
	if sum != 10 {
		t.Errorf("kSum = %d, want 10", sum)
	}
}

func TestKSum_Empty(t *testing.T) {
	pkt := &Pkt{Payload: nil}
	state := &UnitState{}
	result := kSum(pkt, state)
	if result.(uint64) != 0 {
		t.Errorf("kSum(empty) = %d, want 0", result)
	}
}

func TestKSum_Overflow(t *testing.T) {
	// Sum of 256 * 0xFF = 65280, fits in 32 bits
	payload := make([]byte, 256)
	for i := range payload {
		payload[i] = 0xFF
	}
	pkt := &Pkt{Payload: payload}
	state := &UnitState{}
	result := kSum(pkt, state)
	if result.(uint64) != 65280 {
		t.Errorf("kSum(256*0xFF) = %d, want 65280", result)
	}
}

func TestKAccum(t *testing.T) {
	state := &UnitState{}
	// First packet: sum = 1+2+3 = 6
	pkt1 := &Pkt{Payload: []byte{1, 2, 3}}
	r1 := kAccum(pkt1, state)
	if r1.(uint64) != 6 {
		t.Errorf("kAccum[1] = %d, want 6", r1)
	}
	// Second packet: sum = 4+5 = 9, acc = 6+9 = 15
	pkt2 := &Pkt{Payload: []byte{4, 5}}
	r2 := kAccum(pkt2, state)
	if r2.(uint64) != 15 {
		t.Errorf("kAccum[2] = %d, want 15", r2)
	}
	// State should be updated
	if state.Acc != 15 {
		t.Errorf("state.Acc = %d, want 15", state.Acc)
	}
}

func TestKDot(t *testing.T) {
	// dot([1,2,3], [4,5,6]) = 1*4 + 2*5 + 3*6 = 32
	pkt := &Pkt{Payload: []byte{1, 2, 3}}
	state := &UnitState{Weights: []int{4, 5, 6}}
	result := kDot(pkt, state)
	if result.(uint64) != 32 {
		t.Errorf("kDot = %d, want 32", result)
	}
}

func TestKDot_MismatchedLengths(t *testing.T) {
	// Payload shorter than weights: zero-padded
	pkt := &Pkt{Payload: []byte{1, 2}}
	state := &UnitState{Weights: []int{3, 4, 5}}
	result := kDot(pkt, state)
	// 1*3 + 2*4 + 0*5 = 11
	if result.(uint64) != 11 {
		t.Errorf("kDot(short payload) = %d, want 11", result)
	}

	// Weights shorter than payload: zero-padded
	pkt2 := &Pkt{Payload: []byte{1, 2, 3}}
	state2 := &UnitState{Weights: []int{4, 5}}
	result2 := kDot(pkt2, state2)
	// 1*4 + 2*5 + 3*0 = 14
	if result2.(uint64) != 14 {
		t.Errorf("kDot(short weights) = %d, want 14", result2)
	}
}

func TestKDot_Empty(t *testing.T) {
	pkt := &Pkt{Payload: nil}
	state := &UnitState{Weights: nil}
	result := kDot(pkt, state)
	if result.(uint64) != 0 {
		t.Errorf("kDot(empty) = %d, want 0", result)
	}
}

// ============================================================================
// NewVirtualUnit tests
// ============================================================================

func TestNewVirtualUnit(t *testing.T) {
	weights := []int{10, 20, 30}
	u := NewVirtualUnit(NodeID{L: 1, X: 2, Y: 3}, "dot", weights)
	if u.Node != (NodeID{L: 1, X: 2, Y: 3}) {
		t.Errorf("Node = %v", u.Node)
	}
	if u.KernelName != "dot" {
		t.Errorf("KernelName = %s", u.KernelName)
	}
	// Verify weights are copied (not aliased)
	weights[0] = 999
	if u.State.Weights[0] == 999 {
		t.Error("weights not copied: aliasing detected")
	}
}

func TestNewVirtualUnit_AllKernels(t *testing.T) {
	for _, name := range KERNEL_MIX {
		u := NewVirtualUnit(NodeID{}, name, nil)
		if u.Kernel == nil {
			t.Errorf("kernel %q returned nil func", name)
		}
	}
}

func TestNewVirtualUnit_UnknownKernel(t *testing.T) {
	defer func() {
		if r := recover(); r == nil {
			t.Error("expected panic for unknown kernel")
		}
	}()
	NewVirtualUnit(NodeID{}, "nonexistent", nil)
}

// ============================================================================
// Consume tests — doorbell discipline
// ============================================================================

func TestConsume_ValidPacket(t *testing.T) {
	node := NodeID{L: 1, X: 2, Y: 3}
_ownByte := byte((node.X << 4) | node.Y) // 0x23

	// Build a valid packet for this node
	payload := []byte{0x10, 0x20, 0x30}
	body := append([]byte{_ownByte, 0x40, byte(len(payload)), 0x00}, payload...)
	hi, lo := crcBytes(body)
	full := append(body, hi, lo)

	u := NewVirtualUnit(node, "echo", nil)
	pkt := u.Consume(full, false)
	if pkt == nil {
		t.Fatal("Consume returned nil for valid packet")
	}
	if u.Activations != 1 {
		t.Errorf("Activations = %d, want 1", u.Activations)
	}
	if len(u.Results) != 1 {
		t.Fatalf("Results len = %d, want 1", len(u.Results))
	}
	// Echo kernel should return the payload
	result := u.Results[0].([]byte)
	if len(result) != 3 || result[0] != 0x10 || result[1] != 0x20 || result[2] != 0x30 {
		t.Errorf("Echo result = %v", result)
	}
}

func TestConsume_WrongDEST(t *testing.T) {
	node := NodeID{L: 1, X: 2, Y: 3}
	wrongDest := byte(0xFF) // Not this node

	payload := []byte{0x10}
	body := append([]byte{wrongDest, 0x40, byte(len(payload)), 0x00}, payload...)
	hi, lo := crcBytes(body)
	full := append(body, hi, lo)

	u := NewVirtualUnit(node, "echo", nil)
	pkt := u.Consume(full, false)
	if pkt != nil {
		t.Error("Consume should return nil for wrong DEST")
	}
	if u.Rejections != 1 {
		t.Errorf("Rejections = %d, want 1", u.Rejections)
	}
}

func TestConsume_WrongLength(t *testing.T) {
	node := NodeID{L: 1, X: 2, Y: 3}
_ownByte := byte((node.X << 4) | node.Y)

	// Claim length=10 but only send 3 payload bytes
	payload := []byte{0x10, 0x20, 0x30}
	body := append([]byte{_ownByte, 0x40, 0x0A, 0x00}, payload...)
	hi, lo := crcBytes(body)
	full := append(body, hi, lo)

	u := NewVirtualUnit(node, "echo", nil)
	pkt := u.Consume(full, false)
	if pkt != nil {
		t.Error("Consume should return nil for wrong length")
	}
	if u.Rejections != 1 {
		t.Errorf("Rejections = %d, want 1", u.Rejections)
	}
}

func TestConsume_CorruptCRC(t *testing.T) {
	node := NodeID{L: 1, X: 2, Y: 3}
_ownByte := byte((node.X << 4) | node.Y)

	payload := []byte{0x10, 0x20}
	body := append([]byte{_ownByte, 0x40, byte(len(payload)), 0x00}, payload...)
	hi, lo := crcBytes(body)
	full := append(body, hi, lo)
	// Corrupt one CRC byte
	full[len(full)-1] ^= 0xFF

	u := NewVirtualUnit(node, "echo", nil)
	pkt := u.Consume(full, false)
	if pkt != nil {
		t.Error("Consume should return nil for corrupt CRC")
	}
	if u.Rejections != 1 {
		t.Errorf("Rejections = %d, want 1", u.Rejections)
	}
}

func TestConsume_HwCorrupt(t *testing.T) {
	node := NodeID{L: 1, X: 2, Y: 3}
_ownByte := byte((node.X << 4) | node.Y)

	payload := []byte{0x10}
	body := append([]byte{_ownByte, 0x40, byte(len(payload)), 0x00}, payload...)
	hi, lo := crcBytes(body)
	full := append(body, hi, lo)

	u := NewVirtualUnit(node, "echo", nil)
	pkt := u.Consume(full, true) // hwCorrupt=true
	if pkt != nil {
		t.Error("Consume should return nil for hwCorrupt")
	}
	if u.Rejections != 1 {
		t.Errorf("Rejections = %d, want 1", u.Rejections)
	}
}

func TestConsume_MultiplePackets(t *testing.T) {
	node := NodeID{L: 0, X: 0, Y: 0}
	u := NewVirtualUnit(node, "sum", nil)

	for i := 0; i < 5; i++ {
		payload := []byte{byte(i + 1)}
		body := append([]byte{0x00, 0x40, 0x01, 0x00}, payload...)
		hi, lo := crcBytes(body)
		full := append(body, hi, lo)
		u.Consume(full, false)
	}

	if u.Activations != 5 {
		t.Errorf("Activations = %d, want 5", u.Activations)
	}
	if len(u.Results) != 5 {
		t.Fatalf("Results len = %d, want 5", len(u.Results))
	}
	// Each packet has one byte, sum = that byte value
	for i, r := range u.Results {
		expected := uint64(i + 1)
		if r.(uint64) != expected {
			t.Errorf("Result[%d] = %d, want %d", i, r, expected)
		}
	}
}
