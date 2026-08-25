/* ===========================================================================
 *  crt0_soc.S -- start-up for a PE of the multi-core SoC.
 *
 *  All PEs boot out of the shared scratchpad instruction memory, as Section
 *  IV-A describes. The stub below runs in place there and performs the
 *  instruction transfer of Section III-B: it reads the code image through the
 *  Data-Bridge and writes it into this PE's private ITCM, then jumps into the
 *  ITCM copy and never touches the shared instruction memory again.
 *
 *  That transfer is what keeps the evaluation honest. If every PE kept fetching
 *  from the one shared instruction memory, four cores would spend most of their
 *  cycles arbitrating for instructions and the data-cache comparison would be
 *  measuring the wrong bottleneck.
 * ======================================================================== */

    .section .text.boot, "ax"
    .globl _start
    .type  _start, @function

_start:
    /* --- copy .text/.rodata/.data from the shared instruction memory ------ */
    la      t0, _itcm_lma               /* source, inside SIMEM              */
    la      t1, _itcm_vma               /* destination, this PE's ITCM       */
    la      t2, _itcm_vma_end
1:  bgeu    t1, t2, 2f
    lw      t3, 0(t0)
    sw      t3, 0(t1)
    addi    t0, t0, 4
    addi    t1, t1, 4
    j       1b
2:
    /* Read the last written word back before fetching from the ITCM: the load
       cannot retire until the store ahead of it has, which orders the transfer
       against the jump. */
    lw      t3, -4(t1)

    la      t0, _start_itcm
    jr      t0
    .size _start, .-_start

/* ---------------------------------------------------------------------------
 *  From here on the PE executes out of its own ITCM.
 * ------------------------------------------------------------------------ */
    .section .text.init, "ax"
    .globl _start_itcm
    .type  _start_itcm, @function

_start_itcm:
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop

    /* Each PE owns its ITCM outright, so every stack starts at its own top. */
    la      sp, _stack_top

    /* clear .bss */
    la      a0, _sbss
    la      a1, _ebss
1:  bgeu    a0, a1, 2f
    sw      zero, 0(a0)
    addi    a0, a0, 4
    j       1b
2:

    li      a0, 0
    li      a1, 0
    call    main

    /* exit(code): a non-zero word at TOHOST marks this PE finished */
    li      t0, 0x80000000
    addi    a0, a0, 1                   /* main()==0 -> tohost 1 -> success */
    sw      a0, 0(t0)

3:  wfi
    j       3b
    .size _start_itcm, .-_start_itcm
