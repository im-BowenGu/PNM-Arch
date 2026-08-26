/* pnm_regs.h — PNM router register definitions for router_mcu
 *
 * Matches the hardware register map in HDL/router_mcu.v.
 * All accesses are 32-bit aligned word writes/reads.
 */

#ifndef PNM_REGS_H
#define PNM_REGS_H

#include <stdint.h>

#define PNM_BASE        0xF0000000u

#define PNM_CTRL        (*(volatile uint32_t *)(PNM_BASE + 0x00))
#define PNM_LAYER       (*(volatile uint32_t *)(PNM_BASE + 0x04))
#define PNM_MODULE      (*(volatile uint32_t *)(PNM_BASE + 0x08))
#define PNM_LEN         (*(volatile uint32_t *)(PNM_BASE + 0x0C))
#define PNM_DATA        (*(volatile uint32_t *)(PNM_BASE + 0x10))
#define PNM_STATUS      (*(volatile uint32_t *)(PNM_BASE + 0x14))
#define PNM_RESULT      (*(volatile uint32_t *)(PNM_BASE + 0x18))
#define PNM_ERRORS      (*(volatile uint32_t *)(PNM_BASE + 0x1C))
#define PNM_DISPATCHES  (*(volatile uint32_t *)(PNM_BASE + 0x20))
#define PNM_WEIGHTS     (*(volatile uint32_t *)(PNM_BASE + 0x24))

/* CTRL bits */
#define PNM_CTRL_INJECT   (1u << 0)
#define PNM_CTRL_BOOTDONE (1u << 2)

/* STATUS bits */
#define PNM_STATUS_BUSY   (1u << 0)

static inline void pnm_write_payload(const uint8_t *buf, uint16_t len) {
    for (uint16_t i = 0; i < len; i++)
        PNM_DATA = buf[i];
}

static inline void pnm_inject(uint8_t layer, uint8_t module,
                              const uint8_t *payload, uint16_t len) {
    while (PNM_STATUS & PNM_STATUS_BUSY) {}
    PNM_LAYER  = layer;
    PNM_MODULE = module;
    PNM_LEN    = len;
    pnm_write_payload(payload, len);
    PNM_CTRL = PNM_CTRL_INJECT;
}

static inline void pnm_signal_boot_done(void) {
    PNM_CTRL = PNM_CTRL_BOOTDONE;
}

#endif /* PNM_REGS_H */
