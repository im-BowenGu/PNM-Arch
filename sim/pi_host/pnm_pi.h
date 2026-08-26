/* pnm_pi.h — PNM router host driver API for Raspberry Pi CM5 (PCIe)
 *
 * The CM5 exposes a Gen3 x1 link through its FPC connector. A PNM chassis
 * front-ended by a PCIe bridge enumerates as an endpoint device whose BAR0
 * is the router-chip PNM register window (CTRL@0x00 .. WEIGHT_FLITS@0x24).
 * This driver mmaps BAR0 from sysfs and mirrors the pnm_regs.h API used by
 * the MCU firmware and the pnm_dev.h API used by the SoC daemon.
 */

#ifndef PNM_PI_H
#define PNM_PI_H

#include <stdint.h>

#define PNM_PI_CTRL       0x00
#define PNM_PI_LAYER      0x04
#define PNM_PI_MODULE     0x08
#define PNM_PI_LEN        0x0C
#define PNM_PI_DATA       0x10
#define PNM_PI_STATUS     0x14
#define PNM_PI_RESULT     0x18
#define PNM_PI_ERRORS     0x1C
#define PNM_PI_DISPATCHES 0x20
#define PNM_PI_WEIGHTS    0x24

#define PNM_CTRL_INJECT   (1u << 0)
#define PNM_CTRL_BOOTDONE (1u << 2)
#define PNM_STATUS_BUSY   (1u << 0)

int      pnm_pi_open(const char *sysfs_dir);
void     pnm_pi_close(void);
uint32_t pnm_pi_reg_read(unsigned offset);
void     pnm_pi_reg_write(unsigned offset, uint32_t value);
int      pnm_pi_boot_done(void);
uint32_t pnm_pi_dispatch_count(void);
int      pnm_pi_inject(uint8_t layer, uint8_t module,
                       const uint8_t *payload, uint16_t len);

typedef struct pnm_card pnm_card;

int      pnm_pi_open_at(pnm_card *card, const char *sysfs_dir);
void     pnm_pi_close_at(pnm_card *card);
uint32_t pnm_pi_reg_read_at(pnm_card *card, unsigned offset);
void     pnm_pi_reg_write_at(pnm_card *card, unsigned offset, uint32_t value);
int      pnm_pi_boot_done_at(pnm_card *card);
uint32_t pnm_pi_dispatch_count_at(pnm_card *card);
int      pnm_pi_inject_at(pnm_card *card, uint8_t layer, uint8_t module,
                          const uint8_t *payload, uint16_t len);

#endif /* PNM_PI_H */
