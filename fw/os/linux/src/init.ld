/* init.ld — link script for the Linux init binary.
 *
 * The init binary is a flat (no-MMU) program: it runs from wherever the
 * kernel put it, so its link address has to be chosen, not guessed by the
 * toolchain default (riscv32-elf links at 0x10000, which is neither the
 * chip's SRAM window nor the QEMU RAM base).
 *
 * The base is a linker symbol so the same object can be linked for
 * different targets:
 *
 *   -Wl,--defsym=__base=0x40000000   the orchestrator_sbc SRAM window
 *   -Wl,--defsym=__base=0x80000000   DRAM / QEMU RAM base
 *
 * The stack lives 8 KB above the image (__stack_top = __base + 0x2000), so a
 * flat-memory harness only has to model the first 32 KB of the window.
 *
 * __base defaults to 0x40000000 in the Makefile.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
    . = __base;

    .text : {
        *(.text.init)
        *(.text .text.*)
    }

    .rodata : {
        *(.rodata .rodata.*)
    }

    .data : {
        *(.data .data.*)
    }

    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    }

    _end = .;

    /* the stack lives above the image, inside the same window */
    __stack_top = __base + 0x2000;
}
