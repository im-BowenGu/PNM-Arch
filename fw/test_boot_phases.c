/**
 * test_boot_phases.c — the boot sequence's routing and gating phases.
 *
 * Two of the five boot phases used to be no-ops in both twins: the routing
 * table load and the MoE gating load.  They are real now -- the routing
 * table is programmed with the 11-bit routing bitmaps, and the gating
 * phase tells each node's gating engine which layer it holds and how big
 * its router is -- and this test checks that the C twin and the Go twin
 * agree on both.
 *
 * The Go twin's values are compared against the C's here, by the Go
 * integration test that runs this program.
 */

#include <stdio.h>
#include <string.h>

#include "pnm_fw.h"

int main(void)
{
    firmware_t fw;
    int i;

    memset(&fw, 0, sizeof(fw));
    fw.state = FW_RESET;
    fw.board_x = 4;
    fw.board_y = 4;
    fw.num_layers = 2;
    fw.model_layers_per_physical = 1;
    fw.num_hidden_layers = 3;
    fw.top_k_experts = 2;

    /* the inventory, as the POST phase would have produced it */
    fw.node_count = 0;
    for (int l = 0; l < fw.num_layers; l++)
        for (int x = 0; x < fw.board_x; x++)
            for (int y = 0; y < fw.board_y; y++) {
                void *invp = &fw.inventory[fw.node_count];
                fw.inventory[fw.node_count].node.L = (int8_t)l;
                fw.inventory[fw.node_count].node.X = (uint8_t)x;
                fw.inventory[fw.node_count].node.Y = (uint8_t)y;
                fw.inventory[fw.node_count].module_id = (uint8_t)((x << 4) | y);
                fw.inventory[fw.node_count].bandwidth = 512;
                fw.inventory[fw.node_count].status = 1;
                fw.node_count++;
            }

    /* the MoE map, as the compiler would have produced it */
    fw.moe_count = 0;
    for (int ml = 0; ml < 3; ml++)
        for (int e = 0; e < 2; e++) {
            moe_entry_t *m = &fw.moe_map[fw.moe_count++];
            m->model_layer = ml;
            m->expert_idx = e;
            m->target_node.L = (int8_t)(ml / 2);
            m->target_node.X = (uint8_t)e;
            m->target_node.Y = 0;
            m->cu_type = CU_BF16_FMA;
        }

    /* Phase 2: the routing table */
    if (fw_boot_routing_table(&fw) != 0) {
        printf("FAIL: the routing-table phase failed\n");
        return 1;
    }
    printf("ROUTING_COUNT %d\n", fw.routing_count);
    for (i = 0; i < fw.routing_count; i++) {
        printf("ROUTE %d %d %d %04X\n",
               fw.routes[i].node.L, fw.routes[i].node.X, fw.routes[i].node.Y,
               fw.routes[i].bitmap);
    }

    /* Phase 4: the gating programs */
    if (fw_boot_moe_load(&fw) != 0) {
        printf("FAIL: the gating-load phase failed\n");
        return 1;
    }
    printf("GATING_COUNT %d\n", fw.gating_program_count);

    /* the bitmap's shape: [10:7] the 1-based layer, [6] the Y axis,
     * [4:0] the hop distance */
    for (i = 0; i < fw.routing_count; i++) {
        uint16_t want = (uint16_t)(((uint16_t)(fw.routes[i].node.L + 1) << 7) |
                                   (1u << 6) |
                                   ((uint16_t)fw.routes[i].node.Y & 0x1Fu));
        if (fw.routes[i].bitmap != want) {
            printf("FAIL: node (%d,%d,%d) has the bitmap %04X, expected %04X\n",
                   fw.routes[i].node.L, fw.routes[i].node.X, fw.routes[i].node.Y,
                   fw.routes[i].bitmap, want);
            return 1;
        }
    }

    printf("*** BOOT PHASES TEST PASSED ***\n");
    return 0;
}
