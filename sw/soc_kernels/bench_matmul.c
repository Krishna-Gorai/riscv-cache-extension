/* ===========================================================================
 *  bench_matmul.c -- Fig. 6: 16x16 integer matrix multiply, row-partitioned.
 *
 *  C = A * B. PE p owns a band of rows of C, which means it re-reads its own
 *  rows of A once per output column and re-reads the WHOLE of B once per
 *  output row it owns. B is the reuse: 1 KiB of it, read four times over by
 *  every PE, against a 2 KiB cache.
 *
 *  Nothing is shared for writing -- each PE writes only its own rows of C --
 *  so this kernel measures reuse rather than coherence traffic. The point of
 *  including it is that it is the case the extension should help most, and it
 *  is the one the paper reports at roughly 40%.
 * ======================================================================== */

#include "bench.h"

#define N        16u
#define A_OFF    0x0000u                /* 256 words = 0x400 bytes           */
#define B_OFF    0x0400u
#define C_OFF    0x0800u

/* scripts/bench_golden.py :: bench_matmul */
#define GOLDEN   0x6D5F6C02u

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
        for (uint32_t j = 0; j < N; j++) {
            int32_t acc = 0;
            for (uint32_t k = 0; k < N; k++)
                acc += (int32_t)A[i * N + k] * (int32_t)B[k * N + j];
            C[i * N + j] = (uint32_t)acc;
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
