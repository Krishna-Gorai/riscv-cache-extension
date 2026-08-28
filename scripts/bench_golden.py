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
def bench_memcpy(N=1024):
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
def bench_conv2d(H=32, W=32):
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
FFT_N = 128
FFT_LOG2 = 7


def fft_twiddles(N=FFT_N):
    import math
    tw = []
    for k in range(N // 2):
        ang = -2.0 * math.pi * k / N
        tw.append((int(round(math.cos(ang) * 32768.0)),
                   int(round(math.sin(ang) * 32768.0))))
    # cos(0)*32768 rounds to 32768, which does not fit a signed 16-bit twiddle;
    # the C table stores int32 so it is kept exact rather than clamped.
    return tw


def bench_fft(N=FFT_N, log2n=FFT_LOG2):
    xr = [((i * 37) % 1000) - 500 for i in range(N)]
    xi = [0] * N

    # bit-reversal permutation
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
                xr[b] = xr[a] - tr
                xi[b] = xi[a] - ti
                xr[a] = xr[a] + tr
                xi[a] = xi[a] + ti
        half = step

    return csum([v & M32 for v in xr] + [v & M32 for v in xi]), xr, xi


if __name__ == "__main__":
    mc = bench_memcpy()
    mm = bench_matmul()
    cv = bench_conv2d()
    ft, fr, fi = bench_fft()

    print("golden checksums (paste into the GOLDEN define of each kernel)")
    print("  bench_memcpy   N=1024 words        0x%08X  (%u)" % (mc, mc))
    print("  bench_matmul   32x32 int32         0x%08X  (%u)" % (mm, mm))
    print("  bench_conv2d   3x3 over 32x32      0x%08X  (%u)" % (cv, cv))
    print("  bench_fft      N=128 Q15 radix-2   0x%08X  (%u)" % (ft, ft))

    # a couple of spot values, so a wrong kernel can be localised rather than
    # just reported as "checksum differs"
    print("\nspot checks")
    print("  fft xr[0..3] = %s" % fr[:4])
    print("  fft xi[1..4] = %s" % fi[1:5])

    mx = max(max(abs(v) for v in fr), max(abs(v) for v in fi))
    print("  fft peak magnitude = %d (int32 headroom ok: %s)"
          % (mx, "yes" if mx * 32768 < 2**31 else "NO -- reduce input amplitude"))
