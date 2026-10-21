/**
 * pnm_fw_hlsl.h -- HLSL-optimized firmware for the PNM router chip.
 *
Specialized variant for HLSL (shader) workloads: FP32 precision,
with dense path using the FP32 ALU, MoE experts using the FP32
MAC array, and LayerNorm using the FP32 ALU.
\
 * The planner itself lives in src_fw.c, shared with the R and
 * Haskell ports: the three were three copies of the same code, and
 * had already drifted from the canonical firmware.  This header
 * keeps the public names; the implementation forwards to the shared
 * planner.
 *
 * Hardware targets: ARM Cortex-M/R, RISC-V, or custom microcontroller.
 */

#ifndef PNM_FW_HLSL_H
#define PNM_FW_HLSL_H

#include "pnm_fw.h"
#include "src_fw.h"

/* -- hlsl-specific constants ------------------------------------------- */

#define HLSL_CU_DENSE        CU_FP32_ALU      /* shader ops: FP32 ALU */
#define HLSL_CU_MOE          CU_FP32_ARRAY    /* MoE experts: FP32 MAC array */
#define HLSL_CU_NORM         CU_FP32_ALU      /* LayerNorm: FP32 ALU */
#define HLSL_CU_GATE         CU_FP32_FMA      /* gating network: FP32 FMA */
#define HLSL_DTYPE           "FP32"           /* native data type name */
#define HLSL_DTYPE_BYTES     4                /* bytes per element */

/* -- The hlsl dispatch record (a view of the shared record) ----------- */

typedef src_dispatch_t hlsl_dispatch_t;

/* -- The hlsl firmware context (a view of the shared context) ---------- */

typedef src_fw_t hlsl_fw_t;

/* -- API --------------------------------------------------------------- */

void hlsl_fw_init(hlsl_fw_t *fw);

int  hlsl_fw_plan_inference(hlsl_fw_t *fw, const uint8_t *token,
                         int token_len, hlsl_dispatch_t *records,
                         int max_records, int *num_records);

int  hlsl_fw_verify_dispatch(hlsl_fw_t *fw, const hlsl_dispatch_t *records,
                          int num_records);

int  hlsl_fw_estimate_flops(const hlsl_dispatch_t *records, int num_records);

#endif /* PNM_FW_HLSL_H */
