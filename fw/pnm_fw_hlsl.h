/**
 * pnm_fw_hlsl.h — HLSL-optimized firmware for the PNM router chip.
 *
 * Specialized variant for HLSL shader workloads that use FP32 precision
 * with FP32 ALU for shader-specific operations (dot, lerp, clamp, rcp).
 * MoE experts use fp32_mac_array for matrix multiply, dense path uses
 * fp32_alu for per-element shader operations.
 *
 * Hardware targets: ARM Cortex-M/R, RISC-V, or custom microcontroller.
 */

#ifndef PNM_FW_HLSL_H
#define PNM_FW_HLSL_H

#include "pnm_fw.h"

/* ── HLSL-specific constants ───────────────────────────────────────── */

#define HLSL_CU_DENSE    CU_FP32_ALU    /* shader ops: FP32 ALU          */
#define HLSL_CU_MOE      CU_FP32_ARRAY  /* MoE experts: FP32 MAC array   */
#define HLSL_CU_NORM     CU_FP32_ALU    /* LayerNorm: FP32 ALU           */
#define HLSL_CU_GATE     CU_FP32_FMA    /* gating network: FP32 FMA      */
#define HLSL_DTYPE       "FP32"         /* native data type name          */
#define HLSL_DTYPE_BYTES 4              /* bytes per element              */

/* ── HLSL dispatch record (extends base) ──────────────────────────── */

typedef struct {
    dispatch_record_t base;
    int       precision;     /* 32 for FP32                             */
    int       shader_op;     /* HLSL-specific op code (dot/lerp/etc.)   */
    int       group_size;    /* compute group size (thread count)       */
} hlsl_dispatch_t;

/* ── HLSL firmware context ────────────────────────────────────────── */

typedef struct {
    firmware_t base;         /* inherits all base firmware state        */
    int        fp32_nodes;   /* count of nodes with fp32_alu            */
    int        total_flops;  /* estimated FP32 FLOPs per token          */
} hlsl_fw_t;

/* ── API ───────────────────────────────────────────────────────────── */

void hlsl_fw_init(hlsl_fw_t *fw);

int  hlsl_fw_plan_inference(hlsl_fw_t *fw, const uint8_t *token,
                            int token_len, hlsl_dispatch_t *records,
                            int max_records, int *num_records);

int  hlsl_fw_verify_dispatch(hlsl_fw_t *fw,
                             const hlsl_dispatch_t *records,
                             int num_records);

int  hlsl_fw_estimate_flops(const hlsl_dispatch_t *records,
                            int num_records);

#endif /* PNM_FW_HLSL_H */
