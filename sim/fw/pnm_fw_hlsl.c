/**
 * pnm_fw_hlsl.c — HLSL-optimized firmware for the PNM router chip.
 *
 * Specialized dispatch for FP32-precision HLSL shader workloads.
 * HLSL programs use fp32_alu for per-element shader operations (dot,
 * lerp, clamp, rcp) and fp32_mac_array for MoE matrix multiply.
 *
 * Targets: ARM Cortex-M/R, RISC-V, or custom microcontroller.
 * No dynamic allocation — all buffers are statically sized.
 */

#include "pnm_fw_hlsl.h"
#include <string.h>

/* ── HLSL Shader Op Codes ─────────────────────────────────────────── */

enum {
    HLSL_OP_DENSE  = 0,  /* generic dense compute */
    HLSL_OP_DOT    = 1,  /* dot product */
    HLSL_OP_LERP   = 2,  /* linear interpolation */
    HLSL_OP_CLAMP  = 3,  /* clamp to range */
    HLSL_OP_RCP    = 4,  /* reciprocal */
    HLSL_OP_MUL    = 5,  /* element-wise multiply */
};

/* ── Firmware Init ─────────────────────────────────────────────────── */

void hlsl_fw_init(hlsl_fw_t *fw) {
    memset(fw, 0, sizeof(*fw));
    fw->base.state = FW_RESET;
    fw->fp32_nodes = 0;
    fw->total_flops = 0;
}

/* ── Inference Dispatch ────────────────────────────────────────────── */

/**
 * Plan the dispatch for one HLSL token through all transformer layers.
 *
 * HLSL programs target FP32 precision:
 *   1. Dense path: fp32_alu for shader-specific ops (dot/lerp/clamp)
 *   2. LayerNorm: fp32_alu for reduce + normalize
 *   3. MoE gating: fp32_fma for router.proj · hidden
 *   4. Expert dispatch: fp32_mac_array for matrix multiply
 *   5. Combine: weighted sum via fp32_alu
 */
int hlsl_fw_plan_inference(hlsl_fw_t *fw, const uint8_t *token,
                           int token_len, hlsl_dispatch_t *records,
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

        /* Dense path — FP32 ALU for shader ops */
        int attn_node = ml % nodes_per_layer;
        hlsl_dispatch_t *r = &records[idx];
        r->base.layer = ml;
        memcpy(r->base.phase, "dense", 6);
        r->base.target.L = (int8_t)pl;
        r->base.target.X = (uint8_t)(attn_node / by);
        r->base.target.Y = (uint8_t)(attn_node % by);
        r->base.expert_idx = -1;
        r->base.flit_bytes = 4 + token_len + 2;
        memcpy(r->base.kv_action, "store", 6);
        r->base.cu_type = HLSL_CU_DENSE;
        r->precision = 32;
        r->shader_op = HLSL_OP_DOT;
        r->group_size = 32;
        idx++;

        /* LayerNorm — FP32 ALU */
        if (idx < max_records) {
            hlsl_dispatch_t *ln = &records[idx];
            ln->base.layer = ml;
            memcpy(ln->base.phase, "norm", 5);
            ln->base.target.L = (int8_t)pl;
            ln->base.target.X = (uint8_t)(attn_node / by);
            ln->base.target.Y = (uint8_t)(attn_node % by);
            ln->base.expert_idx = -1;
            ln->base.flit_bytes = 4 + token_len + 2;
            memcpy(ln->base.kv_action, "", 1);
            ln->base.cu_type = HLSL_CU_NORM;
            ln->precision = 32;
            ln->shader_op = HLSL_OP_MUL;
            ln->group_size = 1;
            idx++;
        }

        /* MoE gating — FP32 FMA */
        for (int exp = 0; exp < PNM_MAX_TOPK && idx < max_records; exp++) {
            for (int e = 0; e < fw->base.moe_count; e++) {
                if (fw->base.moe_map[e].model_layer == ml &&
                    fw->base.moe_map[e].expert_idx == exp) {
                    hlsl_dispatch_t *er = &records[idx];
                    er->base.layer = ml;
                    memcpy(er->base.phase, "moe", 4);
                    er->base.target = fw->base.moe_map[e].target_node;
                    er->base.expert_idx = exp;
                    er->base.flit_bytes = 4 + token_len + 2;
                    memcpy(er->base.kv_action, "", 1);
                    er->base.cu_type = HLSL_CU_MOE;
                    er->precision = 32;
                    er->shader_op = HLSL_OP_MUL;
                    er->group_size = 16;
                    idx++;
                    break;
                }
            }
        }
    }

    *num_records = idx;
    fw->base.dispatch_count += idx;
    fw->total_flops = hlsl_fw_estimate_flops(records, idx);
    return 0;
}

/* ── Verification ──────────────────────────────────────────────────── */

int hlsl_fw_verify_dispatch(hlsl_fw_t *fw,
                            const hlsl_dispatch_t *records,
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
        if (cu != CU_FP32_FMA && cu != CU_FP32_ALU && cu != CU_FP32_ARRAY)
            return -2;
        if (records[i].precision != 32)
            return -3;
    }
    return 0;
}

/* ── FLOP Estimation ──────────────────────────────────────────────── */

int hlsl_fw_estimate_flops(const hlsl_dispatch_t *records, int num_records)
{
    int flops = 0;
    for (int i = 0; i < num_records; i++) {
        int flit_bytes = records[i].base.flit_bytes;
        int elems = (flit_bytes - 6) / HLSL_DTYPE_BYTES;
        if (elems < 0) elems = 0;

        switch (records[i].base.cu_type) {
        case CU_FP32_FMA:
            /* FMA: 2 FLOPs per element */
            flops += elems * 2;
            break;
        case CU_FP32_ARRAY:
            /* MAC array: 2 FLOPs * array_size per element */
            flops += elems * 2 * 16; /* assume 16-wide array */
            break;
        case CU_FP32_ALU:
            /* ALU: 1-3 FLOPs depending on shader op */
            switch (records[i].shader_op) {
            case HLSL_OP_DOT:
                flops += elems * 2; /* mul + add */
                break;
            case HLSL_OP_LERP:
                flops += elems * 3; /* sub + mul + add */
                break;
            default:
                flops += elems;
                break;
            }
            break;
        default:
            flops += elems;
            break;
        }
    }
    return flops;
}
