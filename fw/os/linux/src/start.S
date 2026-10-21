/* start.S — freestanding entry stub for the Linux /init binary.
 *
 * The kernel enters /init with the stack pointer set up, but the binary is
 * also runnable stand-alone (as a flat program), where the reset stack
 * pointer is meaningless.  Set up a stack inside the binary's own window
 * (__stack_top, defined by the linker script) before calling main().
 */
    .section .text.init, "ax"
    .global _start
_start:
    la      sp, __stack_top
    /* set up a frame: 16 bytes of argument space + saved ra */
    addi    sp, sp, -16
    /* a0 = 0 (argc), a1 = 0 (argv) — main() takes no arguments */
    li      a0, 0
    li      a1, 0
    call    main
    /* main() never returns; park the CPU in a wfi loop if it does */
1:  wfi
    j       1b
