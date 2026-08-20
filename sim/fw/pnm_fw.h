/**
 * pnm_fw.h — Firmware for the PNM central router chip.
 *
 * This runs as microcode on the router chip's embedded processor.
 * It manages the boot sequence (POST discovery, routing table load,
 * weight upload, MoE gating load) and runtime inference dispatch
 * (dense path, MoE gating, top-K expert selection, KV cache).
 *
 * Supports: bf16_fma, fp16_fma, fp32_fma, fp64_fma, fp32_alu,
 *           int8_mac, bf16_mac_array, fp16_mac_array
 *
 * Hardware targets: ARM Cortex-M/R, RISC-V, or custom microcontroller.
 */

#ifndef PNM_FW_H
#define PNM_FW_H

#include <stdint.h>
#include <stdbool.h>

/* ── Configuration ─────────────────────────────────────────────────── */

#define PNM_MAX_LAYERS      8       /* max physical spine layers       */
#define PNM_MAX_NODES       64      /* max nodes per physical layer    */
#define PNM_MAX_NODES_TOTAL 512     /* PNM_MAX_LAYERS * PNM_MAX_NODES  */
#define PNM_MAX_EXPERTS     256     /* max experts per model layer     */
#define PNM_MAX_TOPK        16      /* max top-k experts per token     */
#define PNM_MAX_MODEL_LAYERS 128    /* max transformer layers          */
#define PNM_KV_CACHE_DEPTH  4096    /* KV cache entries per bank       */
#define PNM_KV_CACHE_BANKS  4       /* directional banks per layer     */
#define PNM_ROUTING_TABLE_SIZE 256  /* max routing table entries       */
#define PNM_WEIGHT_CMD_MAX  1024    /* max weight upload commands      */
#define PNM_FABRIC_LINK_WIDTH 8     /* byte-wide fabric links          */

/* ── Compute Unit Types ────────────────────────────────────────────── */

typedef enum {
    CU_NONE     = 0,
    CU_BF16_FMA = 1,   /* bf16_fma: 16-bit BF16 FMA               */
    CU_FP16_FMA = 2,   /* fp16_fma: 16-bit IEEE FP16 FMA           */
    CU_FP32_FMA = 3,   /* fp32_fma: 32-bit FP FMA                  */
    CU_FP64_FMA = 4,   /* fp64_fma: 64-bit FP FMA                  */
    CU_FP32_ALU = 5,   /* fp32_alu: FP32 multi-function ALU         */
    CU_INT8_MAC = 6,   /* int8_mac: INT8 Multiply-Accumulate        */
    CU_BF16_ARRAY = 7, /* bf16_mac_array: BF16 systolic MAC array   */
    CU_FP16_ARRAY = 8, /* fp16_mac_array: FP16 systolic MAC array   */
} cu_type_t;

/* Compute unit byte widths */
static inline int cu_dtype_bytes(cu_type_t t) {
    switch (t) {
        case CU_BF16_FMA: case CU_FP16_FMA:
        case CU_BF16_ARRAY: case CU_FP16_ARRAY: return 2;
        case CU_FP32_FMA: case CU_FP32_ALU:     return 4;
        case CU_INT8_MAC:                        return 1;
        case CU_FP64_FMA:                        return 8;
        default:                                 return 2;
    }
}

/* ── Node / Coordinate Types ───────────────────────────────────────── */

typedef struct {
    int8_t  L;          /* physical layer (0-based, -1 = router chip) */
    uint8_t X;          /* X column on board                         */
    uint8_t Y;          /* Y row on board                            */
} node_id_t;

static inline uint8_t module_id(node_id_t n) {
    return (uint8_t)((n.X << 4) | n.Y);
}

/* ── Routing Bitmap ────────────────────────────────────────────────── */

typedef struct {
    node_id_t node;
    uint16_t  bitmap;       /* 11-bit: [10:7]LAYER [6]AXIS [5]SIGN [4:0]DIST */
    cu_type_t cu_type;      /* primary compute unit on this node */
} routing_entry_t;

/* ── MoE Expert Map ────────────────────────────────────────────────── */

typedef struct {
    int      model_layer;
    int      expert_idx;
    node_id_t target_node;
    cu_type_t cu_type;
} moe_entry_t;

/* ── Weight Upload Command ─────────────────────────────────────────── */

typedef struct {
    uint8_t  target_layer;
    uint8_t  target_module;
    uint16_t payload_len;
    const uint8_t *payload;
    cu_type_t cu_type;
    int      model_layer;
} weight_cmd_t;

/* ── KV Cache ──────────────────────────────────────────────────────── */

typedef struct {
    uint8_t *entries;           /* flat buffer: depth * entry_bytes   */
    int      depth;
    int      entry_bytes;
    int      write_ptr;
    int      read_ptr;
    int      occupancy;
    bool     full;
    bool     empty;
    char     direction[4];     /* "X+", "X-", "Y+", "Y-"            */
} kv_bank_t;

typedef struct {
    kv_bank_t banks[PNM_KV_CACHE_BANKS];
    int       layer_id;
    int       evictions;
    int       reloads;
} kv_layer_t;

typedef struct {
    kv_layer_t layers[PNM_MAX_LAYERS];
    int        num_layers;
    int        total_evictions;
    int        total_reloads;
} kv_cache_t;

/* ── Firmware State ────────────────────────────────────────────────── */

typedef enum {
    FW_RESET = 0,
    FW_POST_DISCOVERY,
    FW_ROUTING_TABLE,
    FW_WEIGHT_UPLOAD,
    FW_MOE_LOAD,
    FW_READY
} fw_state_t;

typedef struct {
    /* Discovery results */
    int      node_count;
    struct {
        node_id_t node;
        uint8_t   module_id;
        int       bandwidth;
        int       status;
    } inventory[PNM_MAX_NODES_TOTAL];

    /* Routing table */
    routing_entry_t routes[PNM_ROUTING_TABLE_SIZE];
    int             route_count;

    /* MoE expert map */
    moe_entry_t     moe_map[PNM_MAX_EXPERTS * PNM_MAX_MODEL_LAYERS];
    int             moe_count;

    /* Weight commands */
    weight_cmd_t    weight_cmds[PNM_WEIGHT_CMD_MAX];
    int             weight_count;

    /* KV cache */
    kv_cache_t      kv;

    /* Dispatch counters */
    int dispatch_count;
    int error_count;

    /* State */
    fw_state_t state;

    /* Board dimensions (set during init) */
    int board_x;              /* X columns per board                     */
    int board_y;              /* Y rows per board                        */
    int num_layers;           /* physical spine layers                   */
    int model_layers_per_physical; /* model layers per physical layer    */
} firmware_t;

/* ── Dispatch Record ───────────────────────────────────────────────── */

typedef struct {
    int       layer;
    char      phase[16];      /* "dense", "moe", "kv_offload" */
    node_id_t target;
    int       expert_idx;     /* -1 for dense */
    int       flit_bytes;
    char      kv_action[8];   /* "store", "load", "evict", "" */
    cu_type_t cu_type;
} dispatch_record_t;

/* ── API ───────────────────────────────────────────────────────────── */

/* Initialize firmware */
void fw_init(firmware_t *fw);

/* Boot sequence — returns 0 on success, calls fn for each phase */
int  fw_boot(firmware_t *fw);

/* Phase-specific boot calls */
int  fw_boot_post_discovery(firmware_t *fw);
int  fw_boot_routing_table(firmware_t *fw);
int  fw_boot_weight_upload(firmware_t *fw);
int  fw_boot_moe_load(firmware_t *fw);

/* Inference dispatch — plans one token through all layers */
int  fw_plan_inference(firmware_t *fw, const uint8_t *token,
                       int token_len, dispatch_record_t *records,
                       int max_records, int *num_records);

/* Verification */
int  fw_verify_weight_upload(firmware_t *fw);
int  fw_verify_dispatch(firmware_t *fw, const dispatch_record_t *records,
                        int num_records);

/* KV cache operations */
void kv_cache_init(kv_cache_t *kv, int num_layers, int hidden_size);
bool kv_store(kv_layer_t *layer, int seq_pos, const uint8_t *entry, int entry_len);
bool kv_load(kv_layer_t *layer, int seq_pos, uint8_t *entry, int entry_len);
bool kv_needs_offload(kv_layer_t *layer, int threshold_pct);
int  kv_evict_oldest(kv_layer_t *layer, uint8_t *entry, int entry_len);

/* Compute unit helpers */
const char *cu_type_name(cu_type_t t);
int         cu_type_bytes(cu_type_t t);

#endif /* PNM_FW_H */
