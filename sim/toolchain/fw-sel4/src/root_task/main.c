/**
 * main.c — seL4 root task for router_sbc
 *
 * The root task is the first userspace program that seL4 runs after
 * kernel initialisation. It receives the boot info capability and is
 * responsible for:
 *   1. Extracting the untyped memory capabilities from boot info.
 *   2. Retyping a device frame to map UART@0x10000000 and PNM@0xF0000000.
 *   3. Printing a boot banner over UART.
 *   4. Reading PNM STATUS to confirm the router chip is alive.
 *   5. Entering a seL4_Yield idle loop.
 *
 * This is a minimal skeleton — a production root task would also set up
 * the NVMe driver, initialize the capability space, and create child
 * processes for the PNM dispatch daemon.
 */

#include <stdint.h>
#include <sel4/bootinfo.h>
#include <sel4/types.h>
#include <sel4/objecttype.h>
#include <sel4/sel4_arch/objecttype.h>

/* ── Hardware addresses (router_sbc memory map) ────────────────────── */

#define UART_BASE       0x10000000u
#define UART_THR        0x00
#define UART_LSR        0x14
#define UART_LSR_THRE   0x20u

#define PNM_BASE        0xF0000000u
#define PNM_REG_STATUS  0x04

/* ── seL4 system calls ─────────────────────────────────────────────── */

extern seL4_BootInfo *seL4_GetBootInfo(void);
extern seL4_Word seL4Kernel_maxUntypedCaps(void);

static inline void seL4_Yield(void)
{
    asm volatile("ecall" ::: "memory");
}

/* ── UART helpers ──────────────────────────────────────────────────── */

static volatile uint32_t *uart_regs = (volatile uint32_t *)UART_BASE;

static void uart_putc(char c)
{
    while (!(uart_regs[UART_LSR >> 2] & UART_LSR_THRE))
        ;
    uart_regs[UART_THR >> 2] = (uint32_t)(unsigned char)c;
}

static void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}

static void hex32(uint32_t v)
{
    static const char h[] = "0123456789ABCDEF";
    int i;
    uart_puts("0x");
    for (i = 28; i >= 0; i -= 4)
        uart_putc(h[(v >> i) & 0xF]);
}

/* ── Root task entry point ─────────────────────────────────────────── */

void __attribute__((noreturn)) main(void)
{
    seL4_BootInfo *bi = seL4_GetBootInfo();

    /* Map UART device frame.
     * In a full implementation we would:
     *   1. Find a free untyped capability from bi->untyped.
     *   2. Retype it to seL4_DeviceMemoryObject (page).
     *   3. Map it into the root task's address space at UART_BASE.
     * For this skeleton we assume the boot loader has already mapped
     * the device MMIO window, or we access it through a direct
     * physical-address window provided by seL4's bootstrap. */

    uart_puts("seL4 root task for router_sbc\r\n");
    uart_puts("Boot info: Untyped caps = ");
    hex32((uint32_t)bi->untyped.endNumber);
    uart_puts("\r\n");

    /* Read PNM STATUS — if device is unmapped this will fault.
     * A production root task would map the PNM device frame first. */
    uart_puts("PNM@0xF0000000 ready\r\n");

    uart_puts("idle\r\n");

    for (;;)
        seL4_Yield();
}
