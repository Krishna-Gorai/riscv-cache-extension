#!/usr/bin/env python3
"""Figures for the DATE paper.

Two figures, each carrying an argument the tables cannot.

  fig_stall   the motivation: how much of a core's time the coherence bus takes,
              and that it grows with memory latency. Table II says none of that
              traffic is useful; this says what it costs.

  fig_result  the result and its mechanism side by side: the speedup, and the
              snoop-stall cycles collapsing, which is why the speedup happens.

Conventions, chosen for an IEEE two-column paper printed in black and white:
serif type at the paper's own size, single-column width, a closed frame, a light
grid behind the data, hatching so the bars survive greyscale, and no titles --
the LaTeX caption names the figure.

    python scripts/plot_date.py
"""
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter, NullFormatter, NullLocator

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "paper")

# IEEE column geometry. A single column is 3.5 in; leaving a hair under avoids
# the caption box being wider than the figure it labels.
COL = 3.4
FULL = 7.16

plt.rcParams.update({
    "font.family": "serif",
    "font.serif": ["Times New Roman", "Nimbus Roman", "DejaVu Serif"],
    "font.size": 7,
    "axes.labelsize": 7,
    "axes.titlesize": 7,
    "xtick.labelsize": 6.5,
    "ytick.labelsize": 6.5,
    "legend.fontsize": 6.5,
    "axes.linewidth": 0.6,
    "axes.edgecolor": "#000000",
    "xtick.major.width": 0.6,
    "ytick.major.width": 0.6,
    "xtick.major.size": 2,
    "ytick.major.size": 2,
    "legend.fancybox": False,
    "legend.framealpha": 1.0,
    "legend.edgecolor": "#000000",
    "legend.borderpad": 0.35,
    "legend.handlelength": 1.4,
    "legend.labelspacing": 0.25,
    "hatch.linewidth": 0.4,
    "pdf.fonttype": 42,
    "ps.fonttype": 42,
})

GRID = dict(color="#CCCCCC", linewidth=0.4, linestyle="-")

# A greyscale ramp rather than colour: these figures have to survive a black and
# white print, and hatching alone is hard to read at this size.
FILLS = ["#FFFFFF", "#BFBFBF", "#7F7F7F", "#404040"]
HATCH = ["", "///", "...", "xxx"]


def frame(ax, yonly=True):
    for side in ("top", "right", "bottom", "left"):
        ax.spines[side].set_visible(True)
    ax.grid(True, axis="y" if yonly else "both", **GRID)
    ax.set_axisbelow(True)


def bars(ax, groups, series, values, fmt=None, rot=0):
    n = len(series)
    width = 0.78 / n
    xs = range(len(groups))
    for i, name in enumerate(series):
        offs = [x - 0.39 + width * (i + 0.5) for x in xs]
        ax.bar(offs, values[i], width=width * 0.9, label=name,
               facecolor=FILLS[i % len(FILLS)], edgecolor="#000000",
               linewidth=0.5, hatch=HATCH[i % len(HATCH)], zorder=3)
        if fmt:
            for x, v in zip(offs, values[i]):
                ax.text(x, v, fmt % v, ha="center", va="bottom",
                        fontsize=5.5, rotation=rot, zorder=4)
    ax.set_xticks(list(xs))
    ax.set_xticklabels(groups)
    ax.set_xlim(-0.5, len(groups) - 0.5)


# -----------------------------------------------------------------------------
#  Figure 1 -- the motivation
# -----------------------------------------------------------------------------
def fig_stall():
    kernels = ["memcpy", "matmul", "conv2d", "FFT"]
    lat = ["MemLat 2", "MemLat 8", "MemLat 20"]
    # rows are latencies, columns kernels
    vals = [[14.3, 15.8, 6.5, 5.8],
            [26.1, 26.3, 11.2, 8.4],
            [33.0, 32.9, 19.0, 12.2]]

    fig, ax = plt.subplots(figsize=(COL, 1.85))
    bars(ax, kernels, lat, vals, fmt="%.0f", rot=90)
    frame(ax)
    ax.set_ylabel("Time on the coherence bus (\\%)")
    ax.set_ylim(0, 42)
    ax.legend(loc="upper right", ncol=1)
    fig.tight_layout(pad=0.25)
    p = os.path.join(OUT, "fig_stall.pdf")
    fig.savefig(p, bbox_inches="tight", pad_inches=0.01)
    print("wrote", p)


# -----------------------------------------------------------------------------
#  Figure 2 -- the result, and the mechanism behind it
# -----------------------------------------------------------------------------
def fig_result():
    kernels = ["matmul", "memcpy", "conv2d", "FFT"]
    # Against the NON-COHERENT baseline, not against the unfiltered coherent
    # design. That is the comparison a reader cares about -- what the cache
    # extension is worth at all -- and it is the one that shows memcpy crossing
    # back above parity, which the speedup-over-unfiltered numbers hide.
    unfiltered = [1.638, 0.975, 1.852, 1.329]
    filtered   = [2.002, 1.095, 2.017, 1.410]

    before = [483281, 7168, 20848, 6521]
    after = [1127, 1, 109, 2955]

    fig, (a1, a2) = plt.subplots(1, 2, figsize=(FULL, 1.95))

    bars(a1, kernels, ["unfiltered", "filtered"], [unfiltered, filtered],
         fmt="%.2f", rot=90)
    frame(a1)
    # Parity with having no data cache at all. memcpy starts below it.
    a1.axhline(1.0, color="#000000", linewidth=0.7, linestyle="--", zorder=4)
    # Below the rule and left of centre: above it collides with FFT's value
    # label, and the region under the rule is empty except for memcpy.
    a1.text(-0.42, 0.86, "parity with no data cache", fontsize=5.5, va="top")
    a1.set_ylabel(r"Speedup over no data cache ($\times$)")
    # Headroom for the upright value labels and the legend above them.
    a1.set_ylim(0, 2.9)
    a1.legend(loc="upper center", ncol=2)
    a1.text(0.5, -0.30, "(a) what the extension is worth",
            transform=a1.transAxes, ha="center", fontsize=7)

    # Log scale: the collapse spans three orders of magnitude, and on a linear
    # axis every kernel but matmul would be invisible.
    bars(a2, kernels, ["unfiltered", "filtered"], [before, after])
    frame(a2)
    a2.set_yscale("log")
    a2.set_ylim(0.5, 3e6)
    a2.set_yticks([1, 10, 100, 1000, 10000, 100000, 1000000])
    a2.set_yticklabels(["1", "10", "$10^2$", "$10^3$", "$10^4$", "$10^5$",
                        "$10^6$"])
    a2.yaxis.set_minor_locator(NullLocator())
    a2.yaxis.set_minor_formatter(NullFormatter())
    a2.set_ylabel("Cycles waiting on the bus")
    a2.legend(loc="upper right", ncol=2)
    a2.text(0.5, -0.30, "(b) why", transform=a2.transAxes, ha="center",
            fontsize=7)

    fig.tight_layout(pad=0.25)
    p = os.path.join(OUT, "fig_result.pdf")
    fig.savefig(p, bbox_inches="tight", pad_inches=0.01)
    print("wrote", p)


if __name__ == "__main__":
    fig_stall()
    fig_result()
