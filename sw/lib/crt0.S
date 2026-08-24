/* ===========================================================================
 *  crt0.S -- minimal bare-metal startup for a PE of the coherent SoC.
 *
 *  Runs from the local ITCM. Sets up gp and the stack, clears .bss, calls
 *  main(), then reports the return value through the uncached control region
 *  so the testbench can end the simulation.
 * ======================================================================== */

    .section .text.init, "ax"
    .globl _start
    .type  _start, @function

_start:
    /* global pointer, without letting the linker relax the la itself */
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop

    /* one private stack per hart, carved out of the top of the ITCM */
    la      t0, _stack_top
    csrr    t1, mhartid
    slli    t1, t1, 12                  /* 4 KiB per hart */
    sub     sp, t0, t1

    /* clear .bss */
    la      a0, _sbss
    la      a1, _ebss
1:  bgeu    a0, a1, 2f
    sw      zero, 0(a0)
    addi    a0, a0, 4
    j       1b
2:

    /* argc = 0, argv = NULL */
    li      a0, 0
    li      a1, 0
    call    main

    /* exit(code): a non-zero word at TOHOST ends the simulation */
    li      t0, 0x80000000
    addi    a0, a0, 1                   /* main()==0 -> tohost 1 -> success */
    sw      a0, 0(t0)

3:  wfi
    j       3b
    .size _start, .-_start
