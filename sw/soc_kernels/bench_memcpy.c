/* ===========================================================================
 *  bench_memcpy.c -- Fig. 5: block copy through the shared data memory.
 *
 *  The streaming case. Nothing is re-read, so the only locality is inside a
 *  cache line: a line is filled by the first word touched and the next three
 *  words of that line then hit. With a 16-byte line that is a ceiling of 75%
 *  on reads, and the destination never hits at all, because write-through /
 *  no-allocate does not install a line on a store.
 *
 *  That is the point of including it. It is the kernel with the least reuse in
 *  the set, so whatever speedup it shows is the floor of what the extension
 *  buys, and it isolates line-fill bandwidth from genuine reuse.
 * ======================================================================== */

#include "bench.h"

/* Fig. 5 sweeps the transfer size over 4, 8, 16 and 32 KiB. Both the size and
 * the golden come from the build, so one source builds every point:
 *   KCFLAGS="-DBENCH_KIB=8 -DBENCH_GOLDEN=0x42D89C00u" OUT_SUFFIX=_8k ./build.sh ...
 * The defaults are the leftmost point of the figure. */
#ifndef BENCH_KIB
#define BENCH_KIB   4u
#endif
#ifndef BENCH_GOLDEN
#define BENCH_GOLDEN 0xF96C4E00u
#endif

#define N        (BENCH_KIB * 256u)     /* words copied                      */
#define SRC_OFF  0x0000u
#define DST_OFF  (BENCH_KIB * 1024u)    /* immediately after the source      */

#define GOLDEN   BENCH_GOLDEN

int main(void) {
    volatile uint32_t *src = shared_ptr(SRC_OFF);
    volatile uint32_t *dst = shared_ptr(DST_OFF);

    uint32_t id  = hart_id();
    uint32_t npe = NUM_PES;
    uint32_t lo, hi, t0, t1;
    uint32_t tot0 = 0;

    bench_range(N, id, npe, &lo, &hi);

    /* Each PE seeds its own slice. A serial init would leave three PEs holding
     * clean copies of lines PE0 is still writing, and the copy loop would then
     * be measuring the resulting invalidation storm instead of the copy. */
    for (uint32_t i = lo; i < hi; i++) src[i] = i * 7u + 1u;
    barrier();

    if (id == 0) tot0 = CYCLE_LO;
    t0 = CYCLE_LO;
    for (uint32_t i = lo; i < hi; i++) dst[i] = src[i];
    t1 = CYCLE_LO;

    bench_report(id, t1 - t0);
    barrier();

    if (id == 0) {
        bench_publish(npe, CYCLE_LO - tot0, DST_OFF, N, GOLDEN);
        puts_("memcpy: kib="); putdec(BENCH_KIB);
        puts_(" n=");         putdec(N);
        puts_(" cycles=");     putdec(t1 - t0);
        putch('\n');
    }
    return 0;
}
