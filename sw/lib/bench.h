/* ===========================================================================
 *  bench.h -- shared conventions for the M6 benchmark kernels.
 *
 *  Section IV-B of the paper compares the same kernel with and without the
 *  data-cache extension. Every kernel here therefore has to run unmodified on
 *  both builds of the SoC, and the testbench has to be able to score it
 *  without knowing which kernel it is running.
 *
 *  So a kernel publishes a fixed results block, and the TESTBENCH does the
 *  checking: it reads the result region the kernel names, computes the
 *  checksum below over it, and compares that against the golden constant the
 *  kernel also publishes. The kernel never verifies itself -- a kernel that
 *  computed the wrong answer would happily agree with its own wrong answer.
 *  The golden constants come from scripts/bench_golden.py, an independent
 *  Python model of each kernel.
 *
 *  Keeping the verification out of the kernel has a second benefit: no
 *  checking traffic pollutes the DCU hit-rate counters, so the numbers the
 *  harness reports are the kernel's own memory behaviour and nothing else.
 * ======================================================================== */
#ifndef BENCH_H
#define BENCH_H

#include "pe.h"

/* The results block. Well clear of any kernel's working buffers. */
#define BENCH_RES_OFF     0xF000u

/* Word indices inside the results block. Mirrored by tb/system/tb_bench.sv. */
#define BR_CYCLES         0u    /* [0..7]  per-PE cycles spent in the kernel  */
#define BR_STATUS         8u    /* [8..15] per-PE liveness, 1 = reached the end */
#define BR_RES_OFF        16u   /* byte offset of the result region           */
#define BR_RES_WORDS      17u   /* how many words the result region holds     */
#define BR_GOLDEN         18u   /* checksum the harness must compute over it  */
#define BR_SENTINEL       19u   /* BENCH_SENTINEL once PE0 has published      */
#define BR_TOTCYC         20u   /* wall-clock cycles, measured by PE0         */
#define BR_NPE            21u   /* PEs that took part                         */
#define BR_WORDS          24u   /* size of the block                          */

#define BENCH_SENTINEL    0x00C0FFEEu

/* The checksum. Position-sensitive on purpose: a kernel that computes every
 * right value but puts them in the wrong places must not pass. Duplicated in
 * scripts/bench_golden.py and in tb_bench.sv -- change all three together. */
static inline uint32_t bench_csum(const volatile uint32_t *p, uint32_t n) {
    uint32_t h = 0;
    for (uint32_t i = 0; i < n; i++) h = h * 31u + p[i];
    return h;
}

/* Split [0, n) across npe PEs. The last PE absorbs the remainder, so a count
 * that does not divide evenly still gets covered exactly once. */
static inline void bench_range(uint32_t n, uint32_t id, uint32_t npe,
                               uint32_t *lo, uint32_t *hi) {
    uint32_t span = (n + npe - 1u) / npe;
    uint32_t a    = span * id;
    uint32_t b    = a + span;
    if (a > n) a = n;
    if (b > n) b = n;
    *lo = a;
    *hi = b;
}

/* Called by every PE once its slice is done, then by PE0 to publish the meta
 * data the harness scores the run with. */
static inline void bench_report(uint32_t id, uint32_t cycles) {
    volatile uint32_t *res = shared_ptr(BENCH_RES_OFF);
    res[BR_CYCLES + id] = cycles;
    res[BR_STATUS + id] = 1u;
}

static inline void bench_publish(uint32_t npe, uint32_t total_cycles,
                                 uint32_t res_byte_off, uint32_t res_words,
                                 uint32_t golden) {
    volatile uint32_t *res = shared_ptr(BENCH_RES_OFF);
    res[BR_RES_OFF]   = res_byte_off;
    res[BR_RES_WORDS] = res_words;
    res[BR_GOLDEN]    = golden;
    res[BR_TOTCYC]    = total_cycles;
    res[BR_NPE]       = npe;
    res[BR_SENTINEL]  = BENCH_SENTINEL;
}

#endif /* BENCH_H */
