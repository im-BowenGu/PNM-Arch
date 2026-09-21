/**
 * init.c — Bare-metal init for fw-linux on orchestrator_sbc.
 *
 * This is the first userspace-like code that runs after the Linux
 * tinyconfig kernel boots the initramfs.  In the NOMMU flat-binary
 * configuration it receives control from the kernel's /init mechanism.
 *
 * Behaviour:
 *   1. Print boot banner over UART@0x10000000.
 *   2. Read PNM STATUS register at 0xF0000000 to confirm the router
 *      chip is alive (boot_done should be set).
 *   3. Probe NVMe controller at 0xD0000000 (read CAP, VS, CSTS).
 *   4. Print probe results.
 *   5. Enter an idle loop (wfi for power saving).
 */

#include <stdint.h>
#include "drv_uart.h"
#include "drv_pnm.h"
#include "drv_nvme.h"

#define UART_FREQ   100000000u
#define UART_BAUD   115200u

/* forward declarations */
static void banner(volatile uint32_t *uart);
static void hex32(volatile uint32_t *uart, uint32_t val);

int main(void)
{
    volatile uint32_t *uart = (volatile uint32_t *)UART_BASE;
    volatile uint32_t *pnm  = (volatile uint32_t *)PNM_BASE;

    uart_init(uart, UART_FREQ, UART_BAUD);
    banner(uart);

    /* Confirm router chip is alive */
    uint32_t sts = pnm_read(pnm, PNM_REG_STATUS);
    uart_putc(uart, 'P'); uart_putc(uart, 'N'); uart_putc(uart, 'M');
    uart_putc(uart, ' '); uart_putc(uart, 'S'); uart_putc(uart, 'T');
    uart_putc(uart, 'S'); uart_putc(uart, '=');
    hex32(uart, sts);
    uart_putc(uart, '\r'); uart_putc(uart, '\n');

    /* Probe NVMe */
    volatile uint32_t *nvme = (volatile uint32_t *)NVME_BASE;
    nvme_dev_t dev;
    int rc = nvme_init(&dev, nvme);

    uart_putc(uart, 'N'); uart_putc(uart, 'V');
    uart_putc(uart, 'M'); uart_putc(uart, 'E');
    uart_putc(uart, ' '); uart_putc(uart, 'C');
    uart_putc(uart, 'A'); uart_putc(uart, 'P');
    uart_putc(uart, '=');
    hex32(uart, nvme[NVME_REG_CAP >> 2]);
    uart_putc(uart, ' '); uart_putc(uart, 'V');
    uart_putc(uart, 'S'); uart_putc(uart, '=');
    hex32(uart, nvme[NVME_REG_VS >> 2]);
    uart_putc(uart, ' '); uart_putc(uart, 'R');
    uart_putc(uart, 'C'); uart_putc(uart, '=');
    hex32(uart, (uint32_t)rc);
    uart_putc(uart, '\r'); uart_putc(uart, '\n');

    uart_putc(uart, 'I'); uart_putc(uart, 'D');
    uart_putc(uart, 'L'); uart_putc(uart, 'E');
    uart_putc(uart, '\r'); uart_putc(uart, '\n');

    /* Idle loop — wfi powers down until next interrupt */
    for (;;)
        __asm__ volatile ("wfi");
}

static void banner(volatile uint32_t *uart)
{
    const char *msg = "fw-linux init for orchestrator_sbc\r\n";
    while (*msg)
        uart_putc(uart, *msg++);
}

static void hex32(volatile uint32_t *uart, uint32_t val)
{
    static const char hex[] = "0123456789ABCDEF";
    int i;
    uart_putc(uart, '0'); uart_putc(uart, 'x');
    for (i = 28; i >= 0; i -= 4)
        uart_putc(uart, hex[(val >> i) & 0xF]);
}
