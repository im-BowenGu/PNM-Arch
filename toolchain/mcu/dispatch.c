/* dispatch.c — MCU-class workload dispatch for orchestrator_mcu
 *
 * Implements compile-time-routed workloads that fit within the 4KB SRAM
 * and 8KB ROM budget. Routes are burned into the payload arrays below;
 * no runtime route computation, no dynamic memory.
 */

#include "dispatch.h"
#include "uart_drv.h"

#define NUM_NODES 32

static const uint8_t jacobi_weights[5] = {0x28, 0x08, 0x08, 0x08, 0x08};

static uint8_t tx_buf[64];

void dispatch_init(void) {
    uart_puts("dispatch init\n");
}

const char *dispatch_name(workload_t wk) {
    switch (wk) {
        case WK_JACOBI5:   return "jacobi5";
        case WK_REDUCTION: return "reduction";
        case WK_BROADCAST: return "broadcast";
        default:           return "unknown";
    }
}

static void run_jacobi5(void) {
    for (uint8_t x = 0; x < 4; x++) {
        for (uint8_t y = 0; y < 4; y++) {
            uint8_t node = y * 4 + x;
            tx_buf[0] = node;
            tx_buf[1] = (node > 3)         ? node - 4 : node;
            tx_buf[2] = (node < 12)        ? node + 4 : node;
            tx_buf[3] = ((node & 3) != 3)  ? node + 1 : node;
            tx_buf[4] = ((node & 3) != 0)  ? node - 1 : node;
            pnm_inject(1, node, tx_buf, 5);
        }
    }
}

static void run_reduction(void) {
    for (uint8_t leaf = 0; leaf < 8; leaf++) {
        tx_buf[0] = leaf;
        tx_buf[1] = 0xAA;
        tx_buf[2] = 0x55;
        pnm_inject(1, leaf, tx_buf, 3);
    }
}

static void run_broadcast(void) {
    tx_buf[0] = 0xDE;
    tx_buf[1] = 0xAD;
    tx_buf[2] = 0xBE;
    tx_buf[3] = 0xEF;
    for (uint8_t layer = 1; layer <= 2; layer++)
        for (uint8_t module = 0; module < 16; module++)
            pnm_inject(layer, module, tx_buf, 4);
}

void dispatch_run(workload_t wk) {
    switch (wk) {
        case WK_JACOBI5:   run_jacobi5();   break;
        case WK_REDUCTION: run_reduction(); break;
        case WK_BROADCAST: run_broadcast(); break;
        default: break;
    }
}
