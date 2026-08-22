/**
 * pnm_fw_r.h — R-optimized firmware for the PNM router chip.
 *
 * Specialized variant for R workloads that require FP64 precision.
 * Same precision profile as Haskell (FP64 throughout) but with
 * R-specific dispatch patterns (vectorized operations, no recursion).
 *
 * Hardware targets: ARM Cortex-M/R, RISC-V, or custom microcontroller.
 */

#ifndef PNM_FW_R_H
#define PNM_FW_R_H

#include "pnm_fw.h"

/* ── R-specific constants ──────────────────────────────────────────── */

#define R_CU_DENSE    CU_FP64_FMA    /* dense path: FP64 FMA            */
#define R_CU_MOE      CU_FP64_FMA    /* MoE experts: FP64 FMA           */
#define R_CU_NORM     CU_FP64_ALU    /* LayerNorm: FP64 ALU             */
#define R_CU_GATE     CU_FP64_FMA    /* gating network: FP64 FMA        */
#define R_DTYPE       "FP64"         /* native data type name            */
#define R_DTYPE_BYTES 8              /* bytes per element                */

/* ── R dispatch record (extends base) ─────────────────────────────── */

typedef struct {
    dispatch_record_t base;
    int       precision;     /* 64 for FP64                            */
    int       vec_width;     /* SIMD vector width (1 for scalar)       */
    int       is_vectorized; /* 1 if vectorized loop, 0 if scalar      */
} r_dispatch_t;

/* ── R firmware context ───────────────────────────────────────────── */

typedef struct {
    firmware_t base;         /* inherits all base firmware state        */
    int        fp64_nodes;   /* count of nodes with fp64_fma            */
    int        total_flops;  /* estimated FP64 FLOPs per token          */
} r_fw_t;

/* ── API ───────────────────────────────────────────────────────────── */

void r_fw_init(r_fw_t *fw);

int  r_fw_plan_inference(r_fw_t *fw, const uint8_t *token,
                         int token_len, r_dispatch_t *records,
                         int max_records, int *num_records);

int  r_fw_verify_dispatch(r_fw_t *fw, const r_dispatch_t *records,
                          int num_records);

int  r_fw_estimate_flops(const r_dispatch_t *records, int num_records);

#endif /* PNM_FW_R_H */
