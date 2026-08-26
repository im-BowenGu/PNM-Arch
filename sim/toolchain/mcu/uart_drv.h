/* uart_drv.h — minimal polled UART driver for router_mcu / router_sbc */

#ifndef UART_DRV_H
#define UART_DRV_H

#include <stdint.h>

#define UART_BASE 0x10000000u

#define UART_THR (*(volatile uint32_t *)(UART_BASE + 0x00))
#define UART_LSR (*(volatile uint32_t *)(UART_BASE + 0x14))

#define UART_LSR_THRE (1u << 5)   /* transmit holding register empty */
#define UART_LSR_DR   (1u << 0)   /* data ready */

static inline void uart_putc(char c) {
    while (!(UART_LSR & UART_LSR_THRE)) {}
    UART_THR = (uint32_t)c;
}

static inline void uart_puts(const char *s) {
    while (*s) uart_putc(*s++);
}

static inline int uart_getc(void) {
    if (!(UART_LSR & UART_LSR_DR)) return -1;
    return (int)(UART_THR & 0xFF);
}

#endif /* UART_DRV_H */
