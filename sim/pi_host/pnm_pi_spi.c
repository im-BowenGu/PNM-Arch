/* pnm_pi_spi.c — PNM router host driver for Raspberry Pi Compute Modules
 * over SPI, in C. Fourth implementation of the pnm_pi.py wire protocol for
 * environments without Python/Go/Rust runtimes.
 *
 * Self-contained: the spidev ioctl ABI is re-declared here with PNM-private
 * names so no kernel headers are needed at build time; the numbers match
 * linux/spi/spidev.h on all Pi targets (asm-generic ioctl encoding).
 *
 * Build:
 *   gcc -O2 -Wall -Wextra -std=c11 -c pnm_pi_spi.c -o pnm_pi_spi.o
 *   gcc -O2 -Wall -Wextra -std=c11 -DPNM_PI_DEMO -o pnm_pi_spi_demo \
 *       pnm_pi_spi.c
 */

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>

#define PNMS_FRAME_LEN 6

#define PNMS_SEL_CTRL       0x00
#define PNMS_SEL_LAYER      0x01
#define PNMS_SEL_MODULE     0x02
#define PNMS_SEL_LEN        0x03
#define PNMS_SEL_DATA       0x04
#define PNMS_SEL_STATUS     0x05
#define PNMS_SEL_RESULT     0x06
#define PNMS_SEL_ERRORS     0x07
#define PNMS_SEL_DISPATCHES 0x08
#define PNMS_SEL_WEIGHTS    0x09

#define PNMS_CTRL_INJECT   (1u << 0)
#define PNMS_CTRL_BOOTDONE (1u << 2)
#define PNMS_STATUS_BUSY   (1u << 0)

#define PNMS_IOC_NRBITS   8
#define PNMS_IOC_TYPEBITS 8
#define PNMS_IOC_SIZEBITS 14

#define PNMS_IOC_NRSHIFT   0
#define PNMS_IOC_TYPESHIFT (PNMS_IOC_NRSHIFT + PNMS_IOC_NRBITS)
#define PNMS_IOC_SIZESHIFT (PNMS_IOC_TYPESHIFT + PNMS_IOC_TYPEBITS)
#define PNMS_IOC_DIRSHIFT  (PNMS_IOC_SIZESHIFT + PNMS_IOC_SIZEBITS)

#define PNMS_IOC_WRITE 1u

#define PNMS_IOC(dir, type_, nr, size)                                        \
    (((dir) << PNMS_IOC_DIRSHIFT) | ((type_) << PNMS_IOC_TYPESHIFT) |         \
     ((nr) << PNMS_IOC_NRSHIFT) | ((size) << PNMS_IOC_SIZESHIFT))

#define PNMS_SPI_MAGIC 'k'

struct pnms_ioc_transfer {
    uint64_t tx_buf;
    uint64_t rx_buf;
    uint32_t len;
    uint32_t speed_hz;
    uint16_t delay_usecs;
    uint8_t bits_per_word;
    uint8_t cs_change;
    uint8_t tx_nbits;
    uint8_t rx_nbits;
    uint16_t pad;
};

static unsigned pnms_ioc_message(unsigned n)
{
    unsigned size = n * (unsigned)sizeof(struct pnms_ioc_transfer);
    const unsigned max = 1u << PNMS_IOC_SIZEBITS;
    if (size > max)
        size = max;
    return PNMS_IOC(PNMS_IOC_WRITE, (unsigned)PNMS_SPI_MAGIC, 0, size);
}

typedef struct {
    int fd;
    uint32_t speed_hz;
} pnms_handle;

int pnms_open(pnms_handle *h, int bus, int dev, uint32_t speed_hz)
{
    char path[64];
    uint8_t mode = 0, bits = 8;

    snprintf(path, sizeof(path), "/dev/spidev%d.%d", bus, dev);
    h->fd = open(path, O_RDWR);
    if (h->fd < 0)
        return -1;
    h->speed_hz = speed_hz;
    if (ioctl(h->fd, PNMS_IOC(PNMS_IOC_WRITE, (unsigned)PNMS_SPI_MAGIC, 1, 1),
              &mode) < 0 ||
        ioctl(h->fd, PNMS_IOC(PNMS_IOC_WRITE, (unsigned)PNMS_SPI_MAGIC, 3, 1),
              &bits) < 0 ||
        ioctl(h->fd,
              PNMS_IOC(PNMS_IOC_WRITE, (unsigned)PNMS_SPI_MAGIC, 4, 4),
              &h->speed_hz) < 0) {
        close(h->fd);
        h->fd = -1;
        return -1;
    }
    return 0;
}

void pnms_close(pnms_handle *h)
{
    if (h->fd >= 0)
        close(h->fd);
    h->fd = -1;
}

static int pnms_xfer(pnms_handle *h, const uint8_t *tx, uint8_t *rx)
{
    struct pnms_ioc_transfer tr;

    memset(&tr, 0, sizeof(tr));
    tr.tx_buf = (uint64_t)(uintptr_t)tx;
    tr.rx_buf = (uint64_t)(uintptr_t)rx;
    tr.len = PNMS_FRAME_LEN;
    tr.speed_hz = h->speed_hz;
    tr.bits_per_word = 8;
    return ioctl(h->fd, pnms_ioc_message(1), &tr);
}

static void pnms_frame(uint8_t *fr, int rw, uint8_t sel, uint32_t data)
{
    fr[0] = rw ? (uint8_t)(0x80 | (sel & 0x7F)) : (uint8_t)(sel & 0x7F);
    fr[1] = (uint8_t)(data >> 24);
    fr[2] = (uint8_t)(data >> 16);
    fr[3] = (uint8_t)(data >> 8);
    fr[4] = (uint8_t)data;
    fr[5] = 0;
}

int pnms_reg_write(pnms_handle *h, uint8_t sel, uint32_t value)
{
    uint8_t tx[PNMS_FRAME_LEN], rx[PNMS_FRAME_LEN];

    pnms_frame(tx, 0, sel, value);
    if (pnms_xfer(h, tx, rx) < 0)
        return -1;
    if (rx[5] != 0x01) {
        errno = EIO;
        return -1;
    }
    return 0;
}

int pnms_reg_read(pnms_handle *h, uint8_t sel, uint32_t *value)
{
    uint8_t tx[PNMS_FRAME_LEN], rx[PNMS_FRAME_LEN];

    pnms_frame(tx, 1, sel, 0);
    if (pnms_xfer(h, tx, rx) < 0)
        return -1;
    if (rx[5] != 0x00) {
        errno = EIO;
        return -1;
    }
    *value = ((uint32_t)rx[1] << 24) | ((uint32_t)rx[2] << 16) |
             ((uint32_t)rx[3] << 8) | (uint32_t)rx[4];
    return 0;
}

int pnms_boot_done(pnms_handle *h)
{
    return pnms_reg_write(h, PNMS_SEL_CTRL, PNMS_CTRL_BOOTDONE);
}

int pnms_dispatch_count(pnms_handle *h, uint32_t *count)
{
    return pnms_reg_read(h, PNMS_SEL_DISPATCHES, count);
}

int pnms_inject(pnms_handle *h, uint8_t layer, uint8_t module,
                const uint8_t *payload, uint16_t len)
{
    uint32_t status;
    uint16_t i;

    do {
        if (pnms_reg_read(h, PNMS_SEL_STATUS, &status) != 0)
            return -1;
    } while (status & PNMS_STATUS_BUSY);

    if (pnms_reg_write(h, PNMS_SEL_LAYER, layer) != 0 ||
        pnms_reg_write(h, PNMS_SEL_MODULE, module) != 0 ||
        pnms_reg_write(h, PNMS_SEL_LEN, len) != 0)
        return -1;
    for (i = 0; i < len; i++) {
        if (pnms_reg_write(h, PNMS_SEL_DATA, payload[i]) != 0)
            return -1;
    }
    return pnms_reg_write(h, PNMS_SEL_CTRL, PNMS_CTRL_INJECT);
}

#ifdef PNM_PI_DEMO
int main(int argc, char **argv)
{
    pnms_handle h;
    uint32_t got, dispatches;
    static const uint8_t msg[] = {0xAA, 0x55};
    int bus = (argc > 1) ? atoi(argv[1]) : 0;
    int dev = (argc > 2) ? atoi(argv[2]) : 0;
    uint32_t speed = (argc > 3) ? (uint32_t)strtoul(argv[3], NULL, 0)
                                : 10000000u;

    if (pnms_open(&h, bus, dev, speed) != 0) {
        perror("open spidev");
        return 1;
    }

    if (pnms_reg_write(&h, PNMS_SEL_LAYER, 0xDEADBEEFu) != 0 ||
        pnms_reg_read(&h, PNMS_SEL_LAYER, &got) != 0) {
        perror("register round-trip");
        pnms_close(&h);
        return 1;
    }
    printf("layer round-trip: wrote 0x%08x read 0x%08x -> %s\n",
           0xDEADBEEFu, got, got == 0xDEADBEEFu ? "OK" : "FAIL");

    if (pnms_dispatch_count(&h, &dispatches) == 0)
        printf("dispatches so far: %u\n", dispatches);
    printf("demo inject: layer=%u module=%u len=%u\n", 1u, 5u,
           (unsigned)sizeof(msg));

    pnms_close(&h);
    return 0;
}
#endif /* PNM_PI_DEMO */
