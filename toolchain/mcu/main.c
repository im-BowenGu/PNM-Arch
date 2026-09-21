/* main.c — bare-metal entry point for orchestrator_mcu
 *
 * Boot sequence:
 *   1. Poll topology_rdy (POST discovery stub)
 *   2. Signal boot_done
 *   3. Run the configured workload in a loop
 */

#include "dispatch.h"
#include "uart_drv.h"
#include "pnm_regs.h"

#define CONFIGURED_WORKLOAD WK_JACOBI5

void main(void) {
    uart_puts("\nPNM MCU router boot\n");
    uart_puts("workload: ");
    uart_puts(dispatch_name(CONFIGURED_WORKLOAD));
    uart_puts("\n");

    dispatch_init();
    pnm_signal_boot_done();

    for (;;) {
        dispatch_run(CONFIGURED_WORKLOAD);
        for (volatile int i = 0; i < 100000; i++) {}
    }
}
