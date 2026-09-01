#!/usr/bin/env python3
"""Plot the measured results in the visual style of the paper being reproduced.

Kamaleldin et al.'s figures are Excel-style: a closed box frame, a light grid, a
bordered legend inside the plot area, execution time in thousands of cycles, and
a palette in which green is the cached configuration and red the uncached one.
Matching that is deliberate -- a reader holding our figures against theirs
should be comparing data, not decoding two visual languages.

Their Fig. 6 is a grouped bar chart, and grouped bars are the default here for a
reason beyond fidelity: several of our series carry identical values, and as
lines they superimpose exactly. The 8 KiB and 16 KiB capacity curves are the
same numbers at every point, which is the saturation the capacity claim rests
on -- but drawn as lines it reads as a missing series rather than as a result.
As bars the two stand side by side at equal height and the point makes itself.

Bars are additionally hatched, so the figures survive a greyscale print.

    python scripts/plot_results.py              # grouped bars (default)
    python scripts/plot_results.py --style line # the line version, for comparison

Writes paper/fig_capacity.pdf and paper/fig_speedup.pdf.
"""
import csv
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter, NullFormatter, NullLocator

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS = os.path.join(ROOT, "results")
OUT = os.path.join(ROOT, "paper")

# The reference's two-colour semantic, extended: our capacity figure has four
# configurations where theirs has two, so the scale runs from the paper's own
# configuration (red, the one that fails) to the one that holds the working set.
RED = "#FF0000"
AMBER = "#ED7D31"
GREEN = "#00B050"
DKGREEN = "#006F3C"
BLUE = "#2E75B6"

GRID = dict(color="#BFBFBF", linewidth=0.5, linestyle="-", alpha=0.9)

plt.rcParams.update({
    "font.family": "sans-serif",
    "font.sans-serif": ["Arial", "DejaVu Sans"],
    "font.size": 7,
    "axes.linewidth": 0.8,
    "axes.edgecolor": "#404040",
    "xtick.direction": "out",
    "ytick.direction": "out",
    "xtick.major.size": 2.5,
    "ytick.major.size": 2.5,
    "legend.fancybox": False,
    "legend.framealpha": 1.0,
    "legend.edgecolor": "#808080",
    "hatch.linewidth": 0.5,
    "pdf.fonttype": 42,
})


def frame(ax, bars=False):
    """The reference's axes: closed box, light grid behind the data.

    Bar charts get horizontal gridlines only. Vertical ones cut through the bars
    and read as noise, since the categories are already separated by position.
    """
    for side in ("top", "right", "bottom", "left"):
        ax.spines[side].set_visible(True)
    ax.grid(True, axis="y" if bars else "both", **GRID)
    ax.set_axisbelow(True)
    ax.tick_params(labelsize=6.5)


def panel_label(ax, text):
    """Panel identity inside the frame rather than titled above it."""
    ax.text(0.5, 1.015, text, transform=ax.transAxes, ha="center", va="bottom",
            fontsize=7, fontweight="bold")


def read_csv(name):
    path = os.path.join(RESULTS, name)
    if not os.path.exists(path):
        sys.exit("missing %s -- run the sweep that produces it first" % path)
    with open(path, newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def thousands(x, _pos):
    return "%g" % (x / 1000.0)


def grouped_bars(ax, groups, series, values, colours, hatches):
    """One cluster per group, one bar per series, hatched for greyscale."""
    n = len(series)
    width = 0.8 / n
    xs = range(len(groups))
    for i, name in enumerate(series):
        offs = [x - 0.4 + width * (i + 0.5) for x in xs]
        ax.bar(offs, values[i], width=width * 0.92, label=name,
               color=colours[i], edgecolor="#333333", linewidth=0.5,
               hatch=hatches[i], zorder=3)
    ax.set_xticks(list(xs))
    ax.set_xticklabels(groups)
    ax.set_xlim(-0.5, len(groups) - 0.5)


# -----------------------------------------------------------------------------
#  Capacity: execution time and hit rate against problem size, four caches.
# -----------------------------------------------------------------------------
CAP_SERIES = [
    ("tb_bench",      "2-way 2 KiB (as stated)", RED,     "s", "-",  ""),
    ("tb_bench_w4",   "4-way 2 KiB",             AMBER,   "D", "-",  "///"),
    ("tb_bench_c8k",  "2-way 8 KiB",             GREEN,   "s", "-",  "..."),
    ("tb_bench_c16k", "2-way 16 KiB",            DKGREEN, "^", "--", "xxx"),
]


def fig_capacity(style):
    rows = read_csv("capacity.csv")
    sizes = [128, 256, 512, 1024]

    cyc, hit = [], []
    for cfg, _lbl, _c, _m, _ls, _h in CAP_SERIES:
        pts = sorted((r for r in rows if r["config"] == cfg),
                     key=lambda r: int(r["n"]))
        cyc.append([int(r["cycles"]) for r in pts])
        hit.append([100.0 * int(r["rd_hit"]) / int(r["rd_tot"]) for r in pts])

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(7.0, 2.5))
    labels = [s[1] for s in CAP_SERIES]
    colours = [s[2] for s in CAP_SERIES]
    hatches = [s[5] for s in CAP_SERIES]

    if style == "bar":
        groups = [str(n) for n in sizes]
        grouped_bars(ax1, groups, labels, cyc, colours, hatches)
        grouped_bars(ax2, groups, labels, hit, colours, hatches)
        frame(ax1, bars=True)
        frame(ax2, bars=True)
        # Hit rate starts at 50 so the collapse is not compressed into the top
        # tenth of the panel; the axis break is obvious from the tick labels.
        ax2.set_ylim(50, 104)
    else:
        for i, (_cfg, lbl, colour, marker, ls, _h) in enumerate(CAP_SERIES):
            common = dict(color=colour, marker=marker, markersize=3.6,
                          linewidth=1.2, linestyle=ls,
                          markeredgecolor=colour, markerfacecolor=colour)
            ax1.plot(sizes, cyc[i], label=lbl, **common)
            ax2.plot(sizes, hit[i], label=lbl, **common)
        for ax in (ax1, ax2):
            frame(ax)
            ax.set_xscale("log", base=2)
            ax.set_xticks(sizes)
            ax.set_xticklabels([str(n) for n in sizes])
        ax2.set_ylim(50, 102)

    for ax in (ax1, ax2):
        ax.set_xlabel("FFT input size per sample", fontsize=7)

    ax1.yaxis.set_major_formatter(FuncFormatter(thousands))
    ax1.set_ylabel(r"Execution time (10$^3$ cycles)", fontsize=7)
    ax1.set_ylim(0, 640000)
    panel_label(ax1, "Execution time")
    ax1.legend(loc="upper left", fontsize=6, borderpad=0.4,
               handlelength=1.6, labelspacing=0.3)

    ax2.set_ylabel("Read hit rate (%)", fontsize=7)
    panel_label(ax2, "Cache hit rate")
    # Placed in the gap the collapse itself opens up, above the two short bars
    # at N=512 and N=1024, which is the only clear region in the panel.
    if style == "bar":
        ax2.annotate("working set\nexceeds 2 KiB", xy=(1.87, 66.8),
                     xytext=(2.42, 78), fontsize=6, color="#404040",
                     ha="left",
                     arrowprops=dict(arrowstyle="->", color="#404040", lw=0.7))
    else:
        ax2.annotate("working set\nexceeds 2 KiB", xy=(512, 66.0),
                     xytext=(545, 84), fontsize=6, color="#404040",
                     arrowprops=dict(arrowstyle="->", color="#404040", lw=0.7))

    fig.tight_layout(pad=0.4)
    out = os.path.join(OUT, "fig_capacity.pdf")
    fig.savefig(out, bbox_inches="tight")
    print("wrote", out)


# -----------------------------------------------------------------------------
#  Speedup against memory latency, per kernel.
# -----------------------------------------------------------------------------
LAT_SERIES = [
    ("memcpy_16k", "memcpy 16 KiB", RED,     "s", ""),
    ("fft_256",    "FFT N=256",     AMBER,   "D", "///"),
    ("matmul_64",  "matmul 64x64",  BLUE,    "^", "..."),
    ("conv2d_64",  "conv2d 64x64",  GREEN,   "o", "xxx"),
]


def fig_speedup(style):
    rows = read_csv("memlat.csv")
    lats = [2, 8, 20]

    sp, growth_c, growth_n = [], [], []
    for kern, _lbl, _c, _m, _h in LAT_SERIES:
        pts = sorted((r for r in rows if r["kernel"] == kern),
                     key=lambda r: int(r["memlat"]))
        sp.append([float(r["speedup"]) for r in pts])
        coh = [int(r["coherent_cycles"]) for r in pts]
        nc = [int(r["noncoherent_cycles"]) for r in pts]
        growth_c.append([100.0 * c / coh[0] for c in coh])
        growth_n.append([100.0 * c / nc[0] for c in nc])

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(7.0, 2.5))
    labels = [s[1] for s in LAT_SERIES]
    colours = [s[2] for s in LAT_SERIES]
    hatches = [s[4] for s in LAT_SERIES]
    groups = [str(l) for l in lats]

    if style == "bar":
        grouped_bars(ax1, groups, labels, sp, colours, hatches)
        frame(ax1, bars=True)
    else:
        for i, (_k, lbl, colour, marker, _h) in enumerate(LAT_SERIES):
            ax1.plot(lats, sp[i], label=lbl, color=colour, marker=marker,
                     markersize=3.6, linewidth=1.2, markerfacecolor=colour,
                     markeredgecolor=colour)
        frame(ax1)
        ax1.set_xticks(lats)

    ax1.axhline(1.0, color="#404040", linewidth=0.9, linestyle="--", zorder=4)
    ax1.text(0.015, 1.12 / 8.6, "break-even", transform=ax1.transAxes,
             fontsize=6, color="#404040")
    ax1.set_xlabel("Shared memory latency (cycles)", fontsize=7)
    ax1.set_ylabel(r"Speedup over no data cache ($\times$)", fontsize=7)
    ax1.set_ylim(0, 8.6)
    panel_label(ax1, "Speedup")
    ax1.legend(loc="upper left", fontsize=6, borderpad=0.4,
               handlelength=1.6, labelspacing=0.3)

    # The second panel contrasts two populations rather than four series, so it
    # stays a line plot: the story is that one bundle of curves is flat and the
    # other climbs, and bars would break that into eight separate readings.
    for i, (_k, lbl, colour, marker, _h) in enumerate(LAT_SERIES):
        ax2.plot(lats, growth_c[i], color=colour, marker=marker,
                 markersize=3.4, linewidth=1.2, markerfacecolor=colour,
                 markeredgecolor=colour, label=lbl)
        ax2.plot(lats, growth_n[i], color=colour, marker=marker,
                 markersize=3.4, linewidth=1.2, linestyle=":",
                 markerfacecolor="white", markeredgecolor=colour)
    frame(ax2)
    ax2.set_xticks(lats)
    ax2.set_xlabel("Shared memory latency (cycles)", fontsize=7)
    ax2.set_ylabel("Cycles, relative to latency 2 (%)", fontsize=7)
    ax2.set_yscale("log")
    ax2.set_yticks([100, 200, 400, 600])
    ax2.set_yticklabels(["100", "200", "400", "600"])
    ax2.yaxis.set_minor_locator(NullLocator())
    ax2.yaxis.set_minor_formatter(NullFormatter())
    panel_label(ax2, "Sensitivity to latency")
    ax2.text(0.97, 0.06, "solid: with data cache\ndotted: without",
             transform=ax2.transAxes, ha="right", va="bottom", fontsize=6,
             color="#404040",
             bbox=dict(boxstyle="square,pad=0.3", facecolor="white",
                       edgecolor="#808080", linewidth=0.6))

    fig.tight_layout(pad=0.4)
    out = os.path.join(OUT, "fig_speedup.pdf")
    fig.savefig(out, bbox_inches="tight")
    print("wrote", out)


if __name__ == "__main__":
    style = "line" if "--style" in sys.argv and "line" in sys.argv else "bar"
    print("style:", style)
    fig_capacity(style)
    fig_speedup(style)
