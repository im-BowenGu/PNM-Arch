/**
 * plan.c — the dispatch plan as data (C side).
 *
 * Decoder and re-encoder for the plan wire format defined in plan.h; the
 * device executes a plan it received, it never re-plans.  All byte I/O is
 * explicit and big-endian so the encoding is identical to the Go twin
 * (sim/internal/pnm/plan.go) on every ABI.
 */
#include "plan.h"
#include <string.h>

static uint16_t rd16(const uint8_t *b) {
    return (uint16_t)(((uint16_t)b[0] << 8) | (uint16_t)b[1]);
}

static uint32_t rd32(const uint8_t *b) {
    return ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) |
           ((uint32_t)b[2] << 8) | (uint32_t)b[3];
}

static void wr16(uint8_t *b, uint16_t v) {
    b[0] = (uint8_t)(v >> 8);
    b[1] = (uint8_t)v;
}

static void wr32(uint8_t *b, uint32_t v) {
    b[0] = (uint8_t)(v >> 24);
    b[1] = (uint8_t)(v >> 16);
    b[2] = (uint8_t)(v >> 8);
    b[3] = (uint8_t)v;
}

static uint8_t phase_code(const char *p) {
    if (strcmp(p, "moe") == 0) return 1;
    if (strcmp(p, "kv_offload") == 0) return 2;
    if (strcmp(p, "flash_attn") == 0) return 3;
    if (strcmp(p, "norm") == 0) return 4;
    return 0; /* dense */
}

static const char *phase_name(uint8_t c) {
    switch (c) {
    case 1: return "moe";
    case 2: return "kv_offload";
    case 3: return "flash_attn";
    case 4: return "norm";
    default: return "dense";
    }
}

static uint8_t kv_code(const char *a) {
    if (strcmp(a, "store") == 0) return 1;
    if (strcmp(a, "load") == 0) return 2;
    if (strcmp(a, "evict") == 0) return 3;
    return 0; /* none */
}

static const char *kv_name(uint8_t c) {
    switch (c) {
    case 1: return "store";
    case 2: return "load";
    case 3: return "evict";
    default: return "";
    }
}

static void decode_record(const uint8_t *o, dispatch_record_t *r) {
    r->layer = (int)rd16(o + 0);
    strncpy(r->phase, phase_name(o[2]), sizeof(r->phase));
    r->cu_type = (cu_type_t)o[3];
    r->target.L = (int8_t)o[4];
    r->target.X = o[5];
    r->target.Y = o[6];
    strncpy(r->kv_action, kv_name(o[7]), sizeof(r->kv_action));
    r->expert_idx = (int)(int16_t)rd16(o + 8);
    r->flit_bytes = (int)rd16(o + 10);
    r->flash_tile_q = (int)rd16(o + 12);
    r->flash_tile_kv = (int)rd16(o + 14);
    r->flash_num_tiles = (int)rd16(o + 16);
    r->window_start = (int)(int16_t)rd16(o + 18);
    r->window_end = (int)(int16_t)rd16(o + 20);
    r->group_size = (int)rd16(o + 22);
    r->repeat_kv = o[24] != 0;
}

static void encode_record(uint8_t *o, const dispatch_record_t *r) {
    wr16(o + 0, (uint16_t)r->layer);
    o[2] = phase_code(r->phase);
    o[3] = (uint8_t)r->cu_type;
    o[4] = (uint8_t)r->target.L;
    o[5] = r->target.X;
    o[6] = r->target.Y;
    o[7] = kv_code(r->kv_action);
    wr16(o + 8, (uint16_t)(int16_t)r->expert_idx);
    wr16(o + 10, (uint16_t)r->flit_bytes);
    wr16(o + 12, (uint16_t)r->flash_tile_q);
    wr16(o + 14, (uint16_t)r->flash_tile_kv);
    wr16(o + 16, (uint16_t)r->flash_num_tiles);
    wr16(o + 18, (uint16_t)(int16_t)r->window_start);
    wr16(o + 20, (uint16_t)(int16_t)r->window_end);
    wr16(o + 22, (uint16_t)r->group_size);
    o[24] = r->repeat_kv ? 1 : 0;
}

int fw_plan_decode(const uint8_t *buf, int len, plan_header_t *hdr,
                   dispatch_record_t *recs, int max_records, int *num_records) {
    uint32_t count;
    int i;

    if (len < PNM_PLAN_HDR_LEN) return -1;
    if (rd32(buf) != PNM_PLAN_MAGIC) return -2;
    if (buf[4] != PNM_PLAN_VERSION) return -3;

    memset(hdr, 0, sizeof(*hdr));
    hdr->num_hidden_layers = buf[5];
    hdr->board_x = buf[6];
    hdr->board_y = buf[7];
    hdr->num_layers = buf[8];
    hdr->top_k = buf[9];
    count = rd32(buf + 12);
    hdr->count = count;

    if (len < PNM_PLAN_HDR_LEN + (int)count * PNM_PLAN_REC_LEN) return -4;
    if ((int)count > max_records) return -5;

    for (i = 0; i < (int)count; i++) {
        const uint8_t *o = buf + PNM_PLAN_HDR_LEN + i * PNM_PLAN_REC_LEN;
        uint8_t phase = o[2], kv = o[7];
        if (phase > 4 || kv > 3) return -6;
        decode_record(o, &recs[i]);
    }
    *num_records = (int)count;
    return 0;
}

int fw_plan_encode(const plan_header_t *hdr, const dispatch_record_t *recs,
                   int num_records, uint8_t *buf, int max_len) {
    int i, total = PNM_PLAN_HDR_LEN + num_records * PNM_PLAN_REC_LEN;

    if (max_len < total) return -1;
    memset(buf, 0, (size_t)total);

    wr32(buf, PNM_PLAN_MAGIC);
    buf[4] = PNM_PLAN_VERSION;
    buf[5] = hdr->num_hidden_layers;
    buf[6] = hdr->board_x;
    buf[7] = hdr->board_y;
    buf[8] = hdr->num_layers;
    buf[9] = hdr->top_k;
    wr32(buf + 12, (uint32_t)num_records);

    for (i = 0; i < num_records; i++)
        encode_record(buf + PNM_PLAN_HDR_LEN + i * PNM_PLAN_REC_LEN, &recs[i]);
    return total;
}

void fw_plan_apply(firmware_t *fw, const plan_header_t *hdr) {
    if (hdr->num_hidden_layers > 0) fw->num_hidden_layers = hdr->num_hidden_layers;
    if (hdr->board_x > 0) fw->board_x = hdr->board_x;
    if (hdr->board_y > 0) fw->board_y = hdr->board_y;
    if (hdr->num_layers > 0) fw->num_layers = hdr->num_layers;
    if (hdr->top_k > 0) fw->top_k_experts = hdr->top_k;
}
