/* ===========================================================================
 *  smoke.c -- M4 bring-up kernel.
 *
 *  Exercises the whole PE path: instruction fetch from the ITCM, PE-private
 *  data in the ITCM, and shared data reached through the Data-Bridge and the
 *  private DCU. Fills an array in the coherent shared data memory, reads it
 *  back and publishes a checksum the testbench verifies.
 *
 *  The second pass over the array is what the cache is there for: it should
 *  hit almost everywhere, since the first pass has just installed the lines.
 * ======================================================================== */

#include "pe.h"

#define N        64u
#define ARR_OFF  0x0000u        /* array base within the shared memory   */
#define RES_OFF  0x1000u        /* where the checksum is published       */

int main(void) {
    volatile uint32_t *arr = shared_ptr(ARR_OFF);
    volatile uint32_t *res = shared_ptr(RES_OFF);
    uint32_t sum = 0;

    for (uint32_t i = 0; i < N; i++) arr[i] = i * 3u + 1u;

    /* read the whole array back twice: the second pass should hit */
    for (uint32_t pass = 0; pass < 2; pass++)
        for (uint32_t i = 0; i < N; i++) sum += arr[i];

    res[0] = sum;
    res[1] = 0xC0FFEEu;

    puts_("smoke: sum=");
    putdec(sum);
    putch('\n');

    /* sum_{i<64}(3i+1) = 6112, counted twice -> 12224 */
    return (sum == 2u * 6112u) ? 0 : 1;
}
