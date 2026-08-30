/**
 * pnm_nvme.c — NVMe storage driver for the PNM central router chip.
 *
 * Implements the register-level protocol expected by HDL/nvme_ctrl.v:
 * write command fields, write STATUS (W1C) to trigger, poll for done.
 */

#include "pnm_nvme.h"

/* Timeout in polling iterations (caller scales by clock rate). */
#define NVME_POLL_TIMEOUT 1000000u

static int nvme_submit(nvme_dev_t *dev, uint8_t op, uint64_t lba,
                       uint16_t nlb, uint32_t buf_lo, uint32_t buf_hi)
{
    volatile uint32_t *r = dev->regs;
    uint32_t poll;

    r[NVME_REG_CMD_OP      >> 2] = op;
    r[NVME_REG_CMD_SLBA_LO >> 2] = (uint32_t)(lba & 0xFFFFFFFFu);
    r[NVME_REG_CMD_SLBA_HI >> 2] = (uint32_t)(lba >> 32);
    r[NVME_REG_CMD_NLB     >> 2] = nlb;
    r[NVME_REG_CMD_BUF_LO  >> 2] = buf_lo;
    r[NVME_REG_CMD_BUF_HI  >> 2] = buf_hi;
    /* Trigger: W1C on STATUS clears prior status and starts the FSM */
    r[NVME_REG_STATUS      >> 2] = 0;

    for (poll = 0; poll < NVME_POLL_TIMEOUT; poll++) {
        uint32_t sts = r[NVME_REG_STATUS >> 2];
        if (sts & NVME_STS_ERROR) {
            dev->has_error  = true;
            dev->error_code = (sts >> 8) & 0xFF;
            return -1;
        }
        if (sts & NVME_STS_DONE)
            return 0;
    }
    dev->has_error = true;
    return -1;
}

int nvme_init(nvme_dev_t *dev, volatile uint32_t *regs_base)
{
    dev->regs          = regs_base;
    dev->ready         = false;
    dev->has_error     = false;
    dev->error_code    = 0;
    dev->blocks_read   = 0;
    dev->blocks_written = 0;
    dev->flushes       = 0;

    if (!dev->regs)
        return -1;

    /* Set CSTS.ready and clear any sticky error. */
    dev->regs[NVME_REG_CSTS >> 2] = 0x00000001u | 0x00000002u;

    /* Verify ready took effect. */
    if (!(dev->regs[NVME_REG_CSTS >> 2] & 0x00000001u))
        return -1;

    dev->ready = true;
    return 0;
}

int nvme_read_blocks(nvme_dev_t *dev, uint64_t lba, uint16_t nlb,
                     uint32_t buf_lo, uint32_t buf_hi)
{
    int rc = nvme_submit(dev, NVME_CMD_READ, lba, nlb, buf_lo, buf_hi);
    if (rc == 0)
        dev->blocks_read += nlb + 1;
    return rc;
}

int nvme_write_blocks(nvme_dev_t *dev, uint64_t lba, uint16_t nlb,
                      uint32_t buf_lo, uint32_t buf_hi)
{
    int rc = nvme_submit(dev, NVME_CMD_WRITE, lba, nlb, buf_lo, buf_hi);
    if (rc == 0)
        dev->blocks_written += nlb + 1;
    return rc;
}

int nvme_flush(nvme_dev_t *dev)
{
    int rc = nvme_submit(dev, NVME_CMD_FLUSH, 0, 0, 0, 0);
    if (rc == 0)
        dev->flushes++;
    return rc;
}

bool nvme_busy(const nvme_dev_t *dev)
{
    uint32_t sts = dev->regs[NVME_REG_STATUS >> 2];
    return !(sts & (NVME_STS_DONE | NVME_STS_ERROR));
}
