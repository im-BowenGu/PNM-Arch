/* div.S — the two integer-division helpers the freestanding init binary needs.
 *
 * The init binary is linked with -nostdlib (no libc, no start files) and the
 * toolchain's libgcc is built for a different ABI, so the helpers the UART
 * divisor computation calls are provided here.  rv32i, soft-float, no M
 * extension: a plain bitwise restoring division.
 */
    .section .text

/* unsigned int __udivsi3(unsigned int a, unsigned int b) */
    .global __udivsi3
    .type __udivsi3, @function
__udivsi3:
    li      t0, 0              /* quotient */
    li      t1, 1              /* bit mask */
    li      t2, 0              /* remainder */
1:
    andi    t3, a0, 1
    slli    t2, t2, 1
    or      t2, t2, t3
    slli    t1, t1, 1
    srli    a0, a0, 1
    bltu    t2, a1, 2f
    sub     t2, t2, a1
    or      t0, t0, t1
2:
    bnez    a0, 1b
    mv      a0, t0
    ret
    .size __udivsi3, .-__udivsi3

/* unsigned int __umodsi3(unsigned int a, unsigned int b) */
    .global __umodsi3
    .type __umodsi3, @function
__umodsi3:
    li      t1, 1              /* bit mask */
    li      t2, 0              /* remainder */
1:
    andi    t3, a0, 1
    slli    t2, t2, 1
    or      t2, t2, t3
    slli    t1, t1, 1
    srli    a0, a0, 1
    bltu    t2, a1, 2f
    sub     t2, t2, a1
2:
    bnez    a0, 1b
    mv      a0, t2
    ret
    .size __umodsi3, .-__umodsi3
