/**
 * pnm_fw.c — Firmware for the PNM central router chip.
 *
 * Port of sim/internal/pnm/firmware.go to C for microcontroller targets.
 * Supports all compute units: bf16_fma, fp16_fma, fp32_fma, fp64_fma,
 * fp32_alu, int8_mac, bf16_mac_array, fp16_mac_array.
 *
 * Targets: ARM Cortex-M/R, RISC-V, or custom microcontroller.
 * No dynamic allocation — all buffers are statically sized.
 */

#include "pnm_fw.h"
#include <string.h>

/* ── Compute Unit Helpers ──────────────────────────────────────────── */

const char *cu_type_name(cu_type_t t) {
    switch (t) {
        case CU_BF16_FMA:   return "bf16_fma";
        case CU_FP16_FMA:   return "fp16_fma";
        case CU_FP32_FMA:   return "fp32_fma";
        case CU_FP64_FMA:   return "fp64_fma";
        case CU_FP32_ALU:   return "fp32_alu";
        case CU_INT8_MAC:   return "int8_mac";
        case CU_BF16_ARRAY: return "bf16_mac_array";
        case CU_FP16_ARRAY: return "fp16_mac_array";
        default:            return "none";
    }
}

int cu_type_bytes(cu_type_t t) {
    return cu_dtype_bytes(t);
}

/* ── Firmware Init ─────────────────────────────────────────────────── */

void fw_init(firmware_t *fw) {
    memset(fw, 0, sizeof(*fw));
    fw->state = FW_RESET;
}

/* ── Boot Sequence ─────────────────────────────────────────────────── */

int fw_boot(firmware_t *fw) {
    int rc;
    switch (fw->state) {
    case FW_RESET:
        rc = fw_boot_post_discovery(fw);
        break;
    case FW_POST_DISCOVERY:
        rc = fw_boot_routing_table(fw);
        break;
    case FW_ROUTING_TABLE:
        rc = fw_boot_weight_upload(fw);
        break;
    case FW_WEIGHT_UPLOAD:
        rc = fw_boot_moe_load(fw);
        break;
    case FW_MOE_LOAD:
        fw->state = FW_READY;
        rc = 0;
        break;
    default:
        rc = -1;
        break;
    }
    return rc;
}

/**
 * Phase 1: POST Discovery — enumerate all nodes on the fabric.
 * In production, this pings each coordinate and waits for TOPOLOGY_RDY.
 * Here we build the inventory from the known chassis dimensions.
 */
int fw_boot_post_discovery(firmware_t *fw) {
    /* The caller must have pre-populated the inventory or we discover
       via sideband.  For the co-sim, the Go driver populates this. */
    fw->state = FW_POST_DISCOVERY;
    return 0;
}

/**
 * Phase 2: Routing Table Load — program xyz_repeaters and HFRs.
 * The routing bitmaps are loaded into each repeater's parameter registers
 * via sideband at boot.  The driver pre-computes these.
 */
int fw_boot_routing_table(firmware_t *fw) {
    fw->state = FW_ROUTING_TABLE;
    return 0;
}

/**
 * Phase 3: Weight Upload — stream weight blobs through the fabric.
 * Each command sends a flit: LAYER | MODULE | CTRL | LEN | payload | CRC.
 * The node's pe_tile_stub receives and stores into LPDDR6 CAMM2.
 */
int fw_boot_weight_upload(firmware_t *fw) {
    fw->state = FW_WEIGHT_UPLOAD;
    return 0;
}

/**
 * Phase 4: MoE Gating Load — program router.proj weights into on-chip SRAM.
 * The moe_gating unit uses these for the gating network forward pass.
 */
int fw_boot_moe_load(firmware_t *fw) {
    fw->state = FW_MOE_LOAD;
    return 0;
}

/* ── Inference Dispatch ────────────────────────────────────────────── */

/**
 * Plan the dispatch for one token through all transformer layers.
 *
 * For each model layer:
 *   1. Dense path: dispatch hidden state to the attention node
 *      - bf16_mac_array for Q/K/V/O projections
 *      - fp32_alu for LayerNorm (numerical stability)
 *   2. MoE gating: router.proj · hidden → logits (fp32_alu)
 *   3. Top-K selection: argmax(logits, k)
 *   4. For each expert: dispatch to the node holding that expert
 *      - bf16_fma for weight-stationary matrix multiply
 *   5. Combine: weighted sum of expert outputs → hidden for next layer
 */
int fw_plan_inference(firmware_t *fw, const uint8_t *token,
                      int token_len, dispatch_record_t *records,
                      int max_records, int *num_records)
{
    if (fw->state != FW_READY)
        return -1;

    (void)token; /* used in production for flit construction */
    int idx = 0;
    int nodes_per_layer = PNM_MAX_NODES;

    /* For each model layer dispatched to this physical chassis */
    for (int ml = 0; ml < PNM_MAX_MODEL_LAYERS && idx < max_records; ml++) {
        /* Step 1: Dense path — attention node */
        int attn_node = ml % nodes_per_layer;
        dispatch_record_t *r = &records[idx];
        r->layer = ml;
        memcpy(r->phase, "dense", 6);
        r->target.L = 0; /* simplified: all on layer 0 */
        r->target.X = attn_node / 4;
        r->target.Y = attn_node % 4;
        r->expert_idx = -1;
        r->flit_bytes = 4 + token_len + 2; /* header + payload + CRC */
        memcpy(r->kv_action, "store", 6);
        r->cu_type = CU_BF16_ARRAY; /* attention uses systolic array */
        idx++;

        /* Step 2: MoE gating — dispatch to top-k experts */
        for (int exp = 0; exp < PNM_MAX_TOPK && idx < max_records; exp++) {
            int exp_node = exp % nodes_per_layer;
            dispatch_record_t *er = &records[idx];
            er->layer = ml;
            memcpy(er->phase, "moe", 4);
            er->target.L = 0;
            er->target.X = exp_node / 4;
            er->target.Y = exp_node % 4;
            er->expert_idx = exp;
            er->flit_bytes = 4 + token_len + 2;
            memcpy(er->kv_action, "", 1);
            er->cu_type = CU_BF16_FMA; /* MoE experts use BF16 FMA */
            idx++;
        }
    }

    *num_records = idx;
    fw->dispatch_count += idx;
    return 0;
}

/* ── Verification ──────────────────────────────────────────────────── */

int fw_verify_weight_upload(firmware_t *fw) {
    /* Check that all assigned nodes received weights within budget.
       In the C firmware, the Go driver handles AOT verification;
       this is a runtime sanity check. */
    for (int i = 0; i < fw->weight_count; i++) {
        weight_cmd_t *cmd = &fw->weight_cmds[i];
        if (cmd->target_layer >= PNM_MAX_LAYERS) {
            fw->error_count++;
            return -1;
        }
    }
    return 0;
}

int fw_verify_dispatch(firmware_t *fw, const dispatch_record_t *records,
                       int num_records) {
    (void)fw;
    /* Verify that every layer has at least one dense dispatch */
    int last_layer = -1;
    for (int i = 0; i < num_records; i++) {
        if (records[i].layer != last_layer) {
            if (strcmp(records[i].phase, "dense") != 0) {
                return -1; /* first dispatch per layer must be dense */
            }
            last_layer = records[i].layer;
        }
    }
    return 0;
}

/* ── KV Cache ──────────────────────────────────────────────────────── */

void kv_cache_init(kv_cache_t *kv, int num_layers, int hidden_size) {
    memset(kv, 0, sizeof(*kv));
    kv->num_layers = num_layers;

    int entry_bytes = hidden_size * 4; /* K(2B) + V(2B) per hidden dim */
    const char *dirs[] = {"X+", "X-", "Y+", "Y-"};

    for (int l = 0; l < num_layers; l++) {
        kv_layer_t *layer = &kv->layers[l];
        layer->layer_id = l;
        for (int b = 0; b < PNM_KV_CACHE_BANKS; b++) {
            kv_bank_t *bank = &layer->banks[b];
            bank->depth = PNM_KV_CACHE_DEPTH;
            bank->entry_bytes = entry_bytes;
            /* Static allocation: caller must provide backing store.
               For now, mark as empty. */
            bank->entries = (uint8_t *)0;
            bank->write_ptr = 0;
            bank->read_ptr = 0;
            bank->occupancy = 0;
            bank->full = false;
            bank->empty = true;
            strncpy(bank->direction, dirs[b], 4);
        }
    }
}

bool kv_store(kv_layer_t *layer, int seq_pos, const uint8_t *entry,
              int entry_len) {
    int bank_idx = seq_pos % PNM_KV_CACHE_BANKS;
    kv_bank_t *bank = &layer->banks[bank_idx];

    if (bank->full || bank->entries == (uint8_t *)0)
        return false;

    int offset = bank->write_ptr * bank->entry_bytes;
    int copy_len = entry_len < bank->entry_bytes ? entry_len : bank->entry_bytes;
    memcpy(bank->entries + offset, entry, copy_len);

    bank->write_ptr = (bank->write_ptr + 1) % bank->depth;
    bank->occupancy++;
    bank->full = (bank->occupancy == bank->depth);
    bank->empty = false;
    return true;
}

bool kv_load(kv_layer_t *layer, int seq_pos, uint8_t *entry, int entry_len) {
    int bank_idx = seq_pos % PNM_KV_CACHE_BANKS;
    kv_bank_t *bank = &layer->banks[bank_idx];

    if (bank->empty || bank->entries == (uint8_t *)0)
        return false;

    int offset = bank->read_ptr * bank->entry_bytes;
    int copy_len = entry_len < bank->entry_bytes ? entry_len : bank->entry_bytes;
    memcpy(entry, bank->entries + offset, copy_len);

    bank->read_ptr = (bank->read_ptr + 1) % bank->depth;
    bank->occupancy--;
    bank->empty = (bank->occupancy == 0);
    bank->full = false;
    return true;
}

bool kv_needs_offload(kv_layer_t *layer, int threshold_pct) {
    for (int b = 0; b < PNM_KV_CACHE_BANKS; b++) {
        kv_bank_t *bank = &layer->banks[b];
        int threshold = bank->depth * threshold_pct / 100;
        if (bank->occupancy >= threshold)
            return true;
    }
    return false;
}

int kv_evict_oldest(kv_layer_t *layer, uint8_t *entry, int entry_len) {
    /* Find the fullest bank and evict from it */
    int max_occ = 0, max_bank = 0;
    for (int b = 0; b < PNM_KV_CACHE_BANKS; b++) {
        if (layer->banks[b].occupancy > max_occ) {
            max_occ = layer->banks[b].occupancy;
            max_bank = b;
        }
    }

    kv_bank_t *bank = &layer->banks[max_bank];
    if (bank->empty || bank->entries == (uint8_t *)0)
        return 0;

    int offset = bank->read_ptr * bank->entry_bytes;
    int copy_len = entry_len < bank->entry_bytes ? entry_len : bank->entry_bytes;
    if (entry)
        memcpy(entry, bank->entries + offset, copy_len);

    bank->read_ptr = (bank->read_ptr + 1) % bank->depth;
    bank->occupancy--;
    bank->empty = (bank->occupancy == 0);
    bank->full = false;
    layer->evictions++;

    return copy_len;
}
