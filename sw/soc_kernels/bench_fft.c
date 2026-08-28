/* ===========================================================================
 *  bench_fft.c -- Fig. 6: 64-point radix-2 decimation-in-time FFT, Q15.
 *
 *  In-place, so the butterflies of one stage write the operands the next
 *  stage reads, with a barrier between stages. That makes this the only
 *  kernel in the set where PEs genuinely invalidate each other mid-run: at
 *  every stage boundary a PE re-reads lines another PE has just written.
 *
 *  It is also the kernel with the worst locality. The stride between the two
 *  halves of a butterfly doubles every stage, so by the last stages the two
 *  operands are 32 words apart and land in different lines and different
 *  sets. The paper reports FFT as its smallest gain, and this is why.
 *
 *  Fixed point rather than float: CV32E40P here has no F extension. Q15
 *  twiddles, an int32 datapath, and input amplitudes held under +-500 so that
 *  a twiddle product never leaves int32 -- which is also what lets the Python
 *  model in scripts/bench_golden.py reproduce the result exactly.
 * ======================================================================== */

#include "bench.h"

#define LOG2N    6u
#define NPT      (1u << LOG2N)          /* 64 points                         */
#define RE_OFF   0x0000u                /* 64 words                          */
#define IM_OFF   0x0100u                /* immediately after RE: one region   */

/* scripts/bench_golden.py :: bench_fft */
#define GOLDEN   0x9D1E3B00u

/* W_k = cos(-2*pi*k/64) + j*sin(-2*pi*k/64), Q15. Held as int32: cos(0)
 * scales to 32768, which does not fit a signed 16-bit word. */
static const int32_t TW[NPT / 2][2] = {
    {  32768,      0 }, {  32610,  -3212 }, {  32138,  -6393 }, {  31357,  -9512 },
    {  30274, -12540 }, {  28899, -15447 }, {  27246, -18205 }, {  25330, -20788 },
    {  23170, -23170 }, {  20788, -25330 }, {  18205, -27246 }, {  15447, -28899 },
    {  12540, -30274 }, {   9512, -31357 }, {   6393, -32138 }, {   3212, -32610 },
    {      0, -32768 }, {  -3212, -32610 }, {  -6393, -32138 }, {  -9512, -31357 },
    { -12540, -30274 }, { -15447, -28899 }, { -18205, -27246 }, { -20788, -25330 },
    { -23170, -23170 }, { -25330, -20788 }, { -27246, -18205 }, { -28899, -15447 },
    { -30274, -12540 }, { -31357,  -9512 }, { -32138,  -6393 }, { -32610,  -3212 },
};

static inline uint32_t bitrev(uint32_t v) {
    uint32_t r = 0;
    for (uint32_t b = 0; b < LOG2N; b++) { r = (r << 1) | (v & 1u); v >>= 1; }
    return r;
}

int main(void) {
    volatile uint32_t *re = shared_ptr(RE_OFF);
    volatile uint32_t *im = shared_ptr(IM_OFF);

    uint32_t id  = hart_id();
    uint32_t npe = NUM_PES;
    uint32_t lo, hi, blo, bhi, t0, t1;
    uint32_t tot0 = 0;

    bench_range(NPT, id, npe, &lo, &hi);

    for (uint32_t i = lo; i < hi; i++) {
        re[i] = (uint32_t)(int32_t)((int32_t)((i * 37u) % 1000u) - 500);
        im[i] = 0u;
    }
    barrier();

    if (id == 0) tot0 = CYCLE_LO;
    t0 = CYCLE_LO;

    /* --- bit-reversal permutation ----------------------------------------
     * Each swap touches the pair (i, bitrev(i)) and no other, so the pairs
     * are disjoint and the PEs can do them in parallel. The j > i guard is
     * what makes each pair get swapped exactly once instead of twice. */
    for (uint32_t i = lo; i < hi; i++) {
        uint32_t j = bitrev(i);
        if (j > i) {
            uint32_t tr = re[i], ti = im[i];
            re[i] = re[j]; im[i] = im[j];
            re[j] = tr;    im[j] = ti;
        }
    }
    barrier();

    /* --- log2(N) butterfly stages ----------------------------------------
     * The N/2 butterflies of a stage are split across the PEs by a flat
     * index; group and offset come out of it by shift and mask because the
     * half-span is always a power of two. */
    bench_range(NPT / 2u, id, npe, &blo, &bhi);

    for (uint32_t s = 0; s < LOG2N; s++) {
        uint32_t half  = 1u << s;
        uint32_t step  = half << 1;
        uint32_t tstep = NPT / step;

        for (uint32_t b = blo; b < bhi; b++) {
            uint32_t g  = b >> s;
            uint32_t k  = b & (half - 1u);
            uint32_t ia = g * step + k;
            uint32_t ib = ia + half;

            int32_t wr = TW[k * tstep][0], wi = TW[k * tstep][1];
            int32_t br = (int32_t)re[ib],  bi = (int32_t)im[ib];
            int32_t ar = (int32_t)re[ia],  ai = (int32_t)im[ia];

            int32_t tr = (wr * br - wi * bi) >> 15;
            int32_t ti = (wr * bi + wi * br) >> 15;

            re[ib] = (uint32_t)(ar - tr);
            im[ib] = (uint32_t)(ai - ti);
            re[ia] = (uint32_t)(ar + tr);
            im[ia] = (uint32_t)(ai + ti);
        }
        barrier();
    }
    t1 = CYCLE_LO;

    bench_report(id, t1 - t0);
    barrier();

    if (id == 0) {
        /* RE and IM are adjacent, so the harness scores both as one region. */
        bench_publish(npe, CYCLE_LO - tot0, RE_OFF, 2u * NPT, GOLDEN);
        puts_("fft: n=");     putdec(NPT);
        puts_(" cycles=");    putdec(t1 - t0);
        putch('\n');
    }
    return 0;
}
