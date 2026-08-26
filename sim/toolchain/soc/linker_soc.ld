/* =============================================================================
 * linker_soc.ld — SoC userspace layout for router_sbc / router_sbc_moe
 *
 * The boot ROM's second-stage loader places this ELF in DRAM starting at
 * 0x8000_1000 (after a 4KB page table / boot-info scratch area).
 *
 * Under NOMMU Linux/Redox there is no virtual memory remapping; the
 * linker must produce position-dependent code at fixed addresses because
 * fork() is unavailable and each program occupies one contiguous DRAM
 * region. This is standard Flat-Mode / XIP practice.
 * ========================================================================== */

OUTPUT_ARCH(riscv)

MEMORY
{
    DRAM (rwx) : ORIGIN = 0x80001000, LENGTH = 512M
}

ENTRY(_soc_start)

SECTIONS
{
    .text : {
        KEEP(*(.text.socstart))
        *(.text*)
    } > DRAM

    .rodata : {
        *(.rodata*)
        *(.srodata*)
    } > DRAM

    .data : {
        _sdata = .;
        *(.data*)
        *(.sdata*)
        _edata = .;
    } > DRAM

    .bss (NOLOAD) : {
        _sbss = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        _ebss = .;
    } > DRAM

    /* Heap grows up from end of bss; stack grows down from top of DRAM */
    _heap_start = ALIGN(_ebss, 16);
    _stack_top  = ORIGIN(DRAM) + LENGTH(DRAM);

    /DISCARD/ : {
        *(.eh_frame)
        *(.comment)
    }
}
