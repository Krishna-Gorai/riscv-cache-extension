/* ===========================================================================
 *  pe.h -- memory map and small helpers shared by the bare-metal kernels.
 * ======================================================================== */
#ifndef PE_H
#define PE_H

#include <stdint.h>

/* Coherent shared data memory, reached through the private DCU. */
#define SDMEM_BASE   0x10000000u
#define SDMEM_SIZE   (256u * 1024u)

/* Uncached control region used by the testbench. */
#define CTRL_BASE    0x80000000u
#define TOHOST       (*(volatile uint32_t *)(CTRL_BASE + 0x0))
#define PUTCHAR      (*(volatile uint32_t *)(CTRL_BASE + 0x4))
#define CYCLE_LO     (*(volatile uint32_t *)(CTRL_BASE + 0x8))
#define BARRIER      (*(volatile uint32_t *)(CTRL_BASE + 0xC))
#define NUM_PES      (*(volatile uint32_t *)(CTRL_BASE + 0x10))

/* Shared instruction memory, the SoC boot image. Read-only from software. */
#define SIMEM_BASE   0x20000000u

#define SHARED_U32(off) (*(volatile uint32_t *)(SDMEM_BASE + (off)))

static inline volatile uint32_t *shared_ptr(uint32_t byte_off) {
    return (volatile uint32_t *)(SDMEM_BASE + byte_off);
}

static inline uint32_t hart_id(void) {
    uint32_t id;
    __asm__ volatile("csrr %0, mhartid" : "=r"(id));
    return id;
}

static inline uint32_t rdcycle(void) {
    uint32_t c;
    __asm__ volatile("csrr %0, mcycle" : "=r"(c));
    return c;
}

/* All-PE barrier.
 *
 * CV32E40P implements no A extension, so a PE has no atomic read-modify-write
 * to build a software barrier from. The control region counts arrivals in
 * hardware instead, one per cycle behind its arbiter, which makes the count
 * atomic by construction. Reading the generation before arriving is what makes
 * this sense-reversing rather than racy: a PE cannot miss a release, because
 * the generation it waits to leave behind is the one it sampled on entry. */
static inline void barrier(void) {
    uint32_t gen = BARRIER;
    BARRIER = 1;
    while (BARRIER == gen) { }
}

static inline void putch(char c) { PUTCHAR = (uint32_t)(unsigned char)c; }

static inline void puts_(const char *s) {
    while (*s) putch(*s++);
}

static inline void puthex(uint32_t v) {
    const char *d = "0123456789abcdef";
    for (int i = 7; i >= 0; i--) putch(d[(v >> (i * 4)) & 0xF]);
}

static inline void putdec(uint32_t v) {
    char buf[11];
    int  n = 0;
    if (v == 0) { putch('0'); return; }
    while (v) { buf[n++] = (char)('0' + (v % 10)); v /= 10; }
    while (n) putch(buf[--n]);
}

#endif /* PE_H */
