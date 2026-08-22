package pnm

// crc16 is CRC-16/CCITT-FALSE (init 0xFFFF, poly 0x1021) over the DMA body
// [DEST, CTRL, LEN_LO, LEN_HI, payload...] — the hardware twin of crc16.v
// and of sim/virtual_units.py crc16(). Keep all three in lockstep.
func crc16(data []byte) uint32 {
	crc := uint32(0xFFFF)
	for _, b := range data {
		crc ^= uint32(b) << 8
		for i := 0; i < 8; i++ {
			if crc&0x8000 != 0 {
				crc = (crc<<1 ^ 0x1021) & 0xFFFF
			} else {
				crc = crc << 1 & 0xFFFF
			}
		}
	}
	return crc
}

// crcBytes returns (CRC_HI, CRC_LO) as carried on the wire, big-endian.
func crcBytes(body []byte) (byte, byte) {
	c := crc16(body)
	return byte(c >> 8), byte(c & 0xFF)
}
