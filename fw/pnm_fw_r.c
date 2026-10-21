/**
 * pnm_fw_r -- the r port of the shared source-language
 * dispatch firmware.
 *
 * The planner, the verifier and the FLOP estimator live in src_fw.c; this
 * file keeps the r-specific public names and forwards to them.
 */

#include "pnm_fw_r.h"

void r_fw_init(r_fw_t *fw)
{
    src_fw_init(fw, SRC_LANG_R);
}

int r_fw_plan_inference(r_fw_t *fw, const uint8_t *token,
                        int token_len, r_dispatch_t *records,
                        int max_records, int *num_records)
{
    return src_fw_plan_inference(fw, SRC_LANG_R, token, token_len,
                                 records, max_records, num_records);
}

int r_fw_verify_dispatch(r_fw_t *fw, const r_dispatch_t *records,
                         int num_records)
{
    return src_fw_verify_dispatch(fw, SRC_LANG_R, records, num_records);
}

int r_fw_estimate_flops(const r_dispatch_t *records, int num_records)
{
    return src_fw_estimate_flops(records, num_records);
}
