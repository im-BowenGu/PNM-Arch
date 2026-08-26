/* pnm_pi_cm5.c — PNM router host driver for Raspberry Pi CM5 over PCIe
 *
 * Maps the PNM endpoint's BAR0 through sysfs into user space and drives the
 * router register window directly. No kernel module required (UIO-style
 * userspace mapping of /sys/bus/pci/devices/<bdf>/resource0).
 *
 * Usage:
 *   PNMCard card;
 *   if (pnm_pi_open_at(&card, "/sys/bus/pci/devices/0001:01:00.0") != 0) ...
 *   pnm_pi_boot_done_at(&card);
 *   pnm_pi_inject_at(&card, 1, 5, payload, len);
 *
 * The _at variants take an explicit card handle so one process can drive
 * several chassis; the plain names in pnm_pi.h operate on a default handle.
 */

#include "pnm_pi.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>

#define PNM_PI_MAP_MAX (1u << 20)

struct pnm_card {
    volatile uint8_t *regs;
    uint32_t map_size;
    int fd;
};

static pnm_card default_card;

int pnm_pi_open_at(pnm_card *card, const char *sysfs_dir)
{
    char path[512];
    FILE *rf;
    unsigned long long start = 0, end = 0;
    uint32_t size;

    memset(card, 0, sizeof(*card));

    snprintf(path, sizeof(path), "%s/resource", sysfs_dir);
    rf = fopen(path, "r");
    if (!rf) {
        perror("open resource");
        return -1;
    }
    if (fscanf(rf, "%llx %llx", &start, &end) != 2 || end < start) {
        fclose(rf);
        fprintf(stderr, "pnm_pi: BAR0 absent or malformed in %s\n", path);
        return -1;
    }
    fclose(rf);

    size = (uint32_t)(end - start + 1);
    if (size > PNM_PI_MAP_MAX)
        size = PNM_PI_MAP_MAX;

    snprintf(path, sizeof(path), "%s/resource0", sysfs_dir);
    card->fd = open(path, O_RDWR | O_SYNC);
    if (card->fd < 0) {
        perror("open resource0");
        return -1;
    }

    card->regs = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED,
                      card->fd, 0);
    if (card->regs == MAP_FAILED) {
        perror("mmap BAR0");
        close(card->fd);
        card->fd = -1;
        return -1;
    }
    card->map_size = size;
    return 0;
}

void pnm_pi_close_at(pnm_card *card)
{
    if (card->regs && card->map_size)
        munmap((void *)card->regs, card->map_size);
    if (card->fd >= 0)
        close(card->fd);
    memset(card, 0, sizeof(*card));
}

uint32_t pnm_pi_reg_read_at(pnm_card *card, unsigned offset)
{
    return *(volatile uint32_t *)(card->regs + offset);
}

void pnm_pi_reg_write_at(pnm_card *card, unsigned offset, uint32_t value)
{
    *(volatile uint32_t *)(card->regs + offset) = value;
}

int pnm_pi_boot_done_at(pnm_card *card)
{
    pnm_pi_reg_write_at(card, PNM_PI_CTRL, PNM_CTRL_BOOTDONE);
    return 0;
}

uint32_t pnm_pi_dispatch_count_at(pnm_card *card)
{
    return pnm_pi_reg_read_at(card, PNM_PI_DISPATCHES);
}

int pnm_pi_inject_at(pnm_card *card, uint8_t layer, uint8_t module,
                     const uint8_t *payload, uint16_t len)
{
    uint16_t i;

    while (pnm_pi_reg_read_at(card, PNM_PI_STATUS) & PNM_STATUS_BUSY) {}

    pnm_pi_reg_write_at(card, PNM_PI_LAYER, layer);
    pnm_pi_reg_write_at(card, PNM_PI_MODULE, module);
    pnm_pi_reg_write_at(card, PNM_PI_LEN, len);
    for (i = 0; i < len; i++)
        pnm_pi_reg_write_at(card, PNM_PI_DATA, payload[i]);
    pnm_pi_reg_write_at(card, PNM_PI_CTRL, PNM_CTRL_INJECT);
    return 0;
}

int pnm_pi_open(const char *sysfs_dir)
{
    return pnm_pi_open_at(&default_card, sysfs_dir);
}

void pnm_pi_close(void)
{
    pnm_pi_close_at(&default_card);
}

uint32_t pnm_pi_reg_read(unsigned offset)
{
    return pnm_pi_reg_read_at(&default_card, offset);
}

void pnm_pi_reg_write(unsigned offset, uint32_t value)
{
    pnm_pi_reg_write_at(&default_card, offset, value);
}

int pnm_pi_boot_done(void)
{
    return pnm_pi_boot_done_at(&default_card);
}

uint32_t pnm_pi_dispatch_count(void)
{
    return pnm_pi_dispatch_count_at(&default_card);
}

int pnm_pi_inject(uint8_t layer, uint8_t module,
                  const uint8_t *payload, uint16_t len)
{
    return pnm_pi_inject_at(&default_card, layer, module, payload, len);
}

#ifdef PNM_PI_DEMO
int main(int argc, char **argv)
{
    const char *dir = (argc > 1) ? argv[1]
                                 : "/sys/bus/pci/devices/0001:01:00.0";
    static const uint8_t msg[] = {0xAA, 0x55};

    if (pnm_pi_open(dir) != 0)
        return 1;

    printf("PNM dispatches before boot signal: %u\n", pnm_pi_dispatch_count());
    pnm_pi_boot_done();
    printf("boot_done signalled\n");

    pnm_pi_inject(1, 5, msg, sizeof(msg));
    printf("flit injected: layer=%u module=%u len=%u\n",
           1u, 5u, (unsigned)sizeof(msg));

    pnm_pi_close();
    return 0;
}
#endif /* PNM_PI_DEMO */
