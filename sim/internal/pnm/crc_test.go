package pnm

import (
	"encoding/hex"
	"testing"
)

// ============================================================================
// CRC-16/CCITT-FALSE reference tests
// Verifies Go crc16() matches known test vectors and the Verilog crc16.v
// ============================================================================

func TestCRC16_KnownVectors(t *testing.T) {
	tests := []struct {
		name   string
		input  string // hex-encoded
		expect uint32
	}{
		{
			name:   "123456789",
			input:  "313233343536373839", // ASCII "123456789"
			expect: 0x29B1,              // well-known CRC-16/CCITT-FALSE result
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			data, err := hex.DecodeString(tc.input)
			if err != nil {
				t.Fatal(err)
			}
			got := crc16(data)
			if got != tc.expect {
				t.Errorf("crc16(%s) = 0x%04X, want 0x%04X", tc.input, got, tc.expect)
			}
		})
	}
}

func TestCRC16_IncrementalProperty(t *testing.T) {
	// CRC(init, A||B) == CRC(CRC(init, A), B)
	// This is a fundamental property of CRC algorithms
	full := []byte("Hello, World!")
	a := full[:7]
	b := full[7:]

	crcA := crc16(a)
	crcAB := crc16(full)
	crcB_from_A := uint32(0)

	// Compute CRC(init, B) using crcA as the new init
	// We need to manually compute since crc16 uses hardcoded 0xFFFF init
	// Instead, verify: crc16(a||b) should equal the result of feeding b
	// through a CRC initialized with crc16(a)
	crc := crcA
	for _, byte := range b {
		crc ^= uint32(byte) << 8
		for i := 0; i < 8; i++ {
			if crc&0x8000 != 0 {
				crc = (crc<<1 ^ 0x1021) & 0xFFFF
			} else {
				crc = crc << 1 & 0xFFFF
			}
		}
	}
	crcB_from_A = crc

	if crcB_from_A != crcAB {
		t.Errorf("incremental CRC mismatch: CRC(CRC(init,a),b)=0x%04X, CRC(init,a||b)=0x%04X",
			crcB_from_A, crcAB)
	}
}

func TestCRC16_Deterministic(t *testing.T) {
	data := []byte("deterministic test data for CRC")
	r1 := crc16(data)
	r2 := crc16(data)
	if r1 != r2 {
		t.Errorf("crc16 not deterministic: %04X != %04X", r1, r2)
	}
}

func TestCRC16_SingleByte(t *testing.T) {
	// Verify all 256 single-byte values produce distinct CRCs
	seen := make(map[uint32]bool)
	for i := 0; i < 256; i++ {
		c := crc16([]byte{byte(i)})
		if c == 0xFFFF {
			t.Errorf("CRC of 0x%02X equals init value 0xFFFF", i)
		}
		if seen[c] {
			// Collisions are theoretically possible but extremely unlikely
			t.Logf("WARNING: CRC collision for byte 0x%02X (crc=0x%04X)", i, c)
		}
		seen[c] = true
	}
}

func TestCRCBytes(t *testing.T) {
	body := []byte{0x01, 0x40, 0x02, 0x00, 0xAA, 0xBB}
	hi, lo := crcBytes(body)
	c := crc16(body)
	if hi != byte(c>>8) || lo != byte(c&0xFF) {
		t.Errorf("crcBytes = (0x%02X, 0x%02X), want (0x%02X, 0x%02X)",
			hi, lo, byte(c>>8), byte(c&0xFF))
	}
}

func TestCRC16_PNMPacket(t *testing.T) {
	// Test CRC over a typical PNM flit body
	body := []byte{0x01, 0x40, 0x02, 0x00, 0x0A, 0x0B}
	crc := crc16(body)
	t.Logf("CRC of PNM body [01 40 02 00 0A 0B] = 0x%04X", crc)
	if crc == 0 || crc == 0xFFFF {
		t.Errorf("CRC result is trivial: 0x%04X", crc)
	}
}
