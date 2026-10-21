/**
 * pnm_fw_haskell.h -- Haskell-optimized firmware for the PNM router chip.
 *
Specialized variant for Haskell workloads: FP64 precision
throughout, with dense path using fp64_fma, LayerNorm using
fp64_alu, and MoE experts using fp64_fma.
\
 * The planner itself lives in src_fw.c, shared with the R and HLSL
 * ports: the three were three copies of the same code, and had
 * already drifted from the canonical firmware.  This header keeps the
 * public names; the implementation forwards to the shared planner.
 *
 * Hardware targets: ARM Cortex-M/R, RISC-V, or custom microcontroller.
 */

#ifndef PNM_FW_HASKELL_H
#define PNM_FW_HASKELL_H

#include "pnm_fw.h"
#include "src_fw.h"

/* -- haskell-specific constants ------------------------------------------- */

#define HASKELL_CU_DENSE     CU_FP64_FMA      /* dense path: FP64 FMA */
#define HASKELL_CU_MOE       CU_FP64_FMA      /* MoE experts: FP64 FMA */
#define HASKELL_CU_NORM      CU_FP64_ALU      /* LayerNorm: FP64 ALU */
#define HASKELL_CU_GATE      CU_FP64_FMA      /* gating network: FP64 FMA */
#define HASKELL_DTYPE        "FP64"           /* native data type name */
#define HASKELL_DTYPE_BYTES  8                /* bytes per element */

/* -- The haskell dispatch record (a view of the shared record) ----------- */

typedef src_dispatch_t haskell_dispatch_t;

/* -- The haskell firmware context (a view of the shared context) ---------- */

typedef src_fw_t haskell_fw_t;

/* -- API --------------------------------------------------------------- */

void haskell_fw_init(haskell_fw_t *fw);

int  haskell_fw_plan_inference(haskell_fw_t *fw, const uint8_t *token,
                         int token_len, haskell_dispatch_t *records,
                         int max_records, int *num_records);

int  haskell_fw_verify_dispatch(haskell_fw_t *fw, const haskell_dispatch_t *records,
                          int num_records);

int  haskell_fw_estimate_flops(const haskell_dispatch_t *records, int num_records);

#endif /* PNM_FW_HASKELL_H */
