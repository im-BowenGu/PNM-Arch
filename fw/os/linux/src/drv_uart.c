/**
 * drv_uart.c — 16550 UART driver for orchestrator_sbc bare-metal init.
 *
 * The 16550 register file is *byte* wide (THR, IER, FCR, LCR, MCR, LSR are
 * 8-bit registers), so every access below is a byte store. A 32-bit store to
 * the UART base would write the character into THR *and* spill into IER,
 * FCR and LCR — which our RTL tolerates (it decodes one register per word)
 * but a real 16550 does not: the character ends up in the wrong register and
 * the line control is clobbered by the character value.
 */

#include "drv_uart.h"

/* Register access width follows the bus the UART sits on:
 *  - shift 2 (the chip, HDL/uart.v decodes cpu_addr[7:2]): the registers are
 *    32-bit aligned and are written as words;
 *  - shift 1 (a byte-aligned 16550, e.g. QEMU's riscv virt machine): the
 *    registers are 8-bit and must be written as bytes, or a word write
 *    spills the character into the neighbouring registers.
 */
#if PNM_UART_REG_SHIFT == 2
static inline void uart_out(volatile uint32_t *base, unsigned off, uint8_t v)
{
    base[off >> 2] = (uint32_t)v;
}

static inline uint8_t uart_in(volatile uint32_t *base, unsigned off)
{
    return (uint8_t)base[off >> 2];
}
#else
static inline void uart_out(volatile uint32_t *base, unsigned off, uint8_t v)
{
    *(volatile uint8_t *)((volatile uint8_t *)base + off) = v;
}

static inline uint8_t uart_in(volatile uint32_t *base, unsigned off)
{
    return *(volatile uint8_t *)((volatile uint8_t *)base + off);
}
#endif

void uart_init(volatile uint32_t *base, uint32_t clk_freq, uint32_t baud)
{
    /* 16550 divisor = clock / (16 * baud) */
    uint32_t divisor = clk_freq / (16u * baud);
    if (divisor == 0)
        divisor = 1;
    uart_out(base, UART_LCR, 0x80);       /* enable the divisor latch */
    uart_out(base, UART_THR, (uint8_t)(divisor & 0xFF));   /* DLL */
    uart_out(base, UART_IER, (uint8_t)((divisor >> 8) & 0xFF)); /* DLM */
    uart_out(base, UART_LCR, 0x03);       /* 8N1, divisor latch off */
    uart_out(base, UART_FCR_IIR, 0x07);   /* enable & reset the FIFOs */
}

void uart_putc(volatile uint32_t *base, char c)
{
    while (!(uart_in(base, UART_LSR) & UART_LSR_THRE))
        ;
    uart_out(base, UART_THR, (uint8_t)c);
}

int uart_getc(volatile uint32_t *base)
{
    while (!(uart_in(base, UART_LSR) & UART_LSR_DR))
        ;
    return (int)uart_in(base, UART_THR);
}

int uart_txFifoEmpty(volatile uint32_t *base)
{
    return (uart_in(base, UART_LSR) & UART_LSR_THRE) != 0;
}
