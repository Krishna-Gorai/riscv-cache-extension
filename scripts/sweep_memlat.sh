#!/usr/bin/env bash
# =============================================================================
#  sweep_memlat.sh -- what the cache extension is worth, against memory latency.
#
#  The extension's speedup is not a property of the extension alone. The DCU
#  adds a second pipeline stage, so every access costs a cycle it did not cost
#  before, plus a snoop grant; the non-coherent path pays neither. That overhead
#  is fixed, while the benefit is proportional to the memory latency a hit
#  avoids. So the extension can only win once there is enough latency to hide,
#  and below that it loses.
#
#  This sweeps both variants over the memory latency the shared memories model:
#
#     MemLat  2   tb_bench      tb_bench_nc      the default configuration
#     MemLat  8   tb_bench_l8   tb_bench_nc_l8
#     MemLat 20   tb_bench_l20  tb_bench_nc_l20
#
#  Speedup is the non-coherent cycle count over the coherent one, so above 1
#  means the extension pays.
#
#  Writes results/memlat.csv
# =============================================================================
set -u
cd "$(dirname "$0")/.."
ROOT=$(pwd -W 2>/dev/null || pwd)
OUT=results
mkdir -p $OUT
CSV=$OUT/memlat.csv

echo "kernel,memlat,coherent_cycles,noncoherent_cycles,speedup" > $CSV

# One representative size per kernel, mid-range so neither the cache nor the
# memory is trivially the whole story.
KERNELS="memcpy_16k matmul_64 conv2d_64 fft_256"

run_pair() {
  local kern=$1 lat=$2 tb_c=$3 tb_n=$4
  local hex="$ROOT/sw/build/soc_bench_${kern}.hex"
  [ -f "$hex" ] || { echo "  skip $kern (no image)"; return; }

  local cyc_c cyc_n
  for side in c n; do
    local tb log
    if [ $side = c ]; then tb=$tb_c; else tb=$tb_n; fi
    log="$OUT/${tb}_${kern}.log"
    powershell -ExecutionPolicy Bypass -File sim/run_xsim.ps1 \
        -Tb "$tb" -Hex "$hex" -OutDir "sim\out_lat_${tb}" -Reuse > "$log" 2>&1
    if ! grep -q "slowest_pe_cycles=" "$log"; then
      # No snapshot yet for this testbench: build one and retry.
      powershell -ExecutionPolicy Bypass -File sim/run_xsim.ps1 \
          -Tb "$tb" -Hex "$hex" -OutDir "sim\out_lat_${tb}" > "$log" 2>&1
    fi
    local c
    c=$(grep -oE "slowest_pe_cycles=[0-9]+" "$log" | head -1 | cut -d= -f2)
    if [ $side = c ]; then cyc_c=${c:-}; else cyc_n=${c:-}; fi
  done

  if [ -z "${cyc_c:-}" ] || [ -z "${cyc_n:-}" ]; then
    echo "  $kern memlat=$lat FAILED"
    return
  fi
  local sp
  sp=$(python -c "print('%.3f' % ($cyc_n/$cyc_c))")
  echo "$kern,$lat,$cyc_c,$cyc_n,$sp" >> $CSV
  echo "  $kern memlat=$lat  coh=$cyc_c  nc=$cyc_n  speedup=${sp}x"
}

for spec in "2 tb_bench tb_bench_nc" "8 tb_bench_l8 tb_bench_nc_l8" "20 tb_bench_l20 tb_bench_nc_l20"; do
  set -- $spec
  lat=$1 tb_c=$2 tb_n=$3
  echo "== MemLat $lat =="
  for k in $KERNELS; do run_pair "$k" "$lat" "$tb_c" "$tb_n"; done
done

echo
echo "wrote $CSV"
column -s, -t < $CSV
