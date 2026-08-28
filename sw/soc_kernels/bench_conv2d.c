/* ===========================================================================
 *  bench_conv2d.c -- Fig. 6: 3x3 convolution over a 32x32 image.
 *
 *  A sliding window: output row oy reads input rows oy, oy+1 and oy+2, so
 *  every input row is read three times, once for each output row it takes
 *  part in. Three rows of 32 words is 384 bytes, comfortably inside the 2 KiB
 *  cache, so a PE working down its band keeps the window resident and only
 *  misses when the window advances onto a new row.
 *
 *  The bands overlap by two rows, which is the interesting part: PE p and PE
 *  p+1 both read the two rows on their shared boundary. Those are genuine
 *  read-shared lines, and under a snooping protocol they can sit valid in
 *  both caches at once, because nobody writes the image. It is the case that
 *  distinguishes "shared" from "contended".
 *
 *  Written tap-major and accumulating into the output row in memory, for the
 *  same reason bench_matmul is: accumulating into a register would make every
 *  store a write miss under write-through / no-allocate, and a kernel with a
 *  0% write hit rate cannot reproduce the 96.5% Fig. 7 reports for this one.
 * ======================================================================== */

#include "bench.h"

#define H        32u
#define W        32u
#define OH       (H - 2u)               /* 30 */
#define OW       (W - 2u)               /* 30 */
#define IMG_OFF  0x0000u                /* 1024 words = 0x1000 bytes         */
#define OUT_OFF  0x1000u                /* 900 words                         */

/* scripts/bench_golden.py :: bench_conv2d */
#define GOLDEN   0xB4F41C8Au

/* separable blur, sums to 16 -- the >>4 below is the normalisation */
static const int32_t KER[3][3] = { { 1, 2, 1 }, { 2, 4, 2 }, { 1, 2, 1 } };

int main(void) {
    volatile uint32_t *img = shared_ptr(IMG_OFF);
    volatile uint32_t *out = shared_ptr(OUT_OFF);

    uint32_t id  = hart_id();
    uint32_t npe = NUM_PES;
    uint32_t lo, hi, t0, t1;
    uint32_t ilo, ihi;
    uint32_t tot0 = 0;

    bench_range(H,  id, npe, &ilo, &ihi);       /* input rows to seed        */
    bench_range(OH, id, npe, &lo,  &hi);        /* output rows to compute    */

    for (uint32_t y = ilo; y < ihi; y++)
        for (uint32_t x = 0; x < W; x++)
            img[y * W + x] = (y * W + x) % 251u;
    barrier();

    if (id == 0) tot0 = CYCLE_LO;
    t0 = CYCLE_LO;
    for (uint32_t oy = lo; oy < hi; oy++) {
        volatile uint32_t *orow = &out[oy * OW];

        for (uint32_t ox = 0; ox < OW; ox++) orow[ox] = 0u;

        /* Tap-major: the innermost loop walks a row of the image and a row of
         * the output, both contiguous, and accumulates in memory so the store
         * lands on a line the load ahead of it has just made resident. */
        for (uint32_t ky = 0; ky < 3u; ky++) {
            for (uint32_t kx = 0; kx < 3u; kx++) {
                int32_t w = KER[ky][kx];
                const uint32_t irow = (oy + ky) * W + kx;
                for (uint32_t ox = 0; ox < OW; ox++)
                    orow[ox] = (uint32_t)((int32_t)orow[ox]
                                          + (int32_t)img[irow + ox] * w);
            }
        }

        /* The kernel sums to 16; normalise once the accumulation is complete,
         * which keeps the result identical to summing then shifting. */
        for (uint32_t ox = 0; ox < OW; ox++)
            orow[ox] = (uint32_t)((int32_t)orow[ox] >> 4);
    }
    t1 = CYCLE_LO;

    bench_report(id, t1 - t0);
    barrier();

    if (id == 0) {
        bench_publish(npe, CYCLE_LO - tot0, OUT_OFF, OH * OW, GOLDEN);
        puts_("conv2d: ");    putdec(OH);
        putch('x');           putdec(OW);
        puts_(" cycles=");    putdec(t1 - t0);
        putch('\n');
    }
    return 0;
}
