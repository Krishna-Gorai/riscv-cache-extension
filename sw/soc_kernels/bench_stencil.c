/* ===========================================================================
 *  bench_stencil.c -- a halo-exchange stencil, for the partial-sharing regime.
 *
 *  Every other kernel here partitions its data per PE and shares nothing, so
 *  every invalidation broadcast finds no copy anywhere and a filter that
 *  suppresses the empty case removes all of the traffic. That is a real
 *  measurement, but it is one point on an axis: it says what happens when the
 *  sharer set is always empty, and nothing about what happens when it is small
 *  but not empty.
 *
 *  This kernel occupies that middle. A Jacobi 5-point stencil, double
 *  buffered, with the grid split into row bands. PE p computes rows [lo, hi)
 *  of the destination from rows [lo-1, hi] of the source, so the two rows on
 *  each band boundary are read by one PE and written by its neighbour. On a
 *  four-PE cluster that makes the sharer set for a boundary line exactly one
 *  of the three other caches, and empty for every interior line.
 *
 *  That is the case that separates suppression from direction. A filter that
 *  only answers "is the sharer set empty" must fall back to a full broadcast
 *  and a four-way barrier for every boundary line, even though exactly one
 *  cache needs to hear it. Directed invalidation sends it to that one cache
 *  and waits only on that one.
 *
 *  Double buffering is what makes the sharing recur rather than happen once.
 *  Buffers alternate, so the line PE p caches from buffer B at step t+1 is
 *  rewritten by PE p-1 at step t+2, and the halo is genuinely exchanged on a
 *  two-step period for the whole run.
 *
 *  All values stay in [0, 250]: the interior is an average of non-negative
 *  neighbours and the border is copied unchanged from an initialisation that
 *  is already in range. Nothing here depends on how a signed right shift
 *  behaves, so the C and the Python model in scripts/bench_golden.py cannot
 *  disagree about it.
 * ======================================================================== */

#include "bench.h"

/* Grid edge and step count both come from the build, like every other kernel
 * here, so one source builds each point of the sweep:
 *   KCFLAGS="-DBENCH_N=32 -DBENCH_T=8 -DBENCH_GOLDEN=0x...u" OUT_SUFFIX=_32 ./build.sh ...
 *
 * The default 32x32 is chosen against the cache, not for neatness: a PE's
 * working set is its band plus two halo rows, which at 32 words per row is
 * 10 rows of 128 bytes = 1280 B inside a 2 KiB two-way DCU. Widening the grid
 * without widening the cache turns this into a capacity benchmark instead of a
 * sharing one, and the halo lines stop being resident when the neighbour
 * writes them -- which is the whole effect being measured. */
#ifndef BENCH_N
#define BENCH_N      32u
#endif
#ifndef BENCH_T
#define BENCH_T       8u
#endif
#ifndef BENCH_GOLDEN
#define BENCH_GOLDEN 0u
#endif

#define H        BENCH_N
#define W        BENCH_N
#define T        BENCH_T
#define A_OFF    0x0000u
#define B_OFF    (H * W * 4u)           /* the second buffer, straight after  */

#define GOLDEN   BENCH_GOLDEN

int main(void) {
    volatile uint32_t *bufa = shared_ptr(A_OFF);
    volatile uint32_t *bufb = shared_ptr(B_OFF);

    uint32_t id  = hart_id();
    uint32_t npe = NUM_PES;
    uint32_t lo, hi, t0, t1;
    uint32_t tot0 = 0;

    bench_range(H, id, npe, &lo, &hi);   /* the rows this PE owns */

    /* Seed only our own band. The other buffer needs no initialisation: step 0
     * writes every row of it before anything reads it. */
    for (uint32_t y = lo; y < hi; y++)
        for (uint32_t x = 0; x < W; x++)
            bufa[y * W + x] = (y * W + x) % 251u;
    barrier();

    volatile uint32_t *src = bufa;
    volatile uint32_t *dst = bufb;

    if (id == 0) tot0 = CYCLE_LO;
    t0 = CYCLE_LO;
    for (uint32_t t = 0; t < T; t++) {
        for (uint32_t y = lo; y < hi; y++) {
            for (uint32_t x = 0; x < W; x++) {
                if (y == 0u || y == (H - 1u) || x == 0u || x == (W - 1u)) {
                    /* fixed border, carried forward unchanged */
                    dst[y * W + x] = src[y * W + x];
                } else {
                    /* the two vertical taps are the halo: at y == lo the row
                     * above belongs to PE id-1, and at y == hi-1 the row below
                     * belongs to PE id+1 */
                    dst[y * W + x] = (src[(y - 1u) * W + x]
                                    + src[(y + 1u) * W + x]
                                    + src[y * W + x - 1u]
                                    + src[y * W + x + 1u]) >> 2;
                }
            }
        }
        /* Every PE must finish writing dst before anybody reads it as src. */
        barrier();
        {
            volatile uint32_t *tmp = src;
            src = dst;
            dst = tmp;
        }
    }
    t1 = CYCLE_LO;

    bench_report(id, t1 - t0);
    barrier();

    if (id == 0) {
        /* After T swaps the answer is in A for even T and in B for odd T. */
        uint32_t res_off = ((T & 1u) == 0u) ? A_OFF : B_OFF;
        bench_publish(npe, CYCLE_LO - tot0, res_off, H * W, GOLDEN);
        puts_("stencil: ");   putdec(H);
        putch('x');           putdec(W);
        puts_(" steps=");     putdec(T);
        puts_(" cycles=");    putdec(t1 - t0);
        putch('\n');
    }
    return 0;
}
