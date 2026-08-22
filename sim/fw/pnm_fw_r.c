/**
 * pnm_fw_r.c — R-optimized firmware for the PNM router chip.
 *
 * Specialized dispatch for FP64-precision R workloads.
 * R programs are vectorized (no recursion), using fp64_fma for
 * all matrix and element-wise operations, fp64_alu for normalization.
 *
 * Targets: ARM Cortex-M/R, RISC-V, or custom microcontroller.
 * No dynamic allocation — all buffers are statically sized.
 */

#include "pnm_fw_r.h"
#include <string.h>

/* ── Firmware Init ─────────────────────────────────────────────────── */

void r_fw_init(r_fw_t *fw) {
    memset(fw, 0, sizeof(*fw));
    fw->base.state = FW_RESET;
    fw->fp64_nodes = 0;
    fw->total_flops = 0;
}

/* ── Inference Dispatch ────────────────────────────────────────────── */

/**
 * Plan the dispatch for one R token through all transformer layers.
 *
 * R programs target FP64 precision with vectorized loops:
 *   1. Dense path: fp64_fma for Q/K/V/O projections (vectorized)
 *   2. LayerNorm: fp64_alu for reduce + normalize
 *   3. MoE gating: fp64_fma for router.proj · hidden
 *   4. Expert dispatch: fp64_fma for weight-stationary matmul
 *   5. Combine: weighted sum of expert outputs via fp64_fma
 */
int r_fw_plan_inference(r_fw_t *fw, const uint8_t *token,
                        int token_len, r_dispatch_t *records,
                        int max_records, int *num_records)
{
    if (fw->base.state != FW_READY)
        return -1;

    (void)token;
    int idx = 0;
    int bx = fw->base.board_x > 0 ? fw->base.board_x : 4;
    int by = fw->base.board_y > 0 ? fw->base.board_y : 4;
    int nodes_per_layer = bx * by;
    int mpl = fw->base.model_layers_per_physical > 0
              ? fw->base.model_layers_per_physical : 1;

    for (int ml = 0; ml < PNM_MAX_MODEL_LAYERS && idx < max_records; ml++) {
        int pl = ml / mpl;
        if (pl >= fw->base.num_layers) break;

        /* Dense path — FP64 attention (vectorized) */
        int attn_node = ml % nodes_per_layer;
        r_dispatch_t *r = &records[idx];
        r->base.layer = ml;
        memcpy(r->base.phase, "dense", 6);
        r->base.target.L = (int8_t)pl;
        r->base.target.X = (uint8_t)(attn_node / by);
        r->base.target.Y = (uint8_t)(attn_node % by);
        r->base.expert_idx = -1;
        r->base.flit_bytes = 4 + token_len + 2;
        memcpy(r->base.kv_action, "store", 6);
        r->base.cu_type = R_CU_DENSE;
        r->precision = 64;
        r->vec_width = 4;  /* R vectorized: 4-wide FP64 */
        r->is_vectorized = 1;
        idx++;

        /* LayerNorm — FP64 ALU (reduce + normalize) */
        if (idx < max_records) {
            r_dispatch_t *ln = &records[idx];
            ln->base.layer = ml;
            memcpy(ln->base.phase, "norm", 5);
            ln->base.target.L = (int8_t)pl;
            ln->base.target.X = (uint8_t)(attn_node / by);
            ln->base.target.Y = (uint8_t)(attn_node % by);
            ln->base.expert_idx = -1;
            ln->base.flit_bytes = 4 + token_len + 2;
            memcpy(ln->base.kv_action, "", 1);
            ln->base.cu_type = R_CU_NORM;
            ln->precision = 64;
            ln->vec_width = 1;  /* normalization is scalar */
            ln->is_vectorized = 0;
            idx++;
        }

        /* MoE gating — FP64 FMA */
        for (int exp = 0; exp < PNM_MAX_TOPK && idx < max_records; exp++) {
            for (int e = 0; e < fw->base.moe_count; e++) {
                if (fw->base.moe_map[e].model_layer == ml &&
                    fw->base.moe_map[e].expert_idx == exp) {
                    r_dispatch_t *er = &records[idx];
                    er->base.layer = ml;
                    memcpy(er->base.phase, "moe", 4);
                    er->base.target = fw->base.moe_map[e].target_node;
                    er->base.expert_idx = exp;
                    er->base.flit_bytes = 4 + token_len + 2;
                    memcpy(er->base.kv_action, "", 1);
                    er->base.cu_type = R_CU_MOE;
                    er->precision = 64;
                    er->vec_width = 4;
                    er->is_vectorized = 1;
                    idx++;
                    break;
                }
            }
        }
    }

    *num_records = idx;
    fw->base.dispatch_count += idx;
    fw->total_flops = r_fw_estimate_flops(records, idx);
    return 0;
}

/* ── Verification ──────────────────────────────────────────────────── */

int r_fw_verify_dispatch(r_fw_t *fw, const r_dispatch_t *records,
                         int num_records)
{
    (void)fw;
    int last_layer = -1;
    for (int i = 0; i < num_records; i++) {
        if (records[i].base.layer != last_layer) {
            if (strcmp(records[i].base.phase, "dense") != 0)
                return -1;
            last_layer = records[i].base.layer;
        }
        cu_type_t cu = records[i].base.cu_type;
        if (cu != CU_FP64_FMA && cu != CU_FP64_ALU)
            return -2;
        if (records[i].precision != 64)
            return -3;
    }
    return 0;
}

/* ── FLOP Estimation ──────────────────────────────────────────────── */

int r_fw_estimate_flops(const r_dispatch_t *records, int num_records)
{
    int flops = 0;
    for (int i = 0; i < num_records; i++) {
        int flit_bytes = records[i].base.flit_bytes;
        int elems = (flit_bytes - 6) / R_DTYPE_BYTES;
        if (elems < 0) elems = 0;

        /* Vectorized operations: multiply by vector width */
        int effective = elems * records[i].vec_width;

        switch (records[i].base.cu_type) {
        case CU_FP64_FMA:
            flops += effective * 2; /* FMA: mul + add */
            break;
        case CU_FP64_ALU:
            flops += effective;
            break;
        default:
            flops += effective;
            break;
        }
    }
    return flops;
}
