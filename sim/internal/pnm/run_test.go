package pnm

import (
	"os"
	"path/filepath"
	"testing"
)

// ============================================================================
// Flit construction tests
// ============================================================================

func TestFlit_BasicStructure(t *testing.T) {
	payload := []byte{0xAA, 0xBB}
	stream := Flit(1, 0x23, 0x40, payload, false)

	// Expected wire: LAYER(1) | MODULE(0x23) | CTRL(0x40) | LEN_LO(0x02) | LEN_HI(0x00) | 0xAA | 0xBB | CRC_HI | CRC_LO
	if len(stream) != 4+len(payload)+3 { // 4 header + 2 payload + 1 layer + 2 CRC = 9
		t.Fatalf("Flit length = %d, want %d", len(stream), 9)
	}

	// Check LAYER_ID
	if stream[0].Data != 0x01 {
		t.Errorf("LAYER_ID = 0x%02X, want 0x01", stream[0].Data)
	}
	if !stream[0].Sop {
		t.Error("first byte should be SOP")
	}

	// Check MODULE_ID
	if stream[1].Data != 0x23 {
		t.Errorf("MODULE_ID = 0x%02X, want 0x23", stream[1].Data)
	}

	// Check CTRL
	if stream[2].Data != 0x40 {
		t.Errorf("CTRL = 0x%02X, want 0x40", stream[2].Data)
	}

	// Check LEN_LO, LEN_HI
	if stream[3].Data != 0x02 {
		t.Errorf("LEN_LO = 0x%02X, want 0x02", stream[3].Data)
	}
	if stream[4].Data != 0x00 {
		t.Errorf("LEN_HI = 0x%02X, want 0x00", stream[4].Data)
	}

	// Check payload
	if stream[5].Data != 0xAA {
		t.Errorf("payload[0] = 0x%02X, want 0xAA", stream[5].Data)
	}
	if stream[6].Data != 0xBB {
		t.Errorf("payload[1] = 0x%02X, want 0xBB", stream[6].Data)
	}

	// Check EOP
	if !stream[len(stream)-1].Eop {
		t.Error("last byte should be EOP")
	}
}

func TestFlit_EmptyPayload(t *testing.T) {
	stream := Flit(1, 0x00, 0x40, nil, false)
	// Wire: LAYER | MODULE | CTRL | LEN_LO=0 | LEN_HI=0 | CRC_HI | CRC_LO = 7 bytes
	if len(stream) != 7 {
		t.Fatalf("Flit(empty payload) length = %d, want 7", len(stream))
	}
	if stream[3].Data != 0x00 {
		t.Errorf("LEN_LO = 0x%02X, want 0x00", stream[3].Data)
	}
}

func TestFlit_Corrupt(t *testing.T) {
	payload := []byte{0x10, 0x20, 0x30}
	stream := Flit(1, 0x01, 0x40, payload, true)

	// The corrupt flag should flip a payload byte
	// Check that at least one byte differs from the non-corrupt version
	streamClean := Flit(1, 0x01, 0x40, payload, false)

	differ := false
	for i := range stream {
		if stream[i].Data != streamClean[i].Data {
			differ = true
			break
		}
	}
	if !differ {
		t.Error("corrupt=true should produce different bytes")
	}
}

func TestFlit_LargePayload(t *testing.T) {
	payload := make([]byte, 256)
	for i := range payload {
		payload[i] = byte(i)
	}
	stream := Flit(1, 0x00, 0x40, payload, false)
	expectedLen := 4 + 256 + 3 // header + payload + layer + CRC
	if len(stream) != expectedLen {
		t.Fatalf("Flit(256-byte payload) length = %d, want %d", len(stream), expectedLen)
	}
}

func TestFlit_SOP_EOP_Propagation(t *testing.T) {
	stream := Flit(1, 0x00, 0x40, []byte{0xAA}, false)
	for i, sb := range stream {
		if i == 0 && !sb.Sop {
			t.Errorf("byte %d should be SOP", i)
		}
		if i != 0 && sb.Sop {
			t.Errorf("byte %d should not be SOP", i)
		}
		if i == len(stream)-1 && !sb.Eop {
			t.Errorf("byte %d should be EOP", i)
		}
		if i != len(stream)-1 && sb.Eop {
			t.Errorf("byte %d should not be EOP", i)
		}
	}
}

// ============================================================================
// WithVC tests
// ============================================================================

func TestWithVC(t *testing.T) {
	stream := Flit(1, 0x00, 0x40, []byte{0xAA}, false)
	result := WithVC(stream, 0x02)
	if len(result) != len(stream) {
		t.Fatalf("WithVC changed length: %d != %d", len(result), len(stream))
	}
	for i, sb := range result {
		if sb.Vc != 0x02 {
			t.Errorf("byte %d Vc = %d, want 2", i, sb.Vc)
		}
	}
}

// ============================================================================
// StubOutput tests
// ============================================================================

func TestStubOutput_BiasZero(t *testing.T) {
	dma := []byte{0x01, 0x40, 0x02, 0x00, 0xAA, 0xBB}
	result := StubOutput(dma, 0)
	for i, b := range result {
		if b != dma[i] {
			t.Errorf("StubOutput(bias=0)[%d] = 0x%02X, want 0x%02X", i, b, dma[i])
		}
	}
}

func TestStubOutput_WithBias(t *testing.T) {
	// DMA: DEST=0x01, CTRL=0x40, LEN=1, payload=[0x10]
	dma := []byte{0x01, 0x40, 0x01, 0x00, 0x10}
	// CRC is not included in the DMA slice for StubOutput
	result := StubOutput(dma, 0x05)
	// payload[0] should be (0x10 + 0x05) & 0xFF = 0x15
	if result[4] != 0x15 {
		t.Errorf("StubOutput bias: result[4] = 0x%02X, want 0x15", result[4])
	}
	// Head bytes should be unchanged
	if result[0] != 0x01 || result[1] != 0x40 || result[2] != 0x01 || result[3] != 0x00 {
		t.Errorf("head bytes modified: %v", result[:4])
	}
}

func TestStubOutput_ShortDMA(t *testing.T) {
	// Should not panic
	result := StubOutput([]byte{0x01}, 0x05)
	if len(result) != 1 {
		t.Errorf("StubOutput(short DMA) returned %d bytes, want 1", len(result))
	}
}

func TestStubOutput_NilDMA(t *testing.T) {
	result := StubOutput(nil, 0x05)
	if result != nil {
		t.Errorf("StubOutput(nil) returned %v, want nil", result)
	}
}

func TestStubOutput_PayloadWrap(t *testing.T) {
	// Bias causes byte wrap-around
	dma := []byte{0x01, 0x40, 0x01, 0x00, 0xFE}
	result := StubOutput(dma, 0x05)
	if result[4] != 0x03 { // (0xFE + 0x05) & 0xFF = 0x03
		t.Errorf("wrap: result[4] = 0x%02X, want 0x03", result[4])
	}
}

// ============================================================================
// Golden tests
// ============================================================================

func TestGolden_Echo(t *testing.T) {
	payload := []byte{1, 2, 3, 4}
	result := Golden("echo", payload, nil, nil, 0)
	// Echo returns payload copy
	resultBytes := result.([]byte)
	for i, b := range resultBytes {
		if b != payload[i] {
			t.Errorf("echo[%d] = %d, want %d", i, b, payload[i])
		}
	}
}

func TestGolden_Sum(t *testing.T) {
	payload := []byte{1, 2, 3, 4}
	result := Golden("sum", payload, nil, nil, 0)
	if result.(uint64) != 10 {
		t.Errorf("sum = %d, want 10", result)
	}
}

func TestGolden_Dot(t *testing.T) {
	payload := []byte{1, 2, 3}
	weights := []int{4, 5, 6}
	result := Golden("dot", payload, weights, nil, 0)
	// 1*4 + 2*5 + 3*6 = 32
	if result.(uint64) != 32 {
		t.Errorf("dot = %d, want 32", result)
	}
}

func TestGolden_DotWithBias(t *testing.T) {
	// Bias is applied to payload BEFORE the kernel
	payload := []byte{1, 2, 3}
	weights := []int{4, 5, 6}
	result := Golden("dot", payload, weights, nil, 0x0A)
	// Biased payload: [11, 12, 13], dot = 11*4 + 12*5 + 13*6 = 44+60+78 = 182
	if result.(uint64) != 182 {
		t.Errorf("dot(bias=10) = %d, want 182", result)
	}
}

// ============================================================================
// WriteStimulus / ParseDelivery round-trip
// ============================================================================

func TestWriteStimulus_RoundTrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "stim.hex")

	stream := Flit(1, 0x23, 0x40, []byte{0xAA, 0xBB}, false)
	n := WriteStimulus(stream, path)
	if n != len(stream) {
		t.Fatalf("WriteStimulus returned %d, want %d", n, len(stream))
	}

	// Read back
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	lines := splitLines(string(data))
	if len(lines) != len(stream) {
		t.Fatalf("hex file has %d lines, want %d", len(lines), len(stream))
	}
}

func splitLines(s string) []string {
	var lines []string
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == '\n' {
			lines = append(lines, s[start:i])
			start = i + 1
		}
	}
	if start < len(s) {
		lines = append(lines, s[start:])
	}
	return lines
}

// ============================================================================
// ParseDelivery tests
// ============================================================================

func TestParseDelivery_Empty(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "empty.log")
	os.WriteFile(path, nil, 0o644)
	d := ParseDelivery(path)
	if len(d.Inject) != 0 || len(d.Tail) != 0 || len(d.Nodes) != 0 {
		t.Errorf("empty ParseDelivery returned non-empty data")
	}
}

func TestParseDelivery_Inject(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "inject.log")
	os.WriteFile(path, []byte("I 100 42 1 0 2\nI 200 43 1 0 2\n"), 0o644)
	d := ParseDelivery(path)
	if len(d.Inject) != 2 {
		t.Fatalf("Inject len = %d, want 2", len(d.Inject))
	}
	if d.Inject[0].Cyc != 100 {
		t.Errorf("Inject[0].Cyc = %d, want 100", d.Inject[0].Cyc)
	}
}

func TestParseDelivery_Node(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "node.log")
	os.WriteFile(path, []byte("N 100 1 2 3 42 1 0 2 0\n"), 0o644)
	d := ParseDelivery(path)
	n := NodeID{L: 1, X: 2, Y: 3}
	if len(d.Nodes[n]) != 1 {
		t.Fatalf("Nodes[%v] len = %d, want 1", n, len(d.Nodes[n]))
	}
}

func TestParseDelivery_Corrupt(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "corrupt.log")
	os.WriteFile(path, []byte("C 100 1 2 3\n"), 0o644)
	d := ParseDelivery(path)
	n := NodeID{L: 1, X: 2, Y: 3}
	if len(d.Corrupt[n]) != 1 {
		t.Fatalf("Corrupt[%v] len = %d, want 1", n, len(d.Corrupt[n]))
	}
}

func TestParseDelivery_MalformedLines(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "malformed.log")
	os.WriteFile(path, []byte("I\nI 100\nX 100 1\nY 100 1 2\nN 100\nunknown\n\n"), 0o644)
	// Should not panic on malformed input
	d := ParseDelivery(path)
	_ = d
}

func TestParseDelivery_BlankLines(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "blank.log")
	os.WriteFile(path, []byte("\n\n\nI 100 42 1 0 2\n\n\n"), 0o644)
	d := ParseDelivery(path)
	if len(d.Inject) != 1 {
		t.Errorf("Inject len = %d, want 1 (blank lines should be skipped)", len(d.Inject))
	}
}
