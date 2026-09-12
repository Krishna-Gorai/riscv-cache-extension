#!/usr/bin/env python3
"""Check the cost model of the paper's Section "Why suppression pays".

Per write w from core i the original protocol charges

    C(w) = (g(w) - a(w))  +  sum_{j != i} rho_j(g(w))

i.e. the sender's wait for a grant that is conditioned on every other DCU
being ready, plus one displaced pipeline slot in each receiver that had a
request to displace. The filter zeroes both terms for every write whose sharer
set is empty, which on the four benchmark kernels is all of them, so the
saving must lie between

    lower = sender term alone      (the snoop-stall counter, baseline - oracle)
    upper = sender + one cycle per invalidation delivered

Both are read from the counters the testbench already dumps; nothing is fitted.
Counters are cluster totals over four DCUs and are divided by four; the saving
is that of the slowest PE, so the bracket is a per-DCU average against a
per-PE maximum, which is the approximation the paper states.

    python scripts/model_check.py
"""
import csv
import os

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.join(HERE, "..", "results")
NUM_DCU = 4


def rows(name):
    with open(os.path.join(RES, name), newline="") as f:
        return list(csv.DictReader(f))


def main():
    oracle = {r["kernel"]: r for r in rows("oracle_ceiling.csv")}
    bcast = {r["workload"]: int(r["broadcasts"]) for r in rows("invalidation_use.csv")
             if r["workload"] in oracle}

    print("%-11s %10s %10s %10s %10s  %s" % (
        "kernel", "lower", "saving", "upper", "rx share", "in bracket"))
    ok = True
    for k in ("matmul_64", "conv2d_64", "fft_256", "memcpy_16k"):
        o = oracle[k]
        saving = int(o["baseline_cycles"]) - int(o["oracle_cycles"])
        sender = (int(o["baseline_snoop"]) - int(o["oracle_snoop"])) / NUM_DCU
        rx_max = bcast[k] / NUM_DCU
        share = (saving - sender) / rx_max
        inside = sender <= saving <= sender + rx_max
        ok &= inside
        print("%-11s %10.0f %10d %10.0f %10.2f  %s" % (
            k, sender, saving, sender + rx_max, share, "yes" if inside else "NO"))
    print("model bracket holds on every kernel" if ok else "MODEL BRACKET VIOLATED")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
