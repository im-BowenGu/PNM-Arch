/**
 * pnm_fw_hlsl -- the hlsl port of the shared source-language
 * dispatch firmware.
 *
 * The planner, the verifier and the FLOP estimator live in src_fw.c; this
 * file keeps the hlsl-specific public names and forwards to them.
 */

#include "pnm_fw_hlsl.h"

void hlsl_fw_init(hlsl_fw_t *fw)
{
    src_fw_init(fw, SRC_LANG_HLSL);
}

int hlsl_fw_plan_inference(hlsl_fw_t *fw, const uint8_t *token,
                        int token_len, hlsl_dispatch_t *records,
                        int max_records, int *num_records)
{
    return src_fw_plan_inference(fw, SRC_LANG_HLSL, token, token_len,
                                 records, max_records, num_records);
}

int hlsl_fw_verify_dispatch(hlsl_fw_t *fw, const hlsl_dispatch_t *records,
                         int num_records)
{
    return src_fw_verify_dispatch(fw, SRC_LANG_HLSL, records, num_records);
}

int hlsl_fw_estimate_flops(const hlsl_dispatch_t *records, int num_records)
{
    return src_fw_estimate_flops(records, num_records);
}
