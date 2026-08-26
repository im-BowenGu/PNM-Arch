/**
 * drv_uart.h — 16550 UART driver for router_sbc bare-metal init.
 *
 * Register map matches HDL/uart.v (simplified 16550):
 *   0x00 THR/RDR, 0x04 IER, 0x08 FCR/IIR, 0x0C LCR,
 *   0x10 MCR, 0x14 LSR
 */

#ifndef DRV_UART_H
#define DRV_UART_H

#include <stdint.h>

#define UART_BASE       0x10000000u

#define UART_THR        0x00
#define UART_IER        0x04
#define UART_FCR_IIR    0x08
#define UART_LCR        0x0C
#define UART_MCR        0x10
#define UART_LSR        0x14

#define UART_LSR_DR     0x01u   /* data ready */
#define UART_LSR_THRE   0x20u   /* TX holding register empty */

void uart_init(volatile uint32_t *base, uint32_t clk_freq, uint32_t baud);
void uart_putc(volatile uint32_t *base, char c);
int  uart_getc(volatile uint32_t *base);
int  uart_txFifoEmpty(volatile uint32_t *base);

#endif /* DRV_UART_H */
