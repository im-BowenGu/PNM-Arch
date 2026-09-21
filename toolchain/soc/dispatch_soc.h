/* dispatch_soc.h — SoC-class workload dispatch interface */

#ifndef DISPATCH_SOC_H
#define DISPATCH_SOC_H

#include <stdint.h>

typedef enum {
    WK_MATVEC = 0,
    WK_MOE_GATE,
    WK_TRANSPILER,
    WK_COUNT
} soc_workload_t;

int dispatch_soc_run(soc_workload_t wk);
const char *dispatch_soc_name(soc_workload_t wk);

#endif /* DISPATCH_SOC_H */
