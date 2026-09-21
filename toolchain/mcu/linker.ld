/* =============================================================================
 * linker.ld — MCU bare-metal memory layout for orchestrator_mcu
 *
 * Boot ROM: 0x0000_0000 .. 0x0000_1FFF (8KB)
 * SRAM:     0x8000_0000 .. 0x8000_0FFF (4KB)
 *
 * .text and .rodata live in ROM; .data and .bss are placed in SRAM.
 * The startup code copies .data from ROM load address to SRAM virtual
 * address (typical bare-metal pattern) and zeroes .bss.
 * ========================================================================== */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 8K
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 4K
}

SECTIONS
{
    .text : {
        KEEP(*(.text.start))
        *(.text*)
    } > ROM

    .rodata : {
        *(.rodata*)
        *(.srodata*)
    } > ROM

    /* Runtime address in SRAM; load image in ROM */
    .data ORIGIN(RAM) : AT(LOADADDR(.rodata) + SIZEOF(.rodata)) {
        _sdata = .;
        *(.data*)
        *(.sdata*)
        _edata = .;
    } > RAM

    _sidata = LOADADDR(.data);

    .bss (NOLOAD) : {
        _sbss = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        _ebss = .;
    } > RAM

    /* Stack grows down from top of SRAM */
    _stack_top = ORIGIN(RAM) + LENGTH(RAM);

    /DISCARD/ : {
        *(.eh_frame)
        *(.eh_frame_hdr)
        *(.comment)
        *(.note*)
    }
}
