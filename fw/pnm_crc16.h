/**
 * pnm_crc16.h — CRC-16/CCITT-FALSE over the fabric's protected body.
 *
 * The fabric's wire format protects [DEST, CTRL, LEN_LO, LEN_HI, payload]
 * with a CRC-16/CCITT-FALSE: initial value 0xFFFF, polynomial 0x1021, no
 * final XOR, bytes fed MSB-first.  The two existing implementations are
 * HDL/core/crc16.v (the hardware twin) and sim/internal/pnm/crc.go (the
 * harness's); this is the C twin, and the three must stay in lockstep.
 *
 * Header-only, so every translation unit that needs it gets the same code.
 */

#ifndef PNM_CRC16_H
#define PNM_CRC16_H

#include <stdint.h>

/* Update the running CRC with one byte. */
static inline uint16_t pnm_crc16_byte(uint16_t crc, uint8_t byte)
{
    int i;
    crc = (uint16_t)(crc ^ ((uint16_t)byte << 8));
    for (i = 0; i < 8; i++) {
        if (crc & 0x8000u)
            crc = (uint16_t)((uint16_t)(crc << 1) ^ 0x1021u);
        else
            crc = (uint16_t)(crc << 1);
    }
    return crc;
}

/* The CRC of a byte range, as it appears on the wire (big-endian). */
static inline uint16_t pnm_crc16(const uint8_t *data, int len)
{
    uint16_t crc = 0xFFFFu;
    int i;
    for (i = 0; i < len; i++)
        crc = pnm_crc16_byte(crc, data[i]);
    return crc;
}

#endif /* PNM_CRC16_H */
