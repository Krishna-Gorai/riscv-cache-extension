/* ===========================================================================
 *  bench_matmul.c -- Fig. 6: 32x32 integer matrix multiply, row-partitioned.
 *
 *  C = A * B, in i-k-j order rather than the textbook i-j-k, and accumulating
 *  into C in memory rather than into a register. Both of those are forced by
 *  what the cache is:
 *
 *    i-j-k walks B DOWN A COLUMN, stride N words. At 32x32 that is a 128-byte
 *    stride through a 4 KiB matrix against a 2 KiB cache, so B never survives
 *    to be reused and reads come out at 48%. i-k-j walks a ROW of B and a ROW
 *    of C, both contiguous, and the paper reports 94.7% at this size.
 *
 *    Accumulating in a register would make every store a write MISS, because
 *    write-through / no-allocate never installs a line on a store. A kernel
 *    written that way cannot have a write hit rate above zero, and so cannot
 *    average the 90-96.5% Fig. 7 reports. Accumulating in memory reads the
 *    line first, so the store that follows hits.
 *
 *  PE p owns a band of rows of C. A and C rows are private to their owner; B
 *  is read by every PE and written by none, so it is the read-shared case the
 *  snooping protocol is supposed to make free.
 *
 *  32x32 is the leftmost point of the paper's Fig. 6 x-axis (32 / 64 / 128).
 *  At 16x16 the whole working set fits the cache, the coherent build goes
 *  nearly compute-bound, and the speedup over the no-cache baseline comes
 *  out far above what the paper reports. Kernel size is the variable that
 *  matters most in this comparison.
 *
 *  Nothing is shared for writing -- each PE writes only its own rows of C --
 *  so this kernel measures reuse rather than coherence traffic. The point of
 *  including it is that it is the case the extension should help most, and it
 *  is the one the paper reports at roughly 40%.
 * ======================================================================== */

#include "bench.h"

#define N        32u
#define A_OFF    0x0000u                /* 1024 words = 0x1000 bytes         */
#define B_OFF    0x1000u
#define C_OFF    0x2000u

/* scripts/bench_golden.py :: bench_matmul */
#define GOLDEN   0xD4B9F33Cu

int main(void) {
    volatile uint32_t *A = shared_ptr(A_OFF);
    volatile uint32_t *B = shared_ptr(B_OFF);
    volatile uint32_t *C = shared_ptr(C_OFF);

    uint32_t id  = hart_id();
    uint32_t npe = NUM_PES;
    uint32_t lo, hi, t0, t1;
    uint32_t tot0 = 0;

    bench_range(N, id, npe, &lo, &hi);

    for (uint32_t i = lo; i < hi; i++) {
        for (uint32_t j = 0; j < N; j++) {
            A[i * N + j] = (uint32_t)(int32_t)((int32_t)((i * N + j) % 13u) - 6);
            B[i * N + j] = (uint32_t)(int32_t)((int32_t)((i * 7u + j * 3u) % 11u) - 5);
        }
    }
    barrier();

    if (id == 0) tot0 = CYCLE_LO;
    t0 = CYCLE_LO;
    for (uint32_t i = lo; i < hi; i++) {
        for (uint32_t j = 0; j < N; j++) C[i * N + j] = 0u;
        for (uint32_t k = 0; k < N; k++) {
            int32_t a = (int32_t)A[i * N + k];
            for (uint32_t j = 0; j < N; j++)
                C[i * N + j] = (uint32_t)((int32_t)C[i * N + j] + a * (int32_t)B[k * N + j]);
        }
    }
    t1 = CYCLE_LO;

    bench_report(id, t1 - t0);
    barrier();

    if (id == 0) {
        bench_publish(npe, CYCLE_LO - tot0, C_OFF, N * N, GOLDEN);
        puts_("matmul: n=");   putdec(N);
        puts_(" cycles=");     putdec(t1 - t0);
        putch('\n');
    }
    return 0;
}
