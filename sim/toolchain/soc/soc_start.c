/* soc_start.c — SoC userspace entry point
 *
 * Under NOMMU Linux the kernel jumps directly to the ELF entry with a
 * valid stack already set up. No .data copy or .bss zeroing is needed
 * (the kernel loader does it). We provide _soc_start as the entry symbol
 * that calls main().
 */

extern int main(int argc, char **argv);

void __attribute__((section(".text.socstart"), noreturn))
_soc_start(void) {
    __asm__ volatile (
        "la sp, _stack_top\n"
        "mv a0, zero\n"       /* argc */
        "mv a1, zero\n"       /* argv */
        "call main\n"
        "ebreak\n"
    );
    __builtin_unreachable();
}
