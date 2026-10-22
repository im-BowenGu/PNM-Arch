/**
 * plan.h — the dispatch plan as data (C side).
 *
 * The dispatch plan is compiled once on the host (sim/internal/pnm/plan.go)
 * and executed by the device; this header is the C twin of the plan wire
 * format, so the host compiler and the device firmware are linked by bytes,
 * not by two parallel planners.  Keep in lockstep with plan.go.
 *
 * Header 16 bytes: magic "PNMP" | version 1 | num_hidden_layers | board_x |
 * board_y | num_layers | top_k | reserved[2] | count (u32 BE), then
 * count x 32-byte records:
 *
 *   0..1   layer (u16 BE)
 *   2      phase (0 dense, 1 moe, 2 kv_offload, 3 flash_attn, 4 norm)
 *   3      cu_type
 *   4      target L (i8)
 *   5      target X
 *   6      target Y
 *   7      kv_action (0 none, 1 store, 2 load, 3 evict)
 *   8..9   expert (i16 BE)
 *   10..11 flit_bytes (u16 BE; the fabric LEN field caps payloads at 65535)
 *   12..13 flash_tile_q   14..15 flash_tile_kv   16..17 flash_num_tiles
 *   18..19 window_start   20..21 window_end       22..23 group_size
 *   24     repeat_kv
 *   25..31 reserved (0)
 *
 * All values big-endian.
 */
#ifndef PNM_PLAN_H
#define PNM_PLAN_H

#include <stdint.h>
#include "pnm_fw.h"

#define PNM_PLAN_MAGIC    0x504E4D50u /* "PNMP" */
#define PNM_PLAN_VERSION  1
#define PNM_PLAN_HDR_LEN  16
#define PNM_PLAN_REC_LEN  32
#define PNM_PLAN_MAX_RECORDS 4096
#define PNM_PLAN_MAX_BYTES (PNM_PLAN_HDR_LEN + \
                            PNM_PLAN_MAX_RECORDS * PNM_PLAN_REC_LEN)

typedef struct {
    uint8_t  num_hidden_layers; /* 0 = unknown */
    uint8_t  board_x;
    uint8_t  board_y;
    uint8_t  num_layers;
    uint8_t  top_k;
    uint32_t count;
} plan_header_t;

/* Decode a plan buffer into records.  Returns 0 on success, < 0 on failure:
 * -1 buffer shorter than header, -2 bad magic, -3 unsupported version,
 * -4 buffer shorter than records, -5 record count exceeds max_records,
 * -6 unknown phase/kv code. */
int fw_plan_decode(const uint8_t *buf, int len, plan_header_t *hdr,
                   dispatch_record_t *recs, int max_records, int *num_records);

/* Encode records into a plan buffer (the inverse of fw_plan_decode; used by
 * the byte-equality test and by any device that forwards a received plan).
 * Returns the number of bytes written, or < 0 if the buffer is too small. */
int fw_plan_encode(const plan_header_t *hdr, const dispatch_record_t *recs,
                   int num_records, uint8_t *buf, int max_len);

/* Apply a plan header to the firmware: a received plan validates itself. */
void fw_plan_apply(firmware_t *fw, const plan_header_t *hdr);

#endif /* PNM_PLAN_H */
