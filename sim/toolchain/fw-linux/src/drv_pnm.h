/**
 * drv_pnm.h — PNM register window access for router_sbc bare-metal init.
 *
 * The central PNM register window sits at 0xF000_0000 on the SoC bus.
 * Each register is 32-bit, word-addressed (offsets 0x00..0x24).
 */

#ifndef DRV_PNM_H
#define DRV_PNM_H

#include <stdint.h>

#define PNM_BASE            0xF0000000u

/* Standard register offsets (from pnm_defs.vh / router_chip.v) */
#define PNM_REG_STATUS      0x00
#define PNM_REG_ROUTE_LAYER 0x04
#define PNM_REG_ROUTE_MODULE 0x08
#define PNM_REG_ROUTE_LEN   0x0C
#define PNM_REG_ROUTE_DATA  0x10
#define PNM_REG_ROUTE_STATUS 0x14
#define PNM_REG_ROUTE_RESULT 0x18
#define PNM_REG_ROUTE_ERRORS 0x1C
#define PNM_REG_ROUTE_DISPATCH 0x20
#define PNM_REG_ROUTE_WEIGHTS 0x24

static inline uint32_t pnm_read(volatile uint32_t *base, uint32_t off)
{
    return base[off >> 2];
}

static inline void pnm_write(volatile uint32_t *base, uint32_t off, uint32_t val)
{
    base[off >> 2] = val;
}

#endif /* DRV_PNM_H */
