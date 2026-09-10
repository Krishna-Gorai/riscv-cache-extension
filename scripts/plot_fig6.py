#!/usr/bin/env python3
"""Execution time against problem size, on the axes of the reference's Fig. 6.

Kamaleldin et al. plot total execution time of matrix multiplication, 2-D
convolution and FFT for coherent and non-coherent multi-core systems, one panel
per kernel, sweeping problem size at a fixed clock. This reproduces those axes
exactly -- same panel order, same x-axis labels, same "Execution Time (10^3
Cycles)" on y, same green-is-cached / red-is-uncached palette -- so a reader can
hold the two figures side by side and compare data rather than decode two
visual languages.

Two versions, from one data file:

    python scripts/plot_fig6.py --series 2   -> paper/fig_exec_repro.pdf
        The reference's own comparison and nothing else: with and without the
        data cache. This is a reproduction result and belongs in the
        reproduction paper.

    python scripts/plot_fig6.py --series 3   -> paper/fig_exec.pdf   (default)
        The same, plus the snoop filter of this work as a third bar. The
        reference has no counterpart to that bar; it is what the DATE paper is
        about.

Panel identity goes inside the frame via panel_label rather than as a title
above the axes, which is this project's convention -- the LaTeX caption does
the titling. The reference titles its panels; we do not, and the caption names
the kernels instead.

Reads results/fig6.csv, produced by scripts/run_fig6.ps1.
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
    BLUE, GREEN, RED, OUT, frame, grouped_bars, panel_label, read_csv,
)

# Panel order, x-axis label and category order, all taken from the reference's
# Fig. 6. The x labels are quoted verbatim from it.
PANELS = [
    ("matmul", "Matrix Multiplication", "A, B Matrix Size",
     ["32x32", "64x64", "128x128"]),
    ("conv2d", "Convolution", "Input Matrix Size",
     ["32x32", "64x64", "128x128"]),
    ("fft", "FFT", "FFT Input Size per Sample",
     ["256", "512", "1024"]),
]

YLABEL = "Execution Time ($10^3$ Cycles)"

# Green is the cached configuration and red the uncached one, matching the
# reference. Blue is ours, a colour the reference does not use, so the added
# series cannot be mistaken for one of theirs.
SERIES3 = [
    ("noncoherent", "Cores w/o Data Cache", RED, ""),
    ("coherent", "Cores w/ Data Cache", GREEN, "///"),
    ("filtered", "+ Snoop Filter (this work)", BLUE, "..."),
]
SERIES2 = SERIES3[:2]


def load():
    """{(kernel, size, config): cycles} from the sweep."""
    out = {}
    for r in read_csv("fig6.csv"):
        out[(r["kernel"], r["size"], r["config"])] = int(r["cycles"])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--series", type=int, choices=(2, 3), default=3)
    args = ap.parse_args()

    series = SERIES2 if args.series == 2 else SERIES3
    data = load()

    # Drop any size for which the sweep has not produced every series yet, and
    # say so. A whole group omitted from the axis is honest -- the reader sees
    # two sizes instead of three. A group kept with a bar missing is not: an
    # absent bar in a cluster reads as a measured zero.
    panels, dropped = [], []
    for kern, title, xlabel, sizes in PANELS:
        keep = [s for s in sizes
                if all((kern, s, c) in data for c, _l, _col, _h in series)]
        dropped += [(kern, s) for s in sizes if s not in keep]
        if keep:
            panels.append((kern, title, xlabel, keep))
    if dropped:
        print("NOT YET MEASURED, omitted from the figure: %s"
              % ", ".join("%s %s" % d for d in dropped))
    if not panels:
        sys.exit("results/fig6.csv has no complete size for any kernel")

    fig, axes = plt.subplots(1, 3, figsize=(7.16, 2.35))

    for ax, (kern, title, xlabel, sizes) in zip(axes, panels):
        values = [[data[(kern, s, cfg)] for s in sizes]
                  for cfg, _l, _c, _h in series]
        grouped_bars(ax, sizes, [l for _c, l, _col, _h in series], values,
                     [col for _c, _l, col, _h in series],
                     [h for _c, _l, _col, h in series])
        frame(ax, bars=True)
        panel_label(ax, title)
        ax.set_xlabel(xlabel, fontsize=6.5)
        ax.set_ylabel(YLABEL, fontsize=6.5)
        ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _p: "%g" % (v / 1000.0)))
        ax.margins(y=0.02)

    # One legend for all three panels, bordered and inside the last one, which
    # is where the reference puts it. Three entries fit; two leave it smaller.
    axes[-1].legend(loc="upper left", fontsize=5.6, borderpad=0.3,
                    handlelength=1.4, handletextpad=0.4, labelspacing=0.25)

    fig.tight_layout(pad=0.4, w_pad=1.1)
    name = "fig_exec.pdf" if args.series == 3 else "fig_exec_repro.pdf"
    path = os.path.join(OUT, name)
    fig.savefig(path, bbox_inches="tight")
    print("wrote %s" % path)

    # Restate the reduction the reference quotes (~40 % matmul, ~40 % conv2d,
    # ~23 % FFT), so the number in the text always comes from the same data as
    # the figure.
    for kern, title, _x, sizes in panels:
        for s in sizes:
            nc = data[(kern, s, "noncoherent")]
            co = data[(kern, s, "coherent")]
            line = "  %-8s %-8s  w/o %9d  w/ %9d  reduction %5.1f%%" % (
                kern, s, nc, co, 100.0 * (nc - co) / nc)
            if args.series == 3:
                fl = data[(kern, s, "filtered")]
                line += "  filtered %9d (%5.1f%%)" % (
                    fl, 100.0 * (nc - fl) / nc)
            print(line)


if __name__ == "__main__":
    main()
