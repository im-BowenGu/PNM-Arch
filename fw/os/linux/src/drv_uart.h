/**
 * drv_uart.h — 16550 UART driver for orchestrator_sbc bare-metal init.
 *
 * Register map matches HDL/uart.v (simplified 16550):
 *   0x00 THR/RDR, 0x04 IER, 0x08 FCR/IIR, 0x0C LCR,
 *   0x10 MCR, 0x14 LSR
 */

#ifndef DRV_UART_H
#define DRV_UART_H

#include <stdint.h>

#define UART_BASE       0x10000000u

/* Register shift. The chip's UART (HDL/uart.v) decodes cpu_addr[7:2], i.e.
 * the 16550 registers are 32-bit aligned (shift 2). A host whose 16550 is
 * byte aligned (QEMU's riscv virt machine, reg-shift 1) needs shift 1:
 * build with -DPNM_UART_REG_SHIFT=1. */
#ifndef PNM_UART_REG_SHIFT
#define PNM_UART_REG_SHIFT 2
#endif

#define UART_REG(off)   ((off) << PNM_UART_REG_SHIFT)

#define UART_THR        UART_REG(0x00)
#define UART_IER        UART_REG(0x01)
#define UART_FCR_IIR    UART_REG(0x02)
#define UART_LCR        UART_REG(0x03)
#define UART_MCR        UART_REG(0x04)
#define UART_LSR        UART_REG(0x05)

#define UART_LSR_DR     0x01u   /* data ready */
#define UART_LSR_THRE   0x20u   /* TX holding register empty */

void uart_init(volatile uint32_t *base, uint32_t clk_freq, uint32_t baud);
void uart_putc(volatile uint32_t *base, char c);
int  uart_getc(volatile uint32_t *base);
int  uart_txFifoEmpty(volatile uint32_t *base);

#endif /* DRV_UART_H */
