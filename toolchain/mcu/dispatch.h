/* dispatch.h — workload dispatch interface for MCU firmware */

#ifndef DISPATCH_H
#define DISPATCH_H

#include <stdint.h>
#include "pnm_regs.h"

typedef enum {
    WK_JACOBI5 = 0,
    WK_REDUCTION,
    WK_BROADCAST,
    WK_COUNT
} workload_t;

void dispatch_init(void);
void dispatch_run(workload_t wk);
const char *dispatch_name(workload_t wk);

#endif /* DISPATCH_H */
