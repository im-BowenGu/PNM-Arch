/**
 * pnm_lustre.c — Lustre distributed filesystem client for the PNM router.
 *
 * Implements round-robin file striping over NVMe-backed OSTs. Each file
 * is divided into stripe_size chunks that alternate across the active
 * OST pool starting at start_ost. Object IDs are allocated sequentially.
 *
 * The backing storage is the nvme_ctrl register window (see pnm_nvme.c).
 * In simulation, DMA buffer addresses point into the router's DRAM
 * stub; on production silicon they point into real LPDDR5.
 */

#include "pnm_lustre.h"
#include <string.h>

/* ── Internal helpers ──────────────────────────────────────────────── */

static lustre_ost_t *ost_for_stripe(lustre_client_t *lc,
                                    const lustre_file_t *f, int stripe_idx)
{
    int ost = (f->start_ost + stripe_idx) % lc->ost_count;
    if (!lc->osts[ost].active)
        return 0;
    return &lc->osts[ost];
}

static uint64_t obj_lba(lustre_client_t *lc, lustre_ost_t *ost,
                        uint64_t obj_id)
{
    (void)lc;
    /* Object data starts at lba_base + (obj_id * blocks_per_obj).
     * We use one LBA per object for simplicity in the behavioral model;
     * production maps multi-block objects via extent lists. */
    return ost->lba_base + (obj_id % ost->lba_count);
}

/* ── API ───────────────────────────────────────────────────────────── */

int lustre_init(lustre_client_t *lc, nvme_dev_t *nvme, int n_ost)
{
    int i;
    uint64_t total_blocks, per_ost;

    memset(lc, 0, sizeof(*lc));
    lc->nvme = nvme;

    if (!nvme || !nvme->ready || n_ost <= 0 || n_ost > LUSTRE_MAX_OST) {
        lc->errors++;
        return -1;
    }

    /* Total capacity: assume 1M blocks per device as a placeholder.
     * Production reads this from NVMe identify namespace data. */
    total_blocks = 1048576;
    per_ost = total_blocks / (uint64_t)n_ost;

    for (i = 0; i < n_ost; i++) {
        lc->osts[i].active     = true;
        lc->osts[i].ost_index  = (uint8_t)i;
        lc->osts[i].lba_base   = per_ost * (uint64_t)i;
        lc->osts[i].lba_count  = per_ost;
        lc->osts[i].blocks_used = 0;
    }
    lc->ost_count   = n_ost;
    lc->next_obj_id = 1;

    return 0;
}

int lustre_create(lustre_client_t *lc, const char *name,
                  uint16_t stripe_count, uint32_t stripe_size)
{
    int fd;
    lustre_file_t *f;

    if (!name || lc->file_count >= LUSTRE_MAX_FILES ||
        stripe_count == 0 || stripe_count > LUSTRE_MAX_STRIPE ||
        stripe_size == 0 || stripe_size > LUSTRE_STRIPE_SIZE) {
        lc->errors++;
        return -1;
    }

    /* Reject duplicate names */
    for (fd = 0; fd < lc->file_count; fd++) {
        if (strncmp(lc->files[fd].name, name, LUSTRE_NAME_LEN) == 0) {
            lc->errors++;
            return -1;
        }
    }

    fd = lc->file_count++;
    f = &lc->files[fd];
    strncpy(f->name, name, LUSTRE_NAME_LEN - 1);
    f->name[LUSTRE_NAME_LEN - 1] = '\0';
    f->open         = true;
    f->size_bytes   = 0;
    f->stripe_count = stripe_count;
    f->stripe_size  = stripe_size;
    f->start_ost    = (uint8_t)(lc->file_count % lc->ost_count);
    f->obj_id_base  = lc->next_obj_id;
    lc->next_obj_id += stripe_count;

    return fd;
}

int lustre_open(lustre_client_t *lc, const char *name)
{
    int fd;
    for (fd = 0; fd < lc->file_count; fd++) {
        if (!lc->files[fd].open)
            continue;
        if (strncmp(lc->files[fd].name, name, LUSTRE_NAME_LEN) == 0)
            return fd;
    }
    lc->errors++;
    return -1;
}

int64_t lustre_write(lustre_client_t *lc, int fd,
                     uint64_t offset, const uint8_t *data, uint64_t len)
{
    lustre_file_t *f;
    uint64_t written = 0;

    if (fd < 0 || fd >= lc->file_count || !lc->files[fd].open || !data || len == 0) {
        lc->errors++;
        return -1;
    }

    f = &lc->files[fd];

    while (written < len) {
        uint64_t abs_off    = offset + written;
        int      stripe_idx = (int)((abs_off / f->stripe_size) % f->stripe_count);
        uint64_t stripe_off = abs_off % f->stripe_size;
        uint64_t chunk      = f->stripe_size - stripe_off;
        lustre_ost_t *ost;
        uint64_t lba;
        uint16_t nlb;

        if (chunk > len - written)
            chunk = len - written;

        ost = ost_for_stripe(lc, f, stripe_idx);
        if (!ost) {
            lc->errors++;
            return -1;
        }

        lba = obj_lba(lc, ost, f->obj_id_base + stripe_idx) + stripe_off / 512;
        nlb = (uint16_t)(((chunk + 511) / 512) - 1);

        /* DMA buffer: use a fixed staging area in DRAM.
         * The caller is responsible for placing data there or we
         * copy it through the DRAM stub's address space. */
        if (nvme_write_blocks(lc->nvme, lba, nlb,
                              (uint32_t)(0x80000000u + (offset & 0x0FFFFFFFu)),
                              0) != 0) {
            lc->errors++;
            return -1;
        }
        ost->blocks_used += nlb + 1;
        written += chunk;
    }

    if (offset + len > f->size_bytes)
        f->size_bytes = offset + len;

    return (int64_t)written;
}

int64_t lustre_read(lustre_client_t *lc, int fd,
                    uint64_t offset, uint8_t *data, uint64_t len)
{
    lustre_file_t *f;
    uint64_t total = 0;

    if (fd < 0 || fd >= lc->file_count || !lc->files[fd].open || !data || len == 0) {
        lc->errors++;
        return -1;
    }

    f = &lc->files[fd];
    if (offset >= f->size_bytes)
        return 0;
    if (offset + len > f->size_bytes)
        len = f->size_bytes - offset;

    while (total < len) {
        uint64_t abs_off    = offset + total;
        int      stripe_idx = (int)((abs_off / f->stripe_size) % f->stripe_count);
        uint64_t stripe_off = abs_off % f->stripe_size;
        uint64_t chunk      = f->stripe_size - stripe_off;
        lustre_ost_t *ost;
        uint64_t lba;
        uint16_t nlb;

        if (chunk > len - total)
            chunk = len - total;

        ost = ost_for_stripe(lc, f, stripe_idx);
        if (!ost) {
            lc->errors++;
            return -1;
        }

        lba = obj_lba(lc, ost, f->obj_id_base + stripe_idx) + stripe_off / 512;
        nlb = (uint16_t)(((chunk + 511) / 512) - 1);

        if (nvme_read_blocks(lc->nvme, lba, nlb,
                             (uint32_t)(0x80000000u + (offset & 0x0FFFFFFFu)),
                             0) != 0) {
            lc->errors++;
            return -1;
        }
        total += chunk;
    }

    return (int64_t)total;
}

int lustre_close(lustre_client_t *lc, int fd)
{
    if (fd < 0 || fd >= lc->file_count || !lc->files[fd].open) {
        lc->errors++;
        return -1;
    }
    lc->files[fd].open = false;
    return lustre_sync(lc);
}

int lustre_sync(lustre_client_t *lc)
{
    return nvme_flush(lc->nvme);
}
