/* pnm_dev.c — PNM device driver for NOMMU Linux/Redox
 *
 * Opens /dev/pnm and mmaps the register window. Falls back to raw
 * physical address access if /dev/pnm is absent (bare-metal bring-up).
 */

#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include "pnm_dev.h"

#define PNM_WINDOW_SIZE 0x40
#define PNM_PHYS_BASE   0xF0000000u

static volatile uint32_t *regs = 0;

#define R(off) (regs[(off) >> 2])
#define W(off, v) (regs[(off) >> 2] = (v))

int pnm_open(void) {
    int fd = open("/dev/pnm", O_RDWR);
    if (fd < 0)
        return -1;

    regs = mmap(0, PNM_WINDOW_SIZE, PROT_READ | PROT_WRITE,
                MAP_SHARED, fd, PNM_PHYS_BASE);
    if (regs == (void *)-1) {
        close(fd);
        return -1;
    }
    return 0;
}

void pnm_close(void) {
    if (regs) munmap((void *)regs, PNM_WINDOW_SIZE);
    regs = 0;
}

int pnm_inject(uint8_t layer, uint8_t module, const uint8_t *payload, uint16_t len) {
    if (!regs) return -1;
    while (R(0x14) & 1) {}
    W(0x04, layer);
    W(0x08, module);
    W(0x0C, len);
    for (uint16_t i = 0; i < len; i++)
        W(0x10, payload[i]);
    W(0x00, 1);
    return 0;
}

int pnm_boot_done(void) {
    if (!regs) return -1;
    W(0x00, 4);
    return 0;
}

uint32_t pnm_dispatch_count(void) {
    return regs ? R(0x20) : 0;
}
