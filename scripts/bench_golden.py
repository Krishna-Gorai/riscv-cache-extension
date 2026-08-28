#!/usr/bin/env python3
"""bench_golden.py -- independent reference model for the M6 benchmark kernels.

The kernels in sw/soc_kernels/bench_*.c compute their results into the shared
data memory. This script recomputes the same results in Python, with the same
integer semantics, and prints the checksum each kernel must produce. Those
numbers are what the GOLDEN constants in the C files are set to, so a kernel
that computes the wrong thing is caught by a value derived independently of it
rather than by a value it produced itself.

Checksum (must match bench.h's definition exactly):

    h = 0
    for v in words:  h = (h * 31 + (v & 0xFFFFFFFF)) & 0xFFFFFFFF

Run:  python scripts/bench_golden.py
"""

M32 = 0xFFFFFFFF


def csum(words):
    h = 0
    for v in words:
        h = (h * 31 + (v & M32)) & M32
    return h


def s32(v):
    """Interpret a Python int as a signed 32-bit value, the way the RTL memory
    model's word would be read back."""
    v &= M32
    return v - (1 << 32) if v >> 31 else v


# ---------------------------------------------------------------------------
#  memcpy -- N words copied from src to dst. Streaming, no reuse: this is the
#  Fig. 5 latency benchmark.
# ---------------------------------------------------------------------------
def bench_memcpy(kib=4):
    N = kib * 256
    src = [(i * 7 + 1) & M32 for i in range(N)]
    dst = list(src)
    return csum(dst)


# ---------------------------------------------------------------------------
#  matmul -- C = A x B over 32x32 int32 matrices, row-partitioned. 32x32 is the
#  leftmost point of the paper's Fig. 6 x-axis (32x32 / 64x64 / 128x128). Each element
#  of B is re-read once per output row, which is where the reuse comes from.
# ---------------------------------------------------------------------------
def bench_matmul(N=32):
    A = [[(i * N + j) % 13 - 6 for j in range(N)] for i in range(N)]
    B = [[(i * 7 + j * 3) % 11 - 5 for j in range(N)] for i in range(N)]
    C = [[0] * N for _ in range(N)]
    for i in range(N):
        for j in range(N):
            acc = 0
            for k in range(N):
                acc = s32((acc + A[i][k] * B[k][j]) & M32)
            C[i][j] = acc
    return csum(C[i][j] for i in range(N) for j in range(N))


# ---------------------------------------------------------------------------
#  conv2d -- 3x3 kernel over a 32x32 image, 30x30 valid output. A sliding
#  window reads each input row for three consecutive output rows, so a row band
#  stays resident: this is the high-reuse case.
# ---------------------------------------------------------------------------
def bench_conv2d(N=32):
    H = W = N
    K = [[1, 2, 1], [2, 4, 2], [1, 2, 1]]          # separable blur, sums to 16
    img = [[(i * W + j) % 251 for j in range(W)] for i in range(H)]
    OH, OW = H - 2, W - 2
    out = [[0] * OW for _ in range(OH)]
    for oy in range(OH):
        for ox in range(OW):
            acc = 0
            for ky in range(3):
                for kx in range(3):
                    acc += img[oy + ky][ox + kx] * K[ky][kx]
            out[oy][ox] = s32((acc >> 4) & M32)
    return csum(out[y][x] for y in range(OH) for x in range(OW))


# ---------------------------------------------------------------------------
#  fft -- radix-2 decimation-in-time, N=128, Q15 twiddles, int32 datapath.
#  128 is the leftmost point of the paper's Fig. 6 FFT x-axis (128..1024).
#  Strided butterflies with a barrier between stages: the paper's least
#  improved kernel, and the one that stresses invalidation traffic most.
#
#  Amplitudes are kept under +-500 so that wr*xr never leaves int32 and the
#  C and Python results agree exactly without emulating wraparound.
# ---------------------------------------------------------------------------
def fft_twiddles(N):
    import math
    tw = []
    for k in range(N // 2):
        ang = -2.0 * math.pi * k / N
        tw.append((int(round(math.cos(ang) * 32768.0)),
                   int(round(math.sin(ang) * 32768.0))))
    # cos(0)*32768 rounds to 32768, which does not fit a signed 16-bit twiddle;
    # the C table stores int32 so it is kept exact rather than clamped.
    return tw


def bench_fft(log2n=7):
    """Radix-2 DIT, Q15 twiddles, int32 datapath, scaled by 1/2 every stage.

    The per-stage shift is what makes the kernel safe at every size the paper
    uses. Without it the magnitude doubles per stage, and by N=1024 a twiddle
    product would leave int32 -- which would not just be inaccurate, it would
    stop the C and the Python agreeing, because C wraps and Python does not.
    With it the magnitude stays put and the same code runs at 128 and at 1024.
    """
    N = 1 << log2n
    xr = [((i * 37) % 1000) - 500 for i in range(N)]
    xi = [0] * N

    for i in range(N):
        j = int('{:0{w}b}'.format(i, w=log2n)[::-1], 2)
        if j > i:
            xr[i], xr[j] = xr[j], xr[i]
            xi[i], xi[j] = xi[j], xi[i]

    tw = fft_twiddles(N)
    half = 1
    while half < N:
        step = half * 2
        tstep = N // step
        for base in range(0, N, step):
            for k in range(half):
                wr, wi = tw[k * tstep]
                a, b = base + k, base + k + half
                tr = (wr * xr[b] - wi * xi[b]) >> 15
                ti = (wr * xi[b] + wi * xr[b]) >> 15
                ar, ai = xr[a], xi[a]
                xr[b] = (ar - tr) >> 1
                xi[b] = (ai - ti) >> 1
                xr[a] = (ar + tr) >> 1
                xi[a] = (ai + ti) >> 1
        half = step

    # One PE's block. Every PE transforms the same input, so the published
    # region is this block repeated NPE times -- and scoring all of it means
    # a PE that got its own transform wrong is caught.
    block = [v & M32 for v in xr] + [v & M32 for v in xi]
    return csum(block * NPE), xr, xi, csum(block)


NPE        = 4                       # PEs in the SoC under test

MEMCPY_KIB = [4, 8, 16, 32]          # Fig. 5 x-axis
MATMUL_N   = [32, 64, 128]           # Fig. 6/7 x-axis
CONV2D_N   = [32, 64, 128]           # Fig. 6/7 x-axis
FFT_LOG2   = [7, 8, 9, 10]           # Fig. 6/7 x-axis: 128 .. 1024


if __name__ == "__main__":
    import sys

    rows = []
    for k in MEMCPY_KIB:
        rows.append(("memcpy", "%dKiB" % k, k, bench_memcpy(k)))
    for n in MATMUL_N:
        rows.append(("matmul", "%dx%d" % (n, n), n, bench_matmul(n)))
    for n in CONV2D_N:
        rows.append(("conv2d", "%dx%d" % (n, n), n, bench_conv2d(n)))
    for lg in FFT_LOG2:
        rows.append(("fft", "N=%d" % (1 << lg), lg, bench_fft(lg)[0]))

    if "--defs" in sys.argv:
        # emitted so build_bench.sh can compile one image per configuration
        for kern, label, param, gold in rows:
            print("%s %s %d 0x%08X" % (kern, label.replace("KiB", ""), param, gold))
        sys.exit(0)

    print("golden checksums for every configuration the paper evaluates")
    print("%-8s %-10s %-8s %s" % ("kernel", "size", "param", "golden"))
    print("-" * 46)
    for kern, label, param, gold in rows:
        print("%-8s %-10s %-8d 0x%08X" % (kern, label, param, gold))
    print("-" * 46)

    for lg in FFT_LOG2:
        _, fr, fi, _one = bench_fft(lg)
        mx = max(max(abs(v) for v in fr), max(abs(v) for v in fi))
        ok = "ok" if mx * 32768 < 2**31 else "OVERFLOW"
        print("fft N=%-5d peak magnitude %6d  int32 headroom: %-8s one-block golden 0x%08X" % (1 << lg, mx, ok, _one))
