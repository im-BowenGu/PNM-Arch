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
        case CU_FP64_ALU:   return "fp64_alu";
        case CU_FP32_ARRAY: return "fp32_mac_array";
        case CU_INT8_ALU:   return "int8_alu";
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
    /* Flash attention defaults mirror Go DefaultFlashAttnConfig. */
    fw->flash_attn_enabled = 1;
    fw->flash_tile_size_kv = 256;
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

/* ── MoE gating: deterministic top-k expert selection ──────────────── */

/* Port of firmware.go selectTopExperts — an FNV-1a (64-bit) gate score per
 * (token, layer, expert) so routing is token/layer dependent and the full
 * expert population is reachable, matching the Go firmware bit-for-bit. */
static uint64_t fnv1a_64(const uint8_t *token, int token_len) {
    uint64_t h = 14695981039346656037ULL; /* FNV offset basis */
    for (int i = 0; i < token_len; i++) {
        h ^= token[i];
        h *= 1099511628211ULL; /* FNV prime */
    }
    return h;
}

/* select_topk fills topk_experts[] with the top-k entries from experts[]
 * (the global expert indices present for this layer), ranked by the gate
 * score for (token, layer), mirroring firmware.go selectTopExperts.  Returns
 * the count chosen. */
static int select_topk(const uint8_t *token, int token_len, int ml,
                       const int *experts, int n, int topk, int *topk_experts) {
    if (n <= 0) return 0;
    if (topk > n) topk = n;

    uint64_t h = fnv1a_64(token, token_len);
    h ^= (uint64_t)ml * 0x9E3779B97F4A7C15ULL;
    h *= 1099511628211ULL;

    uint64_t score[PNM_MAX_EXPERTS];
    int      exp_idx[PNM_MAX_EXPERTS];
    for (int e = 0; e < n; e++) {
        uint64_t sh = h ^ (uint64_t)experts[e] * 0x2545F4914F6CDD1DULL;
        sh ^= sh >> 33;
        sh *= 0xFF51AFD7ED558CCDULL;
        sh ^= sh >> 33;
        score[e]   = sh;
        exp_idx[e] = experts[e];
    }
    /* Insertion sort by (score desc, expert asc). */
    for (int i = 1; i < n; i++) {
        uint64_t sk = score[i];
        int      ek = exp_idx[i];
        int j = i - 1;
        while (j >= 0 && (score[j] < sk ||
                          (score[j] == sk && exp_idx[j] > ek))) {
            score[j+1]   = score[j];
            exp_idx[j+1] = exp_idx[j];
            j--;
        }
        score[j+1]   = sk;
        exp_idx[j+1] = ek;
    }
    for (int i = 0; i < topk; i++)
        topk_experts[i] = exp_idx[i];
    return topk;
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

    int idx = 0;
    int bx = fw->board_x > 0 ? fw->board_x : 4;
    int by = fw->board_y > 0 ? fw->board_y : 4;
    int nodes_per_layer = bx * by;
    int mpl = fw->model_layers_per_physical > 0 ? fw->model_layers_per_physical : 1;

    /* For each model layer dispatched to this physical chassis */
    int model_layers = mpl * fw->num_layers;
    /* Clamp to the actual model layer count when known, so we never plan a
     * phantom layer when mpl*num_layers exceeds NumHiddenLayers (mirrors the
     * Go firmware's `for ml < tc.NumHiddenLayers` loop boundary). */
    if (fw->num_hidden_layers > 0 && model_layers > fw->num_hidden_layers)
        model_layers = fw->num_hidden_layers;
    if (model_layers > PNM_MAX_MODEL_LAYERS)
        model_layers = PNM_MAX_MODEL_LAYERS;

    /* Track whether the plan is truncated: any record we cannot fit because
     * max_records is exhausted signals a caller-buffer sizing error rather
     * than a silent, partial dispatch plan. */
    int truncated = 0;
    for (int ml = 0; ml < model_layers; ml++) {
        int pl = ml / mpl;  /* physical layer index */
        if (pl >= fw->num_layers) break;

        /* Step 1: Dense path — attention node */
        int attn_node = ml % nodes_per_layer;
        if (idx >= max_records) { truncated = 1; break; }

        /* Flash attention: dispatch tiled QK^T softmax V — mirrors Go
         * firmware.go PlanInference's flash_attn branch. When enabled it
         * emits one "flash_attn" store record per KV tile plus a final
         * "flash_attn" load record; otherwise a single "dense" pair. */
        int tile_size_kv = fw->flash_tile_size_kv > 0 ? fw->flash_tile_size_kv : 256;
        int seq_pos = fw->seq_pos;
        /* Attention target node (persists past the branch for kv_offload). */
        node_id_t attn_target;
        attn_target.L = (int8_t)pl;
        attn_target.X = (uint8_t)(attn_node / by);
        attn_target.Y = (uint8_t)(attn_node % by);
        if (fw->flash_attn_enabled) {
            int num_kv_tiles = (seq_pos + tile_size_kv) / tile_size_kv;
            if (num_kv_tiles < 1) num_kv_tiles = 1;
            for (int kv_tile = 0; kv_tile < num_kv_tiles; kv_tile++) {
                if (idx >= max_records) { truncated = 1; break; }
                dispatch_record_t *r = &records[idx];
                r->layer = ml;
                memcpy(r->phase, "flash_attn", 11);
                r->target.L = (int8_t)pl;
                r->target.X = (uint8_t)(attn_node / by);
                r->target.Y = (uint8_t)(attn_node % by);
                r->expert_idx = -1;
                r->flit_bytes = 5 + token_len + 2; /* LAYER+MODULE+CTRL+LEN2+payload+CRC */
                memcpy(r->kv_action, "store", 6);
                r->cu_type = CU_BF16_ARRAY; /* systolic array */
                r->flash_tile_q = 0;
                r->flash_tile_kv = kv_tile;
                r->flash_num_tiles = num_kv_tiles;
                r->window_start = -1; /* full attention (no sliding window config) */
                r->window_end = -1;
                idx++;
            }
            if (truncated) break;
            /* KV cache load for tiled attention */
            if (idx >= max_records) { truncated = 1; break; }
            dispatch_record_t *lr = &records[idx];
            lr->layer = ml;
            memcpy(lr->phase, "flash_attn", 11);
            lr->target.L = (int8_t)pl;
            lr->target.X = (uint8_t)(attn_node / by);
            lr->target.Y = (uint8_t)(attn_node % by);
            lr->expert_idx = -1;
            lr->flit_bytes = 0;
            memcpy(lr->kv_action, "load", 5);
            lr->cu_type = CU_BF16_ARRAY;
            lr->flash_tile_q = 0;
            lr->flash_tile_kv = 0;
            lr->flash_num_tiles = num_kv_tiles;
            lr->window_start = -1;
            lr->window_end = -1;
            idx++;
        } else {
            dispatch_record_t *r = &records[idx];
            r->layer = ml;
            memcpy(r->phase, "dense", 6);
            r->target.L = (int8_t)pl;
            r->target.X = (uint8_t)(attn_node / by);
            r->target.Y = (uint8_t)(attn_node % by);
            r->expert_idx = -1;
            r->flit_bytes = 5 + token_len + 2; /* LAYER + MODULE + CTRL + LEN2 + payload + CRC */
            memcpy(r->kv_action, "store", 6);
            r->cu_type = CU_BF16_ARRAY; /* attention uses systolic array */
            idx++;

            /* Step 2a: KV cache load for attention — mirrors the Go PlanInference
             * KVAction "load" record (attn_kv_load) that follows every dense store.
             * Bookkeeping only (flit_bytes 0); it marks the read of prior K/V. */
            if (idx >= max_records) { truncated = 1; break; }
            dispatch_record_t *lr = &records[idx];
            lr->layer = ml;
            memcpy(lr->phase, "dense", 6);
            lr->target = r->target;
            lr->expert_idx = -1;
            lr->flit_bytes = 0;
            memcpy(lr->kv_action, "load", 5);
            lr->cu_type = CU_BF16_ARRAY;
            idx++;
        }
        if (truncated) break;

        /* Step 2b: KV cache check — offload if needed. Mirrors the Go
         * firmware's kv_offload/evict record (firmware.go PlanInference):
         * emit a bookkeeping record and drain the layer's over-threshold
         * banks. Threshold matches Go KVCacheConfig default (80%). */
        if (fw->kv.num_layers > pl && kv_needs_offload(&fw->kv.layers[pl], 80)) {
            if (idx >= max_records) { truncated = 1; break; }
            dispatch_record_t *kr = &records[idx];
            kr->layer = ml;
            memcpy(kr->phase, "kv_offload", 11);
            kr->target = attn_target;
            kr->expert_idx = -1;
            kr->flit_bytes = 0;
            memcpy(kr->kv_action, "evict", 6);
            kr->cu_type = CU_NONE;
            idx++;
            while (kv_needs_offload(&fw->kv.layers[pl], 80)) {
                int ev = fw->kv.layers[pl].evictions;
                kv_evict_oldest(&fw->kv.layers[pl], NULL, 0,
                                fw->eviction_mode, fw);
                if (fw->kv.layers[pl].evictions == ev)
                    break; /* no backing store / nothing to evict */
            }
        }
        if (truncated) break;

        /* Step 2c: MoE gating — dispatch to the top-k experts by gate score.
         * The expert population for a layer is everything in the map for that
         * model layer; the gate score (see select_topk) makes routing
         * token/layer dependent, so the whole population is reachable rather
         * than always experts 0..PNM_MAX_TOPK-1. */
        int  cand[PNM_MAX_EXPERTS], cand_n = 0;
        for (int m = 0; m < fw->moe_count && cand_n < PNM_MAX_EXPERTS; m++) {
            if (fw->moe_map[m].model_layer == ml)
                cand[cand_n++] = fw->moe_map[m].expert_idx; /* global expert idx */
        }
        int  sel[PNM_MAX_TOPK + 1];
        int  topk = fw->top_k_experts > 0 ? fw->top_k_experts : PNM_MAX_TOPK;
        if (topk > PNM_MAX_TOPK) topk = PNM_MAX_TOPK; /* cap at table size */
        int  nsel = select_topk(token, token_len, ml, cand, cand_n,
                                topk, sel);
        /* Map each selected expert index back to its node in the map. */
        for (int k = 0; k < nsel; k++) {
            if (idx >= max_records) { truncated = 1; break; }
            moe_entry_t *me = NULL;
            for (int m = 0; m < fw->moe_count; m++) {
                if (fw->moe_map[m].model_layer == ml &&
                    fw->moe_map[m].expert_idx == sel[k]) { me = &fw->moe_map[m]; break; }
            }
            if (!me) continue;
            dispatch_record_t *er = &records[idx];
            er->layer = ml;
            memcpy(er->phase, "moe", 4);
            er->target = me->target_node;
            er->expert_idx = sel[k];
            er->flit_bytes = 5 + token_len + 2; /* LAYER + MODULE + CTRL + LEN2 + payload + CRC */
            memcpy(er->kv_action, "", 1);
            er->cu_type = me->cu_type;
            idx++;
        }
        if (truncated) break;

        /* Advance the sequence position for this layer after the attention
         * (KV store) step, mirroring Go firmware.go SeqPositions[ml]++. */
        fw->seq_pos++;
    }

    *num_records = idx;
    fw->dispatch_count += idx;
    if (truncated)
        return -2; /* plan truncated: caller must enlarge max_records */
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
    /* Verify that every model layer has a dense dispatch as its first record
     * and that no layer is missing entirely. */
    int mpl = fw->model_layers_per_physical > 0 ? fw->model_layers_per_physical : 1;
    int model_layers = mpl * fw->num_layers;
    if (fw->num_hidden_layers > 0 && model_layers > fw->num_hidden_layers)
        model_layers = fw->num_hidden_layers;
    if (model_layers > PNM_MAX_MODEL_LAYERS)
        model_layers = PNM_MAX_MODEL_LAYERS;

    int last_layer = -1;
    /* Track every model layer that has had a dense dispatch, so a middle
     * layer omitted entirely is caught (the old code only checked that the
     * final layer index appeared, letting a gap pass). */
    unsigned char seen[PNM_MAX_MODEL_LAYERS] = {0};
    for (int i = 0; i < num_records; i++) {
        if (records[i].layer > last_layer) {
            if (strcmp(records[i].phase, "dense") != 0) {
                return -1; /* first dispatch per layer must be dense */
            }
            last_layer = records[i].layer;
        }
        if (records[i].layer >= 0 && records[i].layer < model_layers)
            seen[records[i].layer] = 1;
    }
    /* Every layer 0..model_layers-1 must have appeared with a dense record. */
    for (int l = 0; l < model_layers; l++) {
        if (!seen[l])
            return -1; /* a model layer was missing entirely */
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
            bank->entry_seq = (int *)0;
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
    if (seq_pos < 0)
        return false;
    int bank_idx = seq_pos % PNM_KV_CACHE_BANKS;
    kv_bank_t *bank = &layer->banks[bank_idx];

    if (bank->full || bank->entries == (uint8_t *)0)
        return false;

    int offset = bank->write_ptr * bank->entry_bytes;
    int copy_len = entry_len < bank->entry_bytes ? entry_len : bank->entry_bytes;
    memcpy(bank->entries + offset, entry, copy_len);

    if (bank->entry_seq)
        bank->entry_seq[bank->write_ptr] = seq_pos;

    bank->write_ptr = (bank->write_ptr + 1) % bank->depth;
    bank->occupancy++;
    bank->full = (bank->occupancy == bank->depth);
    bank->empty = false;
    return true;
}

bool kv_load(kv_layer_t *layer, int seq_pos, uint8_t *entry, int entry_len) {
    if (seq_pos < 0)
        return false;
    int bank_idx  = seq_pos % PNM_KV_CACHE_BANKS;
    int bank_pos  = seq_pos / PNM_KV_CACHE_BANKS;
    kv_bank_t *bank = &layer->banks[bank_idx];

    if (bank->empty || bank->entries == (uint8_t *)0)
        return false;

    /* KV_LOAD is a read — does NOT mutate occupancy/read_ptr. The entry is
     * addressed positionally (matching the Go model and RTL): bank-local
     * index is seq_pos / PNM_KV_CACHE_BANKS, stored in the circular buffer
     * at that index modulo depth. Live-window validation mirrors the Go
     * KVCacheBank.Load contract. */
    int idx = bank_pos % bank->depth;
    int dist = (idx - bank->read_ptr + bank->depth) % bank->depth;
    if (dist >= bank->occupancy)
        return false; /* evicted or never written */

    /* Per-slot staleness guard: a slot evicted and refilled with a NEWER seqPos
     * still lies inside the live window, so check the stored seqPos directly
     * (mirrors the Go KVCacheBank.Load EntrySeq contract). */
    if (bank->entry_seq && bank->entry_seq[idx] != seq_pos)
        return false; /* stale entry, evicted and overwritten */

    int offset = idx * bank->entry_bytes;
    int copy_len = entry_len < bank->entry_bytes ? entry_len : bank->entry_bytes;
    memcpy(entry, bank->entries + offset, copy_len);
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

int kv_evict_oldest(kv_layer_t *layer, uint8_t *entry, int entry_len,
                    kv_eviction_mode_t mode, firmware_t *fw) {
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

    /* Route the evicted entry based on the configured mode */
    switch (mode) {
    case KV_EVICT_DMA_BMC:
        /* In production, this sends a DMA flit over the spine fabric to the
           host BMC.  The BMC's DRAM controller writes the entry into its
           local buffer.  Latency: ~500ns round-trip. */
        break;

    case KV_EVICT_NVME:
        if (fw && fw->nvme_kv_lba < fw->nvme_kv_lba_end) {
            /* In production, this issues CMD_WRITE to the NVMe controller
               via the PCIe bridge.  The entry is written to the circular
               overflow region starting at nvme_kv_lba. */
            fw->nvme_kv_lba += (copy_len + 511) / 512; /* round up to blocks */
        }
        break;

    default: /* KV_EVICT_NONE */
        /* Discard — no persistence */
        break;
    }

    return copy_len;
}
