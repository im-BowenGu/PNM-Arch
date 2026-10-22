/**
 * pnm_fw.c — the host-side dispatch firmware for the PNM chassis.
 *
 * Port of sim/internal/pnm/firmware.go to C.  The router bridge has no
 * processor of its own, so this firmware runs on the *host*: a Raspberry Pi
 * over the SPI adapter, or any third-party microcontroller, driving the
 * bridge's register window.  It performs the five boot phases (POST
 * discovery, routing tables, weight upload, MoE gating load) and then
 * executes the dispatch plan the host compiled (see plan.h).
 *
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
 * Phase 2: Routing Table Load — program the xyz_repeaters and HFRs.
 *
 * The routing bitmaps are loaded into each repeater's parameter registers
 * via sideband at boot.  The bitmap is the 11-bit routing comparator every
 * repeater and node carries: [10:7] the 1-based layer, [6] the axis
 * (0 = X, 1 = Y), [5] the direction, [4:0] the hop distance.  It is what
 * makes the routing source-routed and deterministic: a packet matches a gate
 * by comparing this bitmap against the header, never by looking a table up
 * at run time.
 *
 * The Go twin (sim/internal/pnm/firmware.go bootRoutingTable) emits one
 * command per node carrying the same bitmap; this fills the firmware's
 * routing table with the same values so the two agree.
 */
int fw_boot_routing_table(firmware_t *fw) {
    int bx = fw->board_x > 0 ? fw->board_x : 4;
    int by = fw->board_y > 0 ? fw->board_y : 4;
    int n = 0;

    for (int l = 0; l < fw->num_layers && n < PNM_ROUTING_TABLE_SIZE; l++) {
        for (int x = 0; x < bx && n < PNM_ROUTING_TABLE_SIZE; x++) {
            for (int y = 0; y < by && n < PNM_ROUTING_TABLE_SIZE; y++) {
                routing_entry_t *r = &fw->routes[n];
                r->node.L = (int8_t)l;
                r->node.X = (uint8_t)x;
                r->node.Y = (uint8_t)y;
                r->bitmap = (uint16_t)(((uint16_t)(l + 1) << 7) |
                                       (1u << 6) | ((uint16_t)y & 0x1Fu));
                r->cu_type = CU_BF16_FMA;
                n++;
            }
        }
    }
    fw->routing_count = n;
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
 * Phase 4: MoE Gating Load — program the gating engines' router weights.
 *
 * The gating ASIC is a per-node device: it holds one layer's router weights
 * and produces the expert decision for every token that lands on its node
 * (Section 2.17.1).  The router weights themselves were already uploaded by
 * the weight-upload phase -- they are ordinary model tensors, the router
 * projection -- so this phase tells each node's gating engine which layer it
 * holds and how many words its router is, and the node programs its own
 * gating ASIC from local memory.  In mode A the node's own management node
 * acts on it; in mode B it arrives over the fabric.
 *
 * The Go twin (sim/internal/pnm/firmware.go bootMoELoad) emits one command
 * per (node, layer) that hosts a gating engine; this counts the same set.
 */
int fw_boot_moe_load(firmware_t *fw) {
    int n = 0;
    int layers_seen[PNM_MAX_MODEL_LAYERS];
    int nl = 0;

    for (int i = 0; i < fw->moe_count; i++) {
        int ml = fw->moe_map[i].model_layer;
        int known = 0;
        for (int k = 0; k < nl; k++)
            if (layers_seen[k] == ml) known = 1;
        if (!known && nl < PNM_MAX_MODEL_LAYERS) {
            layers_seen[nl++] = ml;
            n++;
        }
    }
    fw->gating_program_count = n;
    fw->state = FW_MOE_LOAD;
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
    /* Validate a received plan (see plan.h): every model layer must have a
     * dense (or flash_attn) dispatch as its first record and no layer may be
     * missing entirely.  The expected layer count comes from the plan header
     * (fw_plan_apply), falling back to mpl*num_layers when unknown. */
    int mpl = fw->model_layers_per_physical > 0 ? fw->model_layers_per_physical : 1;
    int model_layers = fw->num_hidden_layers > 0
        ? fw->num_hidden_layers : (mpl * fw->num_layers);
    if (model_layers > PNM_MAX_MODEL_LAYERS)
        model_layers = PNM_MAX_MODEL_LAYERS;

    int last_layer = -1;
    /* Track every model layer that has had a dense dispatch, so a middle
     * layer omitted entirely is caught (the old code only checked that the
     * final layer index appeared, letting a gap pass). */
    unsigned char seen[PNM_MAX_MODEL_LAYERS] = {0};
    for (int i = 0; i < num_records; i++) {
        if (records[i].layer > last_layer) {
            /* First dispatch per layer: dense, or flash_attn when flash
             * attention is enabled (the planner then emits flash_attn store
             * + load records as the layer's leading records, not "dense"). */
            if (strcmp(records[i].phase, "dense") != 0 &&
                strcmp(records[i].phase, "flash_attn") != 0) {
                return -1; /* first dispatch per layer must be dense or flash_attn */
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
    (void)hidden_size; /* frame size is RTL-fixed (PNM_KV_ENTRY_BYTES), not model-derived */

    /* Each KV entry occupies the RTL kv_cache_bank fixed frame
       (ENTRY_BYTES=512), mirroring the Go twin's DefaultKVCacheConfig and
       the silicon accounting. A model-derived hidden_size*4 frame would
       diverge from the hardware frame and overstate paper capacity. */
    int entry_bytes = PNM_KV_ENTRY_BYTES;
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
    /* Zero-pad the remainder of the slot to the full frame, mirroring the
       Go KVCacheBank.Store (make([]byte, EntryBytes) + copy). Without this,
       a short entry leaves stale tail bytes that differ from the Go twin's
       load result. */
    if (copy_len < bank->entry_bytes)
        memset(bank->entries + offset + copy_len, 0,
               bank->entry_bytes - copy_len);

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
