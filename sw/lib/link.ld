/* ===========================================================================
 *  link.ld -- memory layout of one Processing Element.
 *
 *  Code and PE-private data live in the local ITCM, so nothing has to be
 *  copied at start-up. The coherent shared data memory is reserved for the
 *  data the cores actually share, which is what the DCU hit-rate counters are
 *  meant to measure.
 * ======================================================================== */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    ITCM  (rwx) : ORIGIN = 0x00000000, LENGTH = 32K
    SDMEM (rw)  : ORIGIN = 0x10000000, LENGTH = 256K
}

SECTIONS
{
    .text : {
        KEEP(*(.text.init))
        *(.text .text.*)
    } > ITCM

    .rodata : {
        . = ALIGN(4);
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    } > ITCM

    .data : {
        . = ALIGN(4);
        *(.data .data.*)
        . = ALIGN(8);
        __global_pointer$ = . + 0x800;
        *(.sdata .sdata.*)
    } > ITCM

    .bss (NOLOAD) : {
        . = ALIGN(4);
        _sbss = .;
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    } > ITCM

    _stack_top = ORIGIN(ITCM) + LENGTH(ITCM);

    /* Shared data lives in the coherent memory and is never part of the image;
       anything placed here is reached through the DCU. */
    .shared (NOLOAD) : {
        . = ALIGN(64);
        _shared_start = .;
        *(.shared .shared.*)
        _shared_end = .;
    } > SDMEM

    /DISCARD/ : { *(.comment) *(.eh_frame) *(.riscv.attributes) }
}
