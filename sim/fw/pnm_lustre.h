/**
 * pnm_lustre.h — Lustre distributed filesystem client for the PNM router.
 *
 * Minimal Lustre client targeting the router chip's firmware. Provides
 * file striping across local NVMe-backed object storage, so each router
 * node acts as both a Lustre OSS (Object Storage Server) endpoint and
 * a PNM compute node.
 *
 * Design: the router's DRAM window holds a flat object store keyed by
 * (OST index, object ID). Files are striped round-robin across all
 * discovered OSTs with configurable stripe count and size.
 *
 * No dynamic allocation — the object table is statically sized.
 */

#ifndef PNM_LUSTRE_H
#define PNM_LUSTRE_H

#include <stdint.h>
#include <stdbool.h>
#include "pnm_fw.h"
#include "pnm_nvme.h"

/* ── Configuration ─────────────────────────────────────────────────── */

#define LUSTRE_MAX_OST       16      /* max object storage targets     */
#define LUSTRE_MAX_FILES     64      /* max open file entries          */
#define LUSTRE_STRIPE_SIZE   1048576 /* 1 MB default stripe            */
#define LUSTRE_MAX_STRIPE    8       /* max stripes per file           */
#define LUSTRE_NAME_LEN      32

/* ── OST descriptor ────────────────────────────────────────────────── */

typedef struct {
    bool        active;
    uint8_t     ost_index;
    uint64_t    lba_base;        /* starting LBA on the NVMe device    */
    uint64_t    lba_count;       /* total blocks in this OST          */
    uint64_t    blocks_used;
} lustre_ost_t;

/* ── File entry (striping layout) ──────────────────────────────────── */

typedef struct {
    char         name[LUSTRE_NAME_LEN];
    bool         open;
    uint64_t     size_bytes;
    uint16_t     stripe_count;
    uint32_t     stripe_size;
    uint8_t      start_ost;      /* first OST for round-robin         */
    uint64_t     obj_id_base;    /* base object ID                    */
} lustre_file_t;

/* ── Client state ──────────────────────────────────────────────────── */

typedef struct {
    nvme_dev_t    *nvme;                        /* backing storage     */
    lustre_ost_t   osts[LUSTRE_MAX_OST];
    int            ost_count;
    lustre_file_t  files[LUSTRE_MAX_FILES];
    int            file_count;
    uint64_t       next_obj_id;
    uint32_t       errors;
} lustre_client_t;

/* ── API ───────────────────────────────────────────────────────────── */

/* Initialize the Lustre client over an NVMe device. Splits the device
 * into `n_ost` equal-sized object storage targets. */
int  lustre_init(lustre_client_t *lc, nvme_dev_t *nvme, int n_ost);

/* Create a striped file. Returns file index or -1. */
int  lustre_create(lustre_client_t *lc, const char *name,
                   uint16_t stripe_count, uint32_t stripe_size);

/* Open an existing file by name. Returns file index or -1. */
int  lustre_open(lustre_client_t *lc, const char *name);

/* Write data at a byte offset within the file.
 * Stripes across OSTs; returns bytes written or -1. */
int64_t lustre_write(lustre_client_t *lc, int fd,
                     uint64_t offset, const uint8_t *data, uint64_t len);

/* Read data at a byte offset within the file.
 * Returns bytes read or -1. */
int64_t lustre_read(lustre_client_t *lc, int fd,
                    uint64_t offset, uint8_t *data, uint64_t len);

/* Close a file (flush pending writes to NVMe). */
int  lustre_close(lustre_client_t *lc, int fd);

/* Flush all dirty state to the NVMe device. */
int  lustre_sync(lustre_client_t *lc);

#endif /* PNM_LUSTRE_H */
