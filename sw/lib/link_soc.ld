/* ===========================================================================
 *  link_soc.ld -- memory layout of a PE inside the multi-core SoC.
 *
 *  Section IV-A: the shared scratchpad instruction memory is the boot memory
 *  for all PEs. So the whole image is loaded there, and each PE copies the
 *  part it will execute into its own private ITCM at start-up -- the
 *  instruction transfer through the Data-Bridge described in Section III-B.
 *
 *  Load view (what ends up in the shared instruction memory .hex):
 *      0x20000000  .boot            the copy loop, executed in place
 *                  .text            \
 *                  .rodata          |  loaded here, run from the ITCM
 *                  .data            /
 *
 *  Run view:
 *      0x00000000  .text .rodata .data .bss   private ITCM, one per PE
 *      0x10000000  .shared                    coherent shared data memory
 * ======================================================================== */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    ITCM  (rwx) : ORIGIN = 0x00000000, LENGTH = 32K
    SDMEM (rw)  : ORIGIN = 0x10000000, LENGTH = 256K
    SIMEM (rx)  : ORIGIN = 0x20000000, LENGTH = 32K
}

SECTIONS
{
    /* The boot stub runs in place, out of the shared instruction memory. */
    .boot : {
        KEEP(*(.text.boot))
        . = ALIGN(4);
    } > SIMEM

    /* Everything below runs from the ITCM but is loaded into SIMEM. */
    .text : {
        _itcm_vma = .;
        KEEP(*(.text.init))
        *(.text .text.*)
    } > ITCM AT> SIMEM

    .rodata : {
        . = ALIGN(4);
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    } > ITCM AT> SIMEM

    .data : {
        . = ALIGN(4);
        *(.data .data.*)
        . = ALIGN(8);
        __global_pointer$ = . + 0x800;
        *(.sdata .sdata.*)
        . = ALIGN(4);
        _itcm_vma_end = .;
    } > ITCM AT> SIMEM

    /* Where that ITCM image sits inside the shared instruction memory. */
    _itcm_lma = LOADADDR(.text);

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

    /* Shared data is never part of any image; it is reached through the DCU. */
    .shared (NOLOAD) : {
        . = ALIGN(64);
        _shared_start = .;
        *(.shared .shared.*)
        _shared_end = .;
    } > SDMEM

    /DISCARD/ : { *(.comment) *(.eh_frame) *(.riscv.attributes) }
}
