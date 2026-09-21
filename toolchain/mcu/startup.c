/* startup.c — bare-metal entry point for orchestrator_mcu
 *
 * Copies .data from ROM to SRAM, zeroes .bss, sets up stack pointer,
 * then calls main(). No libc, no constructors, no atexit.
 */

extern unsigned char _sidata, _sdata, _edata, _sbss, _ebss, _stack_top;

void main(void);

void _start(void) __attribute__((section(".text.start"), noreturn));

void _start(void) {
    unsigned char *src = &_sidata;
    unsigned char *dst = &_sdata;
    while (dst < &_edata) *dst++ = *src++;

    unsigned int *bss = (unsigned int *)&_sbss;
    while ((unsigned char *)bss < &_ebss) *bss++ = 0;

    __asm__ volatile (
        "la sp, _stack_top\n"
        "fence iorw, iorw\n"
    );

    main();
    for (;;) __asm__ volatile ("wfi");
}
