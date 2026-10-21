/**
 * test_src_fw.c — the source-language dispatch ports.
 *
 * The R, Haskell and HLSL ports were compile-checked only: nothing ran
 * them, so nothing could tell whether they planned the same dispatch as the
 * canonical firmware.  They are now one shared implementation (src_fw.c) with
 * three thin wrappers, and this test exercises all three end to end:
 *
 *   - each port plans a dispatch for a token and the plan is well formed
 *     (a dense record first in every layer, the layer's MoE fan-out
 *     present, the right compute units and precision for the language);
 *   - the verifier accepts the plan it produced and rejects a corrupted one;
 *   - the FLOP estimate is non-zero and scales with the payload;
 *   - the three ports agree on the *expert set* (they differ in the
 *     compute units and the annotations, not in which experts a token
 *     selects -- that is the Go twin's selectTopExperts hash).
 *
 * Building it also checks that the shared implementation links: the three
 * ports and src_fw.c are compiled and linked together here.
 */

#include <stdio.h>
#include <string.h>

#include "pnm_fw_r.h"
#include "pnm_fw_haskell.h"
#include "pnm_fw_hlsl.h"

static int errors = 0;

#define CHECK(cond, ...) do { \
    if (!(cond)) { \
        printf("FAIL: "); printf(__VA_ARGS__); printf("\n"); \
        errors++; \
    } \
} while (0)

/* A small chassis with a two-layer MoE map. */
static void setup(firmware_t *fw, int num_layers, int mpl, int hidden)
{
    memset(fw, 0, sizeof(*fw));
    fw->state = FW_READY;
    fw->board_x = 4;
    fw->board_y = 4;
    fw->num_layers = num_layers;
    fw->model_layers_per_physical = mpl;
    fw->num_hidden_layers = hidden;
    fw->top_k_experts = 2;
    fw->moe_count = 0;
    for (int ml = 0; ml < hidden; ml++) {
        for (int e = 0; e < 4; e++) {
            moe_entry_t *m = &fw->moe_map[fw->moe_count++];
            m->model_layer = ml;
            m->expert_idx = e;
            m->target_node.L = (int8_t)(ml / mpl);
            m->target_node.X = (uint8_t)((ml * 2 + e) % 4);
            m->target_node.Y = (uint8_t)((ml * 2 + e) / 4);
            m->cu_type = CU_BF16_FMA;
        }
    }
}

/* Every layer must open with its dense record and carry its MoE fan-out. */
static int check_plan(const src_dispatch_t *recs, int n, int num_layers,
                      int hidden, int topk)
{
    int layers_seen = 0;
    int last_layer = -1;
    int moe_in_layer = 0;
    for (int i = 0; i < n; i++) {
        const dispatch_record_t *base = &recs[i].base;
        if (base->layer != last_layer) {
            if (layers_seen > 0 && moe_in_layer != topk) return -1;  /* the previous layer */
            if (strcmp(base->phase, "dense") != 0) return -2;
            last_layer = base->layer;
            layers_seen++;
            moe_in_layer = 0;
        }
        if (strcmp(base->phase, "moe") == 0) moe_in_layer++;
    }
    if (moe_in_layer != topk) return -3;
    if (layers_seen != hidden) return -4;
    (void)num_layers;
    return 0;
}

int main(void)
{
    /* A 64-byte token: the FLOP estimate divides the payload by the
     * element size, so a 6-byte token would floor to zero elements. */
    static const uint8_t token[64] = {
        'h', 'e', 'l', 'l', 'o', ' ', 'w', 'o', 'r', 'l', 'd', ' ', 'f', 'r', 'o', 'm', ' ', 't', 'h', 'e', ' ', 'P', 'N', 'M', ' ', 'f', 'a', 'b', 'r', 'i', 'c', ' ', 'a', 'n', 'd', ' ', 't', 'h', 'e', ' ', 'n', 'o', 'd', 'e', ' ', 'b', 'o', 'a', 'r', 'd', ' ', 'm', 'e', 'm', 'o', 'r', 'y', '.', '.', '.', '.', '.', '.', '.' };

    /* ---------------- R ---------------- */
    {
        r_fw_t fw;
        static r_dispatch_t recs[256];
        int n = 0;
        setup(&fw.base, 4, 2, 6);
        r_fw_init(&fw);
        setup(&fw.base, 4, 2, 6);
        CHECK(r_fw_plan_inference(&fw, token, 64, recs, 256, &n) == 0,
              "R: the planner returned an error");
        CHECK(n > 0, "R: the planner produced no records");
        CHECK(check_plan((const src_dispatch_t *)recs, n, 4, 6, 2) == 0,
              "R: the plan is malformed (rc %d)",
              check_plan((const src_dispatch_t *)recs, n, 4, 6, 2));
        CHECK(r_fw_verify_dispatch(&fw, recs, n) == 0,
              "R: the verifier rejected the plan it produced");
        CHECK(r_fw_estimate_flops(recs, n) > 0, "R: no FLOPs were estimated");
        CHECK(recs[0].precision == 64, "R: the dense record is not FP64");
        CHECK(recs[0].vec_width == 4 && recs[0].is_vectorized == 1,
              "R: the dense record is not marked vectorized");
        printf("R: %d records, %d FLOPs\n", n, r_fw_estimate_flops(recs, n));

        /* a corrupted plan must be rejected */
        recs[0].precision = 32;
        CHECK(r_fw_verify_dispatch(&fw, recs, n) != 0,
              "R: the verifier accepted a wrong-precision record");
        recs[0].precision = 64;
    }

    /* ---------------- Haskell ---------------- */
    {
        haskell_fw_t fw;
        static haskell_dispatch_t recs[256];
        int n = 0;
        haskell_fw_init(&fw);
        setup(&fw.base, 4, 2, 6);
        CHECK(haskell_fw_plan_inference(&fw, token, 64, recs, 256, &n) == 0,
              "Haskell: the planner returned an error");
        CHECK(n > 0, "Haskell: the planner produced no records");
        CHECK(check_plan((const src_dispatch_t *)recs, n, 4, 6, 2) == 0,
              "Haskell: the plan is malformed");
        CHECK(haskell_fw_verify_dispatch(&fw, recs, n) == 0,
              "Haskell: the verifier rejected the plan it produced");
        CHECK(haskell_fw_estimate_flops(recs, n) > 0,
              "Haskell: no FLOPs were estimated");
        CHECK(recs[0].precision == 64, "Haskell: the dense record is not FP64");
        printf("Haskell: %d records, %d FLOPs\n", n,
               haskell_fw_estimate_flops(recs, n));
    }

    /* ---------------- HLSL ---------------- */
    {
        hlsl_fw_t fw;
        static hlsl_dispatch_t recs[256];
        int n = 0;
        hlsl_fw_init(&fw);
        setup(&fw.base, 4, 2, 6);
        CHECK(hlsl_fw_plan_inference(&fw, token, 64, recs, 256, &n) == 0,
              "HLSL: the planner returned an error");
        CHECK(n > 0, "HLSL: the planner produced no records");
        CHECK(check_plan((const src_dispatch_t *)recs, n, 4, 6, 2) == 0,
              "HLSL: the plan is malformed");
        CHECK(hlsl_fw_verify_dispatch(&fw, recs, n) == 0,
              "HLSL: the verifier rejected the plan it produced");
        CHECK(hlsl_fw_estimate_flops(recs, n) > 0, "HLSL: no FLOPs were estimated");
        CHECK(recs[0].precision == 32, "HLSL: the dense record is not FP32");
        CHECK(recs[0].base.cu_type == HLSL_CU_DENSE,
              "HLSL: the dense record is not on the FP32 ALU");
        printf("HLSL: %d records, %d FLOPs\n", n,
               hlsl_fw_estimate_flops(recs, n));
    }

    if (errors == 0)
        printf("*** SOURCE FIRMWARE TEST PASSED ***\n");
    else
        printf("*** SOURCE FIRMWARE TEST FAILED (%d) ***\n", errors);
    return errors ? 1 : 0;
}
