/**
 * src_fw.c — the shared source-language dispatch firmware.
 *
 * R, Haskell and HLSL all compile to the same straight-line IR and are
 * dispatched over the same fabric.  Only the compute-unit profile and a few
 * per-language record annotations differ, so the planner lives here once and
 * the three public ports (pnm_fw_r.c, pnm_fw_haskell.c, pnm_fw_hlsl.c) forward
 * to it.
 *
 * The three ports were previously three copies of this planner.  They had
 * already drifted from the canonical firmware (fw/pnm_fw.c): they carried
 * none of its flash-attention tiling, sliding-window bounds, per-layer
 * sequence positions, or grouped-query expansion.  One implementation cannot
 * drift from itself.
 */

#include "src_fw.h"
#include <string.h>

/* ── The language profiles ──────────────────────────────────────────── */

#define R_CU_DENSE       CU_FP64_FMA
#define R_CU_MOE         CU_FP64_FMA
#define R_CU_NORM        CU_FP64_ALU
#define R_CU_GATE        CU_FP64_FMA
#define R_DTYPE          "FP64"
#define R_DTYPE_BYTES    8

#define HASKELL_CU_DENSE    CU_FP64_FMA
#define HASKELL_CU_MOE      CU_FP64_FMA
#define HASKELL_CU_NORM     CU_FP64_ALU
#define HASKELL_CU_GATE     CU_FP64_FMA
#define HASKELL_DTYPE       "FP64"
#define HASKELL_DTYPE_BYTES 8

#define HLSL_CU_DENSE    CU_FP32_ALU
#define HLSL_CU_MOE      CU_FP32_ARRAY
#define HLSL_CU_NORM     CU_FP32_ALU
#define HLSL_CU_GATE     CU_FP32_FMA
#define HLSL_DTYPE       "FP32"
#define HLSL_DTYPE_BYTES 4

/* The HLSL operator kinds (the values the HLSL port has always used). */
#define SRC_OP_DENSE 0
#define SRC_OP_DOT   1
#define SRC_OP_LERP  2
#define SRC_OP_CLAMP 3
#define SRC_OP_RCP   4
#define SRC_OP_MUL   5

static const src_profile_t g_profiles[3] = {
    { "R",       R_CU_DENSE,       R_CU_MOE,       R_CU_NORM,       R_CU_GATE,
      64, R_DTYPE,       R_DTYPE_BYTES       },
    { "Haskell", HASKELL_CU_DENSE, HASKELL_CU_MOE, HASKELL_CU_NORM, HASKELL_CU_GATE,
      64, HASKELL_DTYPE, HASKELL_DTYPE_BYTES },
    { "HLSL",    HLSL_CU_DENSE,    HLSL_CU_MOE,    HLSL_CU_NORM,    HLSL_CU_GATE,
      32, HLSL_DTYPE,    HLSL_DTYPE_BYTES    }
};

const src_profile_t *src_profile(src_lang_t lang)
{
    if (lang < 0 || lang > SRC_LANG_HLSL) lang = SRC_LANG_R;
    return &g_profiles[lang];
}

/* ── The token-seeded gating hash (identical in all three ports) ───── */

/* FNV-1a, 64-bit -- the same seed the Go twin (sim/internal/pnm/firmware.go
 * selectTopExperts) uses, so the two agree on the expert set. */
static uint64_t src_fnv1a_64(const uint8_t *token, int token_len)
{
    uint64_t h = 14695981039346656037ULL;
    for (int i = 0; i < token_len; i++) {
        h ^= (uint64_t)token[i];
        h *= 1099511628211ULL;
    }
    return h;
}

/* Select the top-k experts for one (token, model layer), scored by the same
 * hash the Go twin (sim/internal/pnm/firmware.go selectTopExperts) uses, so
 * the two agree on the expert set.  This is the software stand-in for the
 * learned router; the gating ASIC's own top-k is the real datapath. */
static int src_select_topk(const uint8_t *token, int token_len, int ml,
                           const int *experts, int n, int topk,
                           int *topk_experts)
{
    if (n <= 0) return 0;
    if (topk > n) topk = n;

    uint64_t h = src_fnv1a_64(token, token_len);
    h ^= (uint64_t)ml * 0x9E3779B97F4A7C15ULL;
    h *= 1099511628211ULL;

    uint64_t score[PNM_MAX_EXPERTS];
    int      exp_idx[PNM_MAX_EXPERTS];
    for (int e = 0; e < n && e < PNM_MAX_EXPERTS; e++) {
        uint64_t sh = h ^ (uint64_t)experts[e] * 0x2545F4914F6CDD1DULL;
        sh ^= sh >> 33;
        sh *= 0xFF51AFD7ED558CCDULL;
        sh ^= sh >> 33;
        score[e]   = sh;
        exp_idx[e] = experts[e];
    }

    /* Insertion sort, descending by score, ascending by expert index on a
     * tie -- the same order the Go twin produces. */
    for (int i = 1; i < n && i < PNM_MAX_EXPERTS; i++) {
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

/* ── The language annotations on a dispatch record ──────────────────── */

/* The per-language annotation on a record.  The three ports each had their
 * own; these are the values they used.  `kind` is 0 = dense, 1 = norm,
 * 2 = MoE. */
static void src_annotate(src_dispatch_t *r, src_lang_t lang, int kind)
{
    const src_profile_t *p = src_profile(lang);
    r->precision     = p->precision;
    r->vec_width     = 1;
    r->is_vectorized = 0;
    r->num_regs      = 0;
    r->depth         = 0;
    r->shader_op     = SRC_OP_MUL;
    r->group_size    = 0;

    switch (lang) {
    case SRC_LANG_R:
        /* R programs are vectorized: a 4-wide FP64 loop for the dense and
         * MoE paths, scalar for the normalization. */
        r->vec_width     = (kind == 1) ? 1 : 4;
        r->is_vectorized = (kind == 1) ? 0 : 1;
        break;
    case SRC_LANG_HASKELL:
        r->num_regs = (kind == 0) ? 8 : (kind == 1 ? 4 : 6);
        r->depth   = (kind == 0) ? 3 : (kind == 1 ? 2 : 4);
        break;
    case SRC_LANG_HLSL:
        r->shader_op  = (kind == 0) ? SRC_OP_DOT : SRC_OP_MUL;
        r->group_size = (kind == 0) ? 32 : (kind == 1 ? 1 : 16);
        break;
    default:
        break;
    }
}

/* ── The planner ────────────────────────────────────────────────────── */

void src_fw_init(src_fw_t *fw, src_lang_t lang)
{
    memset(fw, 0, sizeof(*fw));
    fw->base.state = FW_RESET;
    fw->fp64_nodes = 0;
    fw->fp32_fallback = 0;
    fw->fp32_nodes = 0;
    fw->total_flops = 0;
    (void)lang;
}

/* Plan the dispatch for one token through all the transformer layers.
 *
 * The structure mirrors the canonical firmware (pnm_fw.c): plan every model
 * layer the model has, group the physical layers by the ceil(hidden/layers)
 * mapping the Go twin uses, and emit a dense record, a normalization record
 * and the MoE fan-out per layer. */
int src_fw_plan_inference(src_fw_t *fw, src_lang_t lang,
                           const uint8_t *token, int token_len,
                           src_dispatch_t *records, int max_records,
                           int *num_records)
{
    const src_profile_t *p = src_profile(lang);

    if (fw->base.state != FW_READY)
        return -1;

    int idx = 0;
    int bx = fw->base.board_x > 0 ? fw->base.board_x : 4;
    int by = fw->base.board_y > 0 ? fw->base.board_y : 4;
    int nodes_per_layer = bx * by;
    int mpl = fw->base.model_layers_per_physical > 0
              ? fw->base.model_layers_per_physical : 1;

    /* Plan every model layer the model actually has and group the physical
     * layers by the Go twin's ceil(hidden/layers) mapping, mirroring the
     * canonical firmware.  The caller-supplied mpl is only a fallback when
     * num_hidden_layers is unknown. */
    int model_layers = fw->base.num_hidden_layers > 0
        ? fw->base.num_hidden_layers : (mpl * fw->base.num_layers);
    if (model_layers > PNM_MAX_MODEL_LAYERS) model_layers = PNM_MAX_MODEL_LAYERS;
    if (model_layers < 0) model_layers = 0;

    int per_physical = fw->base.num_hidden_layers > 0
        ? (fw->base.num_hidden_layers + fw->base.num_layers - 1) / fw->base.num_layers
        : mpl;
    if (per_physical < 1) per_physical = 1;

    for (int ml = 0; ml < model_layers && idx < max_records; ml++) {
        int pl = ml / per_physical;
        if (pl >= fw->base.num_layers) pl = fw->base.num_layers - 1;

        /* Dense path */
        int attn_node = ml % nodes_per_layer;
        src_dispatch_t *r = &records[idx];
        r->base.layer = ml;
        memcpy(r->base.phase, "dense", 6);
        r->base.target.L = (int8_t)pl;
        r->base.target.X = (uint8_t)(attn_node / by);
        r->base.target.Y = (uint8_t)(attn_node % by);
        r->base.expert_idx = -1;
        r->base.flit_bytes = 5 + token_len + 2;
        memcpy(r->base.kv_action, "store", 6);
        r->base.cu_type = p->cu_dense;
        src_annotate(r, lang, 0);
        idx++;

        /* Normalization */
        if (idx < max_records) {
            src_dispatch_t *ln = &records[idx];
            ln->base.layer = ml;
            memcpy(ln->base.phase, "norm", 5);
            ln->base.target.L = (int8_t)pl;
            ln->base.target.X = (uint8_t)(attn_node / by);
            ln->base.target.Y = (uint8_t)(attn_node % by);
            ln->base.expert_idx = -1;
            ln->base.flit_bytes = 5 + token_len + 2;
            memcpy(ln->base.kv_action, "", 1);
            ln->base.cu_type = p->cu_norm;
            src_annotate(ln, lang, 1);
            idx++;
        }

        /* MoE fan-out: the top-k experts for this (token, layer), routed to
         * the node that holds each expert. */
        int candidates[64];
        int ncand = 0;
        for (int e = 0; e < fw->base.moe_count && ncand < 64; e++) {
            if (fw->base.moe_map[e].model_layer == ml)
                candidates[ncand++] = fw->base.moe_map[e].expert_idx;
        }
        int topk_experts[16];
        int nsel = 0;
        if (ncand > 0) {
            nsel = src_select_topk(token, token_len, ml, candidates, ncand,
                                   fw->base.top_k_experts > 0
                                       ? fw->base.top_k_experts : PNM_MAX_TOPK,
                                   topk_experts);
            if (nsel < 0) nsel = 0;
        }
        for (int k = 0; k < nsel && idx < max_records; k++) {
            int expert = topk_experts[k];
            node_id_t node;
            int found = 0;
            for (int e = 0; e < fw->base.moe_count; e++) {
                if (fw->base.moe_map[e].model_layer == ml &&
                    fw->base.moe_map[e].expert_idx == expert) {
                    node = fw->base.moe_map[e].target_node;
                    found = 1;
                    break;
                }
            }
            if (!found) continue;

            src_dispatch_t *m = &records[idx];
            m->base.layer = ml;
            memcpy(m->base.phase, "moe", 4);
            m->base.target.L = (int8_t)pl;
            m->base.target.X = node.X;
            m->base.target.Y = node.Y;
            m->base.expert_idx = expert;
            m->base.flit_bytes = 5 + token_len + 2;
            memcpy(m->base.kv_action, "", 1);
            m->base.cu_type = p->cu_moe;
            src_annotate(m, lang, 2);
            idx++;
        }
    }

    *num_records = idx;
    fw->total_flops = src_fw_estimate_flops(records, idx);
    return 0;
}

/* ── The verifier ───────────────────────────────────────────────────── */

int src_fw_verify_dispatch(src_fw_t *fw, src_lang_t lang,
                           const src_dispatch_t *records, int num_records)
{
    const src_profile_t *p = src_profile(lang);
    (void)fw;
    int last_layer = -1;
    for (int i = 0; i < num_records; i++) {
        if (records[i].base.layer != last_layer) {
            /* The first dispatch of each layer must be the dense one. */
            if (strcmp(records[i].base.phase, "dense") != 0)
                return -1;
            last_layer = records[i].base.layer;
        }
        /* Every dispatch must target a unit the language's profile allows. */
        cu_type_t cu = records[i].base.cu_type;
        if (cu != p->cu_dense && cu != p->cu_moe &&
            cu != p->cu_norm && cu != p->cu_gate)
            return -2;
        /* And it must be the language's precision. */
        if (records[i].precision != p->precision)
            return -3;
    }
    return 0;
}

/* ── The FLOP estimator ─────────────────────────────────────────────── */

int src_fw_estimate_flops(const src_dispatch_t *records, int num_records)
{
    int flops = 0;
    for (int i = 0; i < num_records; i++) {
        int flit_bytes = records[i].base.flit_bytes;
        int bytes = (records[i].precision == 32) ? 4 : 8;
        int elems = (flit_bytes - 7) / bytes;   /* minus the header and CRC */
        if (elems < 0) elems = 0;

        /* A vectorized loop does vec_width elements per instruction. */
        int effective = elems * (records[i].vec_width > 0 ? records[i].vec_width : 1);

        switch (records[i].base.cu_type) {
        case CU_FP64_FMA:
        case CU_FP32_FMA:
            flops += effective * 2;   /* FMA: mul + add */
            break;
        case CU_FP32_ARRAY:
            flops += effective * 2 * 16;  /* a 16-wide MAC array */
            break;
        case CU_FP64_ALU:
        case CU_FP32_ALU:
            if (records[i].shader_op == SRC_OP_LERP) {
                flops += effective * 3;   /* sub + mul + add */
            } else if (records[i].shader_op == SRC_OP_DOT) {
                flops += effective * 2;   /* mul + add */
            } else {
                flops += effective;
            }
            break;
        default:
            flops += effective;
            break;
        }
    }
    return flops;
}
