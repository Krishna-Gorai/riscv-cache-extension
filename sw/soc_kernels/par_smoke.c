/* ===========================================================================
 *  par_smoke.c -- M5 multi-core bring-up kernel.
 *
 *  Boots all PEs out of the shared instruction memory, transfers the code into
 *  each private ITCM, and then does the smallest thing a non-coherent cache
 *  would get wrong:
 *
 *    phase 0   every PE reads the whole array, caching every line while it
 *              still holds the initial zeros
 *    phase 1   each PE writes only its own slice
 *    phase 2   every PE reads the whole array again
 *
 *  In phase 2 each PE is reading lines it cached in phase 0 and that somebody
 *  else has written since. Only the invalidation traffic on the snoopy bus
 *  makes those reads return the new values, so a wrong or missing invalidation
 *  shows up as a wrong checksum rather than as a hang.
 *
 *  The array is walked a second time in phase 2 as well. Those reads should
 *  all hit, which is what gives the run a hit rate worth reporting.
 * ======================================================================== */

#include "pe.h"

#define N        256u
#define ARR_OFF  0x0000u        /* the shared array                          */
#define RES_OFF  0x1000u        /* per-PE results and the final sentinel     */

/* sum_{i<256} (7i + 1) = 7 * (255*256/2) + 256 */
#define EXPECT   228736u

int main(void) {
    volatile uint32_t *arr = shared_ptr(ARR_OFF);
    volatile uint32_t *res = shared_ptr(RES_OFF);

    uint32_t id   = hart_id();
    uint32_t npe  = NUM_PES;
    uint32_t span = N / npe;
    uint32_t lo   = span * id;
    uint32_t hi   = lo + span;

    uint32_t pre = 0, post = 0, again = 0;
    uint32_t t0, t1;

    t0 = CYCLE_LO;

    /* --- phase 0: cache every line while it still reads as zero ----------- */
    for (uint32_t i = 0; i < N; i++) pre += arr[i];
    barrier();

    /* --- phase 1: each PE writes its own slice ---------------------------- */
    for (uint32_t i = lo; i < hi; i++) arr[i] = i * 7u + 1u;
    barrier();

    /* --- phase 2: read it all back; every line cached in phase 0 is stale -- */
    for (uint32_t i = 0; i < N; i++) post  += arr[i];
    for (uint32_t i = 0; i < N; i++) again += arr[i];

    t1 = CYCLE_LO;

    res[id]      = post;
    res[8 + id]  = pre;
    res[16 + id] = again;
    res[24 + id] = t1 - t0;
    barrier();

    if (id == 0) {
        uint32_t ok = 1;
        for (uint32_t p = 0; p < npe; p++) {
            if (res[p]      != EXPECT) ok = 0;   /* saw everyone's writes    */
            if (res[8 + p]  != 0u)     ok = 0;   /* started from zeros       */
            if (res[16 + p] != EXPECT) ok = 0;   /* stable on the re-read    */
        }
        res[32] = ok ? 0xC0FFEEu : 0x0BADu;

        puts_("par_smoke: pes=");
        putdec(npe);
        puts_(" sum=");
        putdec(post);
        puts_(" cycles=");
        putdec(res[24]);
        putch('\n');
        return ok ? 0 : 1;
    }

    return ((post == EXPECT) && (again == EXPECT) && (pre == 0u)) ? 0 : 1;
}
