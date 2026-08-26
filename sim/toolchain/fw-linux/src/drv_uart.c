/**
 * drv_uart.c — 16550 UART driver for router_sbc bare-metal init.
 */

#include "drv_uart.h"

void uart_init(volatile uint32_t *base, uint32_t clk_freq, uint32_t baud)
{
    uint32_t divisor = clk_freq / baud;
    base[UART_LCR >> 2] = 0x80;          /* enable divisor latch */
    base[UART_THR >> 2] = divisor & 0xFF;
    base[UART_IER >> 2] = (divisor >> 8) & 0xFF;
    base[UART_LCR >> 2] = 0x03;          /* 8N1, disable latch */
    base[UART_FCR_IIR >> 2] = 0x07;      /* enable & reset FIFOs */
}

void uart_putc(volatile uint32_t *base, char c)
{
    while (!(base[UART_LSR >> 2] & UART_LSR_THRE))
        ;
    base[UART_THR >> 2] = (uint32_t)(unsigned char)c;
}

int uart_getc(volatile uint32_t *base)
{
    while (!(base[UART_LSR >> 2] & UART_LSR_DR))
        ;
    return (int)(base[UART_THR >> 2] & 0xFF);
}

int uart_txFifoEmpty(volatile uint32_t *base)
{
    return (base[UART_LSR >> 2] & UART_LSR_THRE) != 0;
}
