package pnm

import (
	"testing"
	"testing/quick"
)

// TestCRC16_ByteFlipProperty verifies that flipping any single byte in the input
// changes the CRC (avalanche property).
func TestCRC16_ByteFlipProperty(t *testing.T) {
	f := func(data []byte) bool {
		if len(data) == 0 || len(data) > 256 {
			return true // skip edge cases
		}
		crc1 := crc16(data)
		for i := range data {
			flipped := make([]byte, len(data))
			copy(flipped, data)
			flipped[i] ^= 0xFF
			crc2 := crc16(flipped)
			if crc1 == crc2 {
				return false // single-byte flip must change CRC
			}
		}
		return true
	}
	if err := quick.Check(f, &quick.Config{MaxCount: 1000}); err != nil {
		t.Error(err)
	}
}

// TestCRC16_AppendProperty verifies CRC(a||b) depends on both a and b.
func TestCRC16_AppendProperty(t *testing.T) {
	f := func(a, b []byte) bool {
		if len(a) == 0 || len(b) == 0 || len(a)+len(b) > 256 {
			return true
		}
		ab := append(append([]byte{}, a...), b...)
		crcAB := crc16(ab)
		crcA := crc16(a)
		crcB := crc16(b)
		// CRC(a||b) != CRC(a) and CRC(a||b) != CRC(b) (with overwhelming probability)
		return crcAB != crcA && crcAB != crcB
	}
	if err := quick.Check(f, &quick.Config{MaxCount: 1000}); err != nil {
		t.Error(err)
	}
}

// TestCRC16_DeterminismProperty verifies the same input always produces the same CRC.
func TestCRC16_DeterminismProperty(t *testing.T) {
	f := func(data []byte) bool {
		if len(data) > 256 {
			return true
		}
		c1 := crc16(data)
		c2 := crc16(data)
		return c1 == c2
	}
	if err := quick.Check(f, &quick.Config{MaxCount: 10000}); err != nil {
		t.Error(err)
	}
}

// TestCRC16_NonEmptyProperty verifies CRC of non-empty data is always non-zero.
func TestCRC16_NonEmptyProperty(t *testing.T) {
	f := func(data []byte) bool {
		if len(data) == 0 || len(data) > 256 {
			return true
		}
		return crc16(data) != 0
	}
	if err := quick.Check(f, &quick.Config{MaxCount: 1000}); err != nil {
		t.Error(err)
	}
}

// TestCRC16_PNMPacketConsistencyProperty verifies CRC is consistent with the
// byte-level PNM packet construction.
func TestCRC16_PNMPacketConsistencyProperty(t *testing.T) {
	f := func(dest byte, ctrl byte, payload []byte) bool {
		if len(payload) > 200 {
			return true
		}
		// Build body: DEST | CTRL | LEN_LO | LEN_HI | payload
		body := make([]byte, 4+len(payload))
		body[0] = dest
		body[1] = ctrl
		body[2] = byte(len(payload) >> 0)
		body[3] = byte(len(payload) >> 8)
		copy(body[4:], payload)

		crc := crc16(body)

		// Rebuild and recompute — must match
		body2 := make([]byte, 4+len(payload))
		body2[0] = dest
		body2[1] = ctrl
		body2[2] = byte(len(payload) >> 0)
		body2[3] = byte(len(payload) >> 8)
		copy(body2[4:], payload)
		crc2 := crc16(body2)

		return crc == crc2
	}
	if err := quick.Check(f, &quick.Config{MaxCount: 1000}); err != nil {
		t.Error(err)
	}
}
