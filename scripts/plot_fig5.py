#!/usr/bin/env python3
"""Memory-copy latency against transfer size, on the axes of the reference's Fig. 5.

Kamaleldin et al. plot memcpy latency for coherent and non-coherent multi-core
systems over 4 to 32 KiB and report the latency "approximately reduced by 50 %"
with the data cache. This reproduces those axes exactly -- same x label, same
"Latency (10^3 Cycles)" on y, same green-is-cached / red-is-uncached palette,
same line-and-marker form -- so the two figures can be read against each other.

It draws two panels rather than one, because a single panel would have to pick a
memory latency and their text does not state theirs. At MemLat=2, a BRAM
answering almost immediately, memcpy has nothing to hide and the extension is
slower than having no cache at all. At MemLat=20 it is 56 % faster, which is
close to their number. Reporting only the second would agree with them by
choosing the operating point that agrees; reporting both says where their result
holds and where it inverts.

    python scripts/plot_fig5.py            -> paper/fig_memcpy.pdf   (3 series)
    python scripts/plot_fig5.py --series 2 -> paper/fig_memcpy_repro.pdf

Reads results/fig5.csv, produced by scripts/run_fig5.ps1.
"""
import argparse
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from plot_results import (  # noqa: E402  -- shares the reference's styling
    BLUE, GREEN, RED, OUT, frame, panel_label, read_csv,
)

SIZES = [4, 8, 16, 32]
XLABEL = "Data Transfer Size"
YLABEL = "Latency ($10^3$ Cycles)"

# Their two series plus ours. Marker shapes differ as well as colour, so the
# figure survives a greyscale print.
SERIES3 = [
    ("noncoherent", "4-Cores w/o Data Cache", RED, "s", "-"),
    ("coherent", "4-Cores w/ Data Cache", GREEN, "s", "-"),
    ("filtered", "+ Snoop Filter (this work)", BLUE, "^", "--"),
]
SERIES2 = SERIES3[:2]

PANELS = [
    (2, "MemLat 2 (on-chip BRAM)"),
    (8, "MemLat 8"),
    (20, "MemLat 20 (off-chip class)"),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--series", type=int, choices=(2, 3), default=3)
    # One panel at a chosen latency, column width, for a paper that cannot
    # afford a full-width float. The two-panel version is the honest one and
    # stays the default; a single panel must say its latency in the caption.
    ap.add_argument("--only-memlat", type=int, choices=(2, 8, 20), default=None)
    args = ap.parse_args()
    series = SERIES2 if args.series == 2 else SERIES3
    panels = ([p for p in PANELS if p[0] == args.only_memlat]
              if args.only_memlat else PANELS)

    data = {}
    for r in read_csv("fig5.csv"):
        data[(int(r["kib"]), int(r["memlat"]), r["config"])] = int(r["cycles"])

    missing = [(k, lat, c) for lat, _t in panels for k in SIZES
               for c, _l, _col, _m, _ls in series if (k, lat, c) not in data]
    if missing:
        sys.exit("results/fig5.csv is missing %d point(s), e.g. %s"
                 % (len(missing), missing[:3]))

    if len(panels) == 1:
        fig, ax0 = plt.subplots(1, 1, figsize=(3.45, 1.80))
        axes = [ax0]
    else:
        fig, axes = plt.subplots(1, len(panels),
                                 figsize=(7.16, 2.15) if len(panels) == 2
                                 else (7.16, 1.75))

    for ax, (lat, title) in zip(axes, panels):
        for cfg, label, colour, marker, ls in series:
            ys = [data[(k, lat, cfg)] for k in SIZES]
            ax.plot(range(len(SIZES)), ys, label=label, color=colour,
                    marker=marker, markersize=3.2, linewidth=1.0, linestyle=ls,
                    markeredgecolor="#333333", markeredgewidth=0.4, zorder=3)
        frame(ax)
        panel_label(ax, title)
        ax.set_xticks(range(len(SIZES)))
        ax.set_xticklabels(["%d KiB" % k for k in SIZES])
        ax.set_xlim(-0.15, len(SIZES) - 0.85)
        ax.set_xlabel(XLABEL, fontsize=6.5)
        ax.set_ylabel(YLABEL, fontsize=6.5)
        ax.set_ylim(bottom=0)
        ax.yaxis.set_major_formatter(
            FuncFormatter(lambda v, _p: "%g" % (v / 1000.0)))

    axes[0].legend(loc="upper left", fontsize=5.6, borderpad=0.3,
                   handlelength=1.8, handletextpad=0.4, labelspacing=0.25)

    fig.tight_layout(pad=0.4, w_pad=1.4)
    if args.only_memlat:
        name = "fig_memcpy_l%d.pdf" % args.only_memlat
    else:
        name = "fig_memcpy.pdf" if args.series == 3 else "fig_memcpy_repro.pdf"
    path = os.path.join(OUT, name)
    fig.savefig(path, bbox_inches="tight")
    print("wrote %s" % path)

    for lat, _t in panels:
        for k in SIZES:
            nc = data[(k, lat, "noncoherent")]
            co = data[(k, lat, "coherent")]
            line = "  memlat %-3d %3d KiB  w/o %7d  w/ %7d  %+6.1f%%" % (
                lat, k, nc, co, 100.0 * (nc - co) / nc)
            if args.series == 3:
                fl = data[(k, lat, "filtered")]
                line += "   filtered %7d  %+6.1f%%" % (
                    fl, 100.0 * (nc - fl) / nc)
            print(line)


if __name__ == "__main__":
    main()
