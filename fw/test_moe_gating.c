/* test_moe_gating.c — verify fw_plan_inference MoE routing matches the Go
 * firmware's deterministic selectTopExperts gating.
 *
 * Builds a firmware whose MoE map holds experts 0..N-1 on model layer 0,
 * runs fw_plan_inference for several tokens, and prints the expert_idx of
 * each "moe" dispatch record as a line "TOKEN <tok> SEL <e0> <e1> ...".
 *
 * The Go integration test cross-checks these selections against the reference
 * selectTopExperts output for the same (token, layer).
 */
#include <stdio.h>
#include <string.h>
#include "pnm_fw.h"

#define N_EXPERTS 16
#define N_TOKENS  5

static void build_map(firmware_t *fw, int n) {
    memset(fw, 0, sizeof(*fw));
    fw->state = FW_READY;
    fw->board_x = 4;
    fw->board_y = 4;
    fw->num_layers = 1;
    fw->model_layers_per_physical = 1;
    fw->moe_count = 0;
    for (int e = 0; e < n; e++) {
        fw->moe_map[fw->moe_count].model_layer = 0;
        fw->moe_map[fw->moe_count].expert_idx = e;
        fw->moe_map[fw->moe_count].target_node.L = 0;
        fw->moe_map[fw->moe_count].target_node.X = (uint8_t)(e % 4);
        fw->moe_map[fw->moe_count].target_node.Y = (uint8_t)(e / 4);
        fw->moe_map[fw->moe_count].cu_type = CU_BF16_FMA;
        fw->moe_count++;
    }
}

int main(void) {
    firmware_t fw;
    build_map(&fw, N_EXPERTS);

    const char *tokens[N_TOKENS] = {
        "hello", "world", "the", "quick", "brown"
    };

    for (int t = 0; t < N_TOKENS; t++) {
        dispatch_record_t records[PNM_MAX_MODEL_LAYERS * (PNM_MAX_TOPK + 1)];
        int nrec = 0;
        int rc = fw_plan_inference(&fw, (const uint8_t *)tokens[t],
                                   (int)strlen(tokens[t]), records,
                                   PNM_MAX_MODEL_LAYERS * (PNM_MAX_TOPK + 1),
                                   &nrec);
        if (rc != 0) { printf("RESULT: ERR\n"); return 1; }
        printf("TOKEN %s SEL", tokens[t]);
        for (int i = 0; i < nrec; i++)
            if (strcmp(records[i].phase, "moe") == 0)
                printf(" %d", records[i].expert_idx);
        printf("\n");
    }

    printf("RESULT: ALL PASS\n");
    return 0;
}
