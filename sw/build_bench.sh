#!/usr/bin/env bash
# =============================================================================
#  build_bench.sh -- build one image per benchmark configuration the paper uses.
#
#  Fig. 5 sweeps memory copy over 4/8/16/32 KiB. Fig. 6 and Fig. 7 sweep matrix
#  multiply and 2-D convolution over 32x32/64x64/128x128, and the FFT over
#  128/256/512/1024 points. Each of those is a separate binary, because the
#  size and the golden checksum are both compiled in.
#
#  The sizes and goldens are not written down here: they come straight out of
#  scripts/bench_golden.py, the independent model, so the two cannot drift.
#
#  Usage:  sw/build_bench.sh              build all 14
#          sw/build_bench.sh fft          build one kernel's sweep
# =============================================================================
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
want="${1:-all}"

python "$root/scripts/bench_golden.py" --defs | while read -r kern size param gold; do
  [ "$want" = "all" ] || [ "$want" = "$kern" ] || continue

  case "$kern" in
    memcpy) def="-DBENCH_KIB=${param}u";   sfx="_${param}k" ;;
    matmul) def="-DBENCH_N=${param}u";     sfx="_${param}"  ;;
    conv2d) def="-DBENCH_N=${param}u";     sfx="_${param}"  ;;
    fft)    def="-DBENCH_LOG2N=${param}u"; sfx="_$(( 1 << param ))" ;;
    *) echo "unknown kernel $kern" >&2; exit 1 ;;
  esac

  KCFLAGS="$def -DBENCH_GOLDEN=${gold}u" OUT_SUFFIX="$sfx" \
    "$root/sw/build.sh" "soc:bench_$kern"
done

echo "done -> sw/build/soc_bench_*.hex"
