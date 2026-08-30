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

/* ── MoE gate helpers (port of pnm_fw.c select_topk) ──────────────── */
static uint64_t hlsl_fnv1a_64(const uint8_t *token, int token_len) {
    uint64_t h = 14695981039346656037ULL; /* FNV offset basis */
    for (int i = 0; i < token_len; i++) {
        h ^= token[i];
        h *= 1099511628211ULL; /* FNV prime */
    }
    return h;
}

/* Fill topk_experts[] with the top-k entries of experts[] ranked by a
 * token/layer-dependent gate score, mirroring firmware.go selectTopExperts
 * and pnm_fw.c select_topk. Returns the count chosen. */
static int hlsl_select_topk(const uint8_t *token, int token_len, int ml,
                            const int *experts, int n, int topk, int *topk_experts) {
    if (n <= 0) return 0;
    if (topk > n) topk = n;
    uint64_t h = hlsl_fnv1a_64(token, token_len);
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

    /* Clamp planned model layers to the actual layer count when known,
     * mirroring the main twin (pnm_fw.c). */
    int model_layers = mpl * fw->base.num_layers;
    if (fw->base.num_hidden_layers > 0 && model_layers > fw->base.num_hidden_layers)
        model_layers = fw->base.num_hidden_layers;
    if (model_layers > PNM_MAX_MODEL_LAYERS) model_layers = PNM_MAX_MODEL_LAYERS;
    if (model_layers < 0) model_layers = 0;

    for (int ml = 0; ml < model_layers && idx < max_records; ml++) {
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
        r->base.flit_bytes = 5 + token_len + 2;
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
            ln->base.flit_bytes = 5 + token_len + 2;
            memcpy(ln->base.kv_action, "", 1);
            ln->base.cu_type = HLSL_CU_NORM;
            ln->precision = 32;
            ln->shader_op = HLSL_OP_MUL;
            ln->group_size = 1;
            idx++;
        }

        /* MoE gating — FP32 FMA. Route to the top-k experts by a token/layer
         * gate score over the layer's full expert population, mirroring
         * pnm_fw.c / firmware.go selectTopExperts. */
        int cand[PNM_MAX_EXPERTS], cand_n = 0;
        for (int m = 0; m < fw->base.moe_count && cand_n < PNM_MAX_EXPERTS; m++)
            if (fw->base.moe_map[m].model_layer == ml)
                cand[cand_n++] = fw->base.moe_map[m].expert_idx;
        int sel[PNM_MAX_TOPK + 1];
        int topk = fw->base.top_k_experts > 0 ? fw->base.top_k_experts : PNM_MAX_TOPK;
        if (topk > PNM_MAX_TOPK) topk = PNM_MAX_TOPK;
        int nsel = hlsl_select_topk(token, token_len, ml, cand, cand_n, topk, sel);
        for (int k = 0; k < nsel && idx < max_records; k++) {
            int eidx = sel[k];
            moe_entry_t *me = NULL;
            for (int m = 0; m < fw->base.moe_count; m++) {
                if (fw->base.moe_map[m].model_layer == ml &&
                    fw->base.moe_map[m].expert_idx == eidx) { me = &fw->base.moe_map[m]; break; }
            }
            if (!me) continue;
            hlsl_dispatch_t *er = &records[idx];
            er->base.layer = ml;
            memcpy(er->base.phase, "moe", 4);
            er->base.target = me->target_node;
            er->base.expert_idx = eidx;
            er->base.flit_bytes = 5 + token_len + 2;
            memcpy(er->base.kv_action, "", 1);
            er->base.cu_type = HLSL_CU_MOE;
            er->precision = 32;
            er->shader_op = HLSL_OP_MUL;
            er->group_size = 16;
            idx++;
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
        int elems = (flit_bytes - 7) / HLSL_DTYPE_BYTES;
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
