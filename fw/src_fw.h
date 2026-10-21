/**
 * src_fw.h — the shared source-language dispatch firmware.
 *
 * R, Haskell and HLSL all compile to the same straight-line FP64/FP32 IR and
 * are dispatched over the same fabric; only the compute-unit profile and a
 * few per-language record annotations differ.  The three ports used to be
 * three copies of the same planner, which had already drifted apart from the
 * canonical firmware (fw/pnm_fw.c) in the features it carried.
 *
 * This is the shared implementation: one planner, one verifier, one flop
 * estimator, and a table of language profiles.  The three public headers
 * (pnm_fw_r.h, pnm_fw_haskell.h, pnm_fw_hlsl.h) keep their own names and
 * forward to it, so nothing outside fw/ changes.
 */

#ifndef PNM_SRC_FW_H
#define PNM_SRC_FW_H

#include "pnm_fw.h"

/* ── The source languages ───────────────────────────────────────────── */

typedef enum {
    SRC_LANG_R = 0,
    SRC_LANG_HASKELL = 1,
    SRC_LANG_HLSL = 2
} src_lang_t;

/* ── The per-language profile ───────────────────────────────────────── */

typedef struct {
    const char *name;         /* "R", "Haskell", "HLSL"                */
    cu_type_t   cu_dense;     /* the dense/attention path's unit        */
    cu_type_t   cu_moe;       /* the MoE expert path's unit             */
    cu_type_t   cu_norm;      /* the normalization path's unit          */
    cu_type_t   cu_gate;      /* the gating network's unit              */
    int         precision;    /* 64 or 32                               */
    const char *dtype;        /* the native data type's name            */
    int         dtype_bytes;  /* bytes per element                      */
} src_profile_t;

/* The profile for a language. */
const src_profile_t *src_profile(src_lang_t lang);

/* ── The dispatch record (the union of the three languages' fields) ──── */

typedef struct {
    dispatch_record_t base;
    int precision;     /* 64 or 32                                       */
    int vec_width;     /* SIMD vector width (R: 4; 1 when scalar)       */
    int is_vectorized; /* 1 if vectorized loop, 0 if scalar             */
    int num_regs;      /* register budget of the emitted program        */
    int depth;         /* expression nesting depth                      */
    int shader_op;     /* the HLSL operator kind                        */
    int group_size;    /* the HLSL group width                          */
} src_dispatch_t;

/* ── The firmware context ───────────────────────────────────────────── */

typedef struct {
    firmware_t base;    /* inherits all base firmware state             */
    int        fp64_nodes;   /* nodes carrying an FP64 unit             */
    int        fp32_fallback;/* 1 if any node lacks FP64 (Haskell)     */
    int        fp32_nodes;   /* nodes carrying an FP32 unit (HLSL)      */
    int        total_flops;  /* estimated FLOPs per token               */
} src_fw_t;

/* ── API ─────────────────────────────────────────────────────────────── */

void src_fw_init(src_fw_t *fw, src_lang_t lang);

int  src_fw_plan_inference(src_fw_t *fw, src_lang_t lang,
                            const uint8_t *token, int token_len,
                            src_dispatch_t *records, int max_records,
                            int *num_records);

int  src_fw_verify_dispatch(src_fw_t *fw, src_lang_t lang,
                            const src_dispatch_t *records, int num_records);

int  src_fw_estimate_flops(const src_dispatch_t *records, int num_records);

#endif /* PNM_SRC_FW_H */
