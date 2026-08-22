/**
 * pnm_fw_haskell.h — Haskell-optimized firmware for the PNM router chip.
 *
 * Specialized variant for Haskell workloads that require FP64 precision.
 * All compute units are FP64 FMA or FP64 ALU. Dispatch targets nodes
 * with fp64_fma silicon (CU_FP64_FMA for matrix ops, CU_FP64_ALU for
 * reductions and normalization).
 *
 * Hardware targets: ARM Cortex-M/R, RISC-V, or custom microcontroller.
 * No dynamic allocation — all buffers are statically sized.
 */

#ifndef PNM_FW_HASKELL_H
#define PNM_FW_HASKELL_H

#include "pnm_fw.h"

/* ── Haskell-specific constants ─────────────────────────────────────── */

#define HASKELL_CU_DENSE    CU_FP64_FMA   /* dense path: FP64 FMA       */
#define HASKELL_CU_MOE      CU_FP64_FMA   /* MoE experts: FP64 FMA      */
#define HASKELL_CU_NORM     CU_FP64_ALU   /* LayerNorm: FP64 ALU        */
#define HASKELL_CU_GATE     CU_FP64_FMA   /* gating network: FP64 FMA   */
#define HASKELL_DTYPE       "FP64"        /* native data type name       */
#define HASKELL_DTYPE_BYTES 8             /* bytes per element           */

/* ── Haskell dispatch record (extends base) ────────────────────────── */

typedef struct {
    dispatch_record_t base;
    int       precision;     /* 64 for FP64, 32 for FP32 fallback       */
    int       num_regs;      /* registers used in this dispatch          */
    int       depth;         /* expression tree depth (for scheduling)   */
} haskell_dispatch_t;

/* ── Haskell firmware context ──────────────────────────────────────── */

typedef struct {
    firmware_t base;         /* inherits all base firmware state         */
    int        fp64_nodes;   /* count of nodes with fp64_fma             */
    int        fp32_fallback;/* 1 if any node lacks FP64                 */
    int        total_flops;  /* estimated FP64 FLOPs per token           */
} haskell_fw_t;

/* ── API ───────────────────────────────────────────────────────────── */

/* Initialize Haskell firmware */
void haskell_fw_init(haskell_fw_t *fw);

/* Plan inference for one Haskell token (FP64 precision) */
int  haskell_fw_plan_inference(haskell_fw_t *fw, const uint8_t *token,
                               int token_len, haskell_dispatch_t *records,
                               int max_records, int *num_records);

/* Verify that all dispatches target FP64-capable nodes */
int  haskell_fw_verify_dispatch(haskell_fw_t *fw,
                                const haskell_dispatch_t *records,
                                int num_records);

/* Estimate total FP64 FLOPs for the dispatch plan */
int  haskell_fw_estimate_flops(const haskell_dispatch_t *records,
                               int num_records);

#endif /* PNM_FW_HASKELL_H */
