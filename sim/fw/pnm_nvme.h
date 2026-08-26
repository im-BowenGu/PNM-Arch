/**
 * pnm_nvme.h — NVMe storage driver for the PNM central router chip.
 *
 * Provides block-level access to the nvme_ctrl HDL module through its
 * AXI-Lite register window. Used by the firmware for:
 *   - Model weight persistence across power cycles
 *   - KV cache overflow to NVMe-backed swap
 *   - Lustre FS object storage backend
 *
 * The register window is at a fixed physical base address on the SoC
 * memory map (NVME@0xD0000000, 64-byte window). On MCU targets the
 * caller provides a volatile uint32_t* pointer instead.
 */

#ifndef PNM_NVME_H
#define PNM_NVME_H

#include <stdint.h>
#include <stdbool.h>
#include "pnm_fw.h"

/* ── Register offsets ──────────────────────────────────────────────── */

#define NVME_REG_CAP       0x00
#define NVME_REG_VS        0x04
#define NVME_REG_CSTS      0x08
#define NVME_REG_AQA       0x0C
#define NVME_REG_ASQ_LO    0x10
#define NVME_REG_ASQ_HI    0x14
#define NVME_REG_ACQ_LO    0x18
#define NVME_REG_ACQ_HI    0x1C
#define NVME_REG_CMD_OP    0x20
#define NVME_REG_CMD_SLBA_LO 0x24
#define NVME_REG_CMD_SLBA_HI 0x28
#define NVME_REG_CMD_NLB   0x2C
#define NVME_REG_CMD_BUF_LO  0x30
#define NVME_REG_CMD_BUF_HI  0x34
#define NVME_REG_STATUS    0x38
#define NVME_REG_INT_EN    0x3C

/* ── Constants ─────────────────────────────────────────────────────── */

#define NVME_CMD_READ      0x01
#define NVME_CMD_WRITE     0x02
#define NVME_CMD_FLUSH     0x03

#define NVME_BLOCK_SIZE    512
#define NVME_MAX_TRANSFER  65536

#define NVME_STS_DONE      0x00000001u
#define NVME_STS_ERROR     0x00000002u

/* ── Device handle ─────────────────────────────────────────────────── */

typedef struct {
    volatile uint32_t *regs;     /* register window base               */
    bool     ready;
    bool     has_error;
    uint32_t error_code;
    uint32_t blocks_read;
    uint32_t blocks_written;
    uint32_t flushes;
} nvme_dev_t;

/* ── API ───────────────────────────────────────────────────────────── */

/* Initialize: probe CAP, set CSTS.ready, clear errors.
 * regs_base is the physical/virtual base of the register window. */
int  nvme_init(nvme_dev_t *dev, volatile uint32_t *regs_base);

/* Submit and poll-wait for a single command.
 * Returns 0 on success, -1 on timeout or device error. */
int  nvme_read_blocks(nvme_dev_t *dev, uint64_t lba, uint16_t nlb,
                      uint32_t buf_lo, uint32_t buf_hi);
int  nvme_write_blocks(nvme_dev_t *dev, uint64_t lba, uint16_t nlb,
                       uint32_t buf_lo, uint32_t buf_hi);
int  nvme_flush(nvme_dev_t *dev);

/* Read status without blocking. */
bool nvme_busy(const nvme_dev_t *dev);

#endif /* PNM_NVME_H */
