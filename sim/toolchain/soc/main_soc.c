/* main_soc.c — SoC userspace daemon entry point
 *
 * Runs under NOMMU Linux/Redox. Initializes the PNM device, signals
 * boot_done, then enters a service loop that polls for incoming IR from
 * the host and dispatches workloads.
 */

#include "dispatch_soc.h"
#include "pnm_dev.h"

#define CONFIGURED_WORKLOAD WK_MATVEC

int main(int argc, char **argv) {
    if (pnm_open() != 0)
        return 1;

    pnm_boot_done();

    for (;;) {
        dispatch_soc_run(CONFIGURED_WORKLOAD);
        for (volatile int i = 0; i < 1000000; i++) {}
    }

    pnm_close();
    return 0;
}
