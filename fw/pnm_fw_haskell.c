/**
 * pnm_fw_haskell -- the haskell port of the shared source-language
 * dispatch firmware.
 *
 * The planner, the verifier and the FLOP estimator live in src_fw.c; this
 * file keeps the haskell-specific public names and forwards to them.
 */

#include "pnm_fw_haskell.h"

void haskell_fw_init(haskell_fw_t *fw)
{
    src_fw_init(fw, SRC_LANG_HASKELL);
}

int haskell_fw_plan_inference(haskell_fw_t *fw, const uint8_t *token,
                        int token_len, haskell_dispatch_t *records,
                        int max_records, int *num_records)
{
    return src_fw_plan_inference(fw, SRC_LANG_HASKELL, token, token_len,
                                 records, max_records, num_records);
}

int haskell_fw_verify_dispatch(haskell_fw_t *fw, const haskell_dispatch_t *records,
                         int num_records)
{
    return src_fw_verify_dispatch(fw, SRC_LANG_HASKELL, records, num_records);
}

int haskell_fw_estimate_flops(const haskell_dispatch_t *records, int num_records)
{
    return src_fw_estimate_flops(records, num_records);
}
