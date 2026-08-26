/* pnm_dev.h — PNM register access via /dev/pnm device node (SoC mode)
 *
 * Unlike MCU firmware which hard-codes physical addresses, SoC firmware
 * runs under an OS and accesses PNM registers through a character device.
 * The kernel driver maps the 0xF000_0000 window into process address space.
 */

#ifndef PNM_DEV_H
#define PNM_DEV_H

#include <stdint.h>

int  pnm_open(void);
void pnm_close(void);
int  pnm_inject(uint8_t layer, uint8_t module, const uint8_t *payload, uint16_t len);
int  pnm_boot_done(void);
uint32_t pnm_dispatch_count(void);

#endif /* PNM_DEV_H */
