#!/usr/bin/env bash
# =============================================================================
#  sweep_capacity.sh -- is the FFT cliff capacity or conflict?
#
#  The per-PE FFT working set is 8N bytes, so N=512 is the first size that does
#  not fit the paper's 2 KiB DCU. It is also the first size whose butterfly
#  half-span reaches the set-index period, so the two operands of a butterfly
#  alias onto one set. Capacity and conflict arrive together, and one run cannot
#  separate them. Four configurations can:
#
#     2-way  64 sets   2 KiB   the paper's configuration
#     4-way  32 sets   2 KiB   capacity held, associativity doubled
#     2-way 256 sets   8 KiB   associativity held, capacity x4
#     2-way 512 sets  16 KiB   capacity x8, so N=1024 has room to be flat
#
#  If associativity is the cause, the 4-way run recovers and the 8 KiB run does
#  not. If capacity is the cause, the opposite.
#
#  Only the coherent side varies: the non-coherent baseline has no cache, so
#  neither parameter can move it.
#
#  Writes scripts/../results/capacity.csv
# =============================================================================
set -u
cd "$(dirname "$0")/.."
ROOT=$(pwd -W 2>/dev/null || pwd)
OUT=results
mkdir -p $OUT
CSV=$OUT/capacity.csv

echo "config,ways,sets,kib,n,cycles,rd_hit,rd_tot,wr_hit,wr_tot" > $CSV

run_one() {
  local tb=$1 ways=$2 sets=$3 kib=$4 n=$5 reuse=$6
  local hex="$ROOT/sw/build/soc_bench_fft_${n}.hex"
  [ -f "$hex" ] || { echo "  skip N=$n (no image)"; return; }

  local log="$OUT/${tb}_fft${n}.log"
  powershell -ExecutionPolicy Bypass -File sim/run_xsim.ps1 \
      -Tb "$tb" -Hex "$hex" -OutDir "sim\out_sweep_${tb}" $reuse > "$log" 2>&1

  local cyc rd
  cyc=$(grep -oE "slowest_pe_cycles=[0-9]+" "$log" | head -1 | cut -d= -f2)
  rd=$(grep -oE "rd_hit=[0-9]+ rd_tot=[0-9]+ wr_hit=[0-9]+ wr_tot=[0-9]+" "$log" | head -1)
  if [ -z "${cyc:-}" ]; then
    echo "  N=$n FAILED (see $log)"
    return
  fi
  local rh rt wh wt
  rh=$(echo "$rd" | grep -oE "rd_hit=[0-9]+" | cut -d= -f2)
  rt=$(echo "$rd" | grep -oE "rd_tot=[0-9]+" | cut -d= -f2)
  wh=$(echo "$rd" | grep -oE "wr_hit=[0-9]+" | cut -d= -f2)
  wt=$(echo "$rd" | grep -oE "wr_tot=[0-9]+" | cut -d= -f2)
  echo "$tb,$ways,$sets,$kib,$n,$cyc,$rh,$rt,$wh,$wt" >> $CSV
  echo "  N=$n  cycles=$cyc  rd_hit=$rh/$rt"
}

for spec in "tb_bench 2 64 2" "tb_bench_w4 4 32 2" "tb_bench_c8k 2 256 8" "tb_bench_c16k 2 512 16"; do
  set -- $spec
  tb=$1 ways=$2 sets=$3 kib=$4
  echo "== $tb  (${ways}-way, ${sets} sets, ${kib} KiB) =="
  first=1
  for n in 128 256 512 1024; do
    if [ $first -eq 1 ]; then run_one "$tb" "$ways" "$sets" "$kib" "$n" ""; first=0
    else                      run_one "$tb" "$ways" "$sets" "$kib" "$n" "-Reuse"; fi
  done
done

echo
echo "wrote $CSV"
column -s, -t < $CSV
