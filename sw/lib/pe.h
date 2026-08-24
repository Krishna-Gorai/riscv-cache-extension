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
