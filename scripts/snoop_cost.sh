#!/usr/bin/env bash
# =============================================================================
#  snoop_cost.sh -- how much of a PE's time goes to the coherence bus.
#
#  The DCU's cycle accounting separates where a core access spends its time.
#  One of those buckets is stage 1 waiting for a snoopy-bus grant: the cost of
#  arbitrating for a shared, one-grant-per-cycle resource before an access may
#  proceed. Every coherent access pays it, including accesses that the cache
#  will not help.
#
#  This extracts that bucket from the sweep logs and expresses it as a fraction
#  of the cycles a PE spent with an access in the DCU at all, which is the
#  figure that says how much there is to win by not arbitrating.
#
#  Writes results/snoop_cost.csv
# =============================================================================
set -u
cd "$(dirname "$0")/.."
OUT=results
CSV=$OUT/snoop_cost.csv

echo "run,busy,snoop,snoop_pct,s2,s2_pct,rdwait,wrwait,reads,writes" > $CSV

for f in $OUT/*.log; do
  [ -f "$f" ] || continue
  line=$(grep -h "BENCHCYC" "$f" 2>/dev/null | head -1)
  [ -z "$line" ] && continue
  get() { echo "$line" | grep -oE "$1=[0-9]+" | head -1 | cut -d= -f2; }
  busy=$(get busy); snoop=$(get snoop); s2=$(get s2)
  rdw=$(get rdwait); wrw=$(get wrwait)
  rds=$(get reads); wrs=$(get writes)
  [ -z "${busy:-}" ] || [ "$busy" = "0" ] && continue
  sp=$(python -c "print('%.2f' % (100.0*$snoop/$busy))")
  s2p=$(python -c "print('%.2f' % (100.0*$s2/$busy))")
  echo "$(basename "$f" .log),$busy,$snoop,$sp,$s2,$s2p,$rdw,$wrw,$rds,$wrs" >> $CSV
done

echo "wrote $CSV"
column -s, -t < $CSV | head -30
