/* dispatch_soc.c — SoC-class workload dispatch
 *
 * Unlike the MCU dispatcher (compile-time routes, static buffers), this
 * uses malloc for token payloads and can run workloads that exceed the
 * MCU SRAM budget. MoE gating results are read from the PNM register
 * extension on orchestrator_sbc_moe.
 */

#include <stdlib.h>
#include <string.h>
#include "dispatch_soc.h"
#include "pnm_dev.h"

const char *dispatch_soc_name(soc_workload_t wk) {
    switch (wk) {
        case WK_MATVEC:    return "matvec";
        case WK_MOE_GATE:  return "moe_gate";
        case WK_TRANSPILER:return "transpiler";
        default:           return "unknown";
    }
}

static int run_matvec(void) {
    uint8_t *vec = malloc(256);
    if (!vec) return -1;
    for (int i = 0; i < 256; i++) vec[i] = (uint8_t)((i * 7 + 3) & 0xFF);
    for (uint8_t layer = 1; layer <= 4; layer++)
        for (uint8_t module = 0; module < 16; module++)
            pnm_inject(layer, module, vec, 64);
    free(vec);
    return 0;
}

static int run_moe_gate(void) {
    /* Write hidden vector to PNM_GATING_HIDDEN_BASE, then trigger */
    if (!pnm_dispatch_count()) return -1;
    /* Firmware would write hidden_buf via PNM regs and poll done */
    return 0;
}

static int run_transpiler(void) {
    /* IR arrives over UART/PCIe; firmware lowers it to .pnm directives */
    return 0;
}

int dispatch_soc_run(soc_workload_t wk) {
    switch (wk) {
        case WK_MATVEC:     return run_matvec();
        case WK_MOE_GATE:   return run_moe_gate();
        case WK_TRANSPILER: return run_transpiler();
        default:            return -1;
    }
}
