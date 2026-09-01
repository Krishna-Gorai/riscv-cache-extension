#!/usr/bin/env python3
"""Plot the measured results in the visual style of the paper being reproduced.

Kamaleldin et al.'s figures are Excel-style: a full box frame, a light grid,
square and diamond markers, a bordered legend sitting inside the plot area, and
a palette in which green is the cached configuration and red the uncached one.
Matching that is deliberate -- a reader comparing our figures against theirs
should be comparing the data, not decoding two different visual languages.

One departure, and it is not an oversight: their panels carry a bold title above
the axes. Ours put the panel's identity inside the frame instead, because a
title above the plot duplicates what the LaTeX caption already says.

    python scripts/plot_results.py

Writes paper/fig_capacity.pdf and paper/fig_speedup.pdf.
"""
import csv
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS = os.path.join(ROOT, "results")
OUT = os.path.join(ROOT, "paper")

# The reference's two-colour semantic: green is the cached case, red the
# uncached one. Our capacity figure has four configurations rather than two, so
# the scale runs from the paper's own configuration (red, the one that fails)
# through to the configuration that holds the working set (green).
GREEN = "#00B050"
DKGREEN = "#006F3C"
RED = "#FF0000"
AMBER = "#ED7D31"
BLUE = "#2E75B6"
PURPLE = "#7030A0"

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
    "pdf.fonttype": 42,
})


def frame(ax):
    """The reference's axes: closed box, light grid behind the data."""
    for side in ("top", "right", "bottom", "left"):
        ax.spines[side].set_visible(True)
    ax.grid(True, which="major", axis="both", **GRID)
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


# -----------------------------------------------------------------------------
#  Capacity: execution time and hit rate against problem size, four caches.
# -----------------------------------------------------------------------------
def fig_capacity():
    rows = read_csv("capacity.csv")

    series = [
        ("tb_bench",      "2-way 2 KiB (as stated)", RED,     "s", "-"),
        ("tb_bench_w4",   "4-way 2 KiB",             AMBER,   "D", "-"),
        ("tb_bench_c8k",  "2-way 8 KiB",             GREEN,   "s", "-"),
        ("tb_bench_c16k", "2-way 16 KiB",            DKGREEN, "^", "--"),
    ]

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(7.0, 2.45))

    for cfg, label, colour, marker, style in series:
        pts = [r for r in rows if r["config"] == cfg]
        pts.sort(key=lambda r: int(r["n"]))
        n = [int(r["n"]) for r in pts]
        cyc = [int(r["cycles"]) for r in pts]
        hit = [100.0 * int(r["rd_hit"]) / int(r["rd_tot"]) for r in pts]
        common = dict(color=colour, marker=marker, markersize=3.6,
                      linewidth=1.2, linestyle=style,
                      markeredgecolor=colour, markerfacecolor=colour)
        ax1.plot(n, cyc, label=label, **common)
        ax2.plot(n, hit, label=label, **common)

    for ax in (ax1, ax2):
        frame(ax)
        ax.set_xscale("log", base=2)
        ax.set_xticks([128, 256, 512, 1024])
        ax.set_xticklabels(["128", "256", "512", "1024"])
        ax.set_xlabel("FFT input size per sample", fontsize=7)

    # The limit is in cycles; only the tick labels are divided down. Setting it
    # in thousands silently empties the panel, because every data point then
    # sits three orders of magnitude above the top of the axis.
    ax1.yaxis.set_major_formatter(FuncFormatter(thousands))
    ax1.set_ylabel(r"Execution time (10$^3$ cycles)", fontsize=7)
    ax1.set_ylim(0, 640000)
    panel_label(ax1, "Execution time")
    ax1.legend(loc="upper left", fontsize=6, borderpad=0.4,
               handlelength=1.8, labelspacing=0.3)

    ax2.set_ylabel("Read hit rate (%)", fontsize=7)
    ax2.set_ylim(50, 102)
    panel_label(ax2, "Cache hit rate")

    # The cliff is the point of the figure, so it is annotated rather than left
    # for the reader to locate. Placed high and right of the knee, clear of the
    # curves and of the legend in the other panel.
    ax2.annotate("working set\nexceeds 2 KiB",
                 xy=(512, 66.0), xytext=(560, 84),
                 fontsize=6, color="#404040",
                 arrowprops=dict(arrowstyle="->", color="#404040", lw=0.7))

    fig.tight_layout(pad=0.4)
    out = os.path.join(OUT, "fig_capacity.pdf")
    fig.savefig(out, bbox_inches="tight")
    print("wrote", out)


# -----------------------------------------------------------------------------
#  Speedup against memory latency, per kernel.
# -----------------------------------------------------------------------------
def fig_speedup():
    rows = read_csv("memlat.csv")

    series = [
        ("memcpy_16k", "memcpy 16 KiB", RED,    "s"),
        ("fft_256",    "FFT N=256",     AMBER,  "D"),
        ("matmul_64",  "matmul 64x64",  BLUE,   "^"),
        ("conv2d_64",  "conv2d 64x64",  GREEN,  "o"),
    ]

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(7.0, 2.45))

    for kern, label, colour, marker in series:
        pts = [r for r in rows if r["kernel"] == kern]
        pts.sort(key=lambda r: int(r["memlat"]))
        lat = [int(r["memlat"]) for r in pts]
        sp = [float(r["speedup"]) for r in pts]
        coh = [int(r["coherent_cycles"]) for r in pts]
        nc = [int(r["noncoherent_cycles"]) for r in pts]
        common = dict(color=colour, marker=marker, markersize=3.6,
                      linewidth=1.2, markeredgecolor=colour,
                      markerfacecolor=colour)
        ax1.plot(lat, sp, label=label, **common)
        # Growth relative to the same build at the lowest latency, which is what
        # shows the cached build absorbing latency the baseline cannot.
        ax2.plot(lat, [100.0 * c / coh[0] for c in coh],
                 label=label + ", w/ cache", **common)
        ax2.plot(lat, [100.0 * c / nc[0] for c in nc],
                 color=colour, marker=marker, markersize=3.6, linewidth=1.2,
                 linestyle=":", markerfacecolor="white",
                 markeredgecolor=colour)

    frame(ax1)
    ax1.axhline(1.0, color="#404040", linewidth=0.9, linestyle="--")
    ax1.text(2.4, 1.06, "break-even", fontsize=6, color="#404040")
    ax1.set_xticks([2, 8, 20])
    ax1.set_xlabel("Shared memory latency (cycles)", fontsize=7)
    ax1.set_ylabel(r"Speedup over no data cache ($\times$)", fontsize=7)
    ax1.set_ylim(0, 8.6)
    panel_label(ax1, "Speedup")
    ax1.legend(loc="upper left", fontsize=6, borderpad=0.4,
               handlelength=1.8, labelspacing=0.3)

    frame(ax2)
    ax2.set_xticks([2, 8, 20])
    ax2.set_xlabel("Shared memory latency (cycles)", fontsize=7)
    ax2.set_ylabel("Cycles, relative to latency 2 (%)", fontsize=7)
    # Log scale, because the two builds separate by a factor rather than an
    # amount. Minor ticks are cleared explicitly: left on, the log locator adds
    # its own labelled decade marker among the chosen ticks.
    ax2.set_yscale("log")
    ax2.set_yticks([100, 200, 400, 600])
    ax2.set_yticklabels(["100", "200", "400", "600"])
    ax2.yaxis.set_minor_locator(matplotlib.ticker.NullLocator())
    ax2.yaxis.set_minor_formatter(matplotlib.ticker.NullFormatter())
    panel_label(ax2, "Sensitivity to latency")
    ax2.text(0.97, 0.06,
             "solid: with data cache\ndotted: without",
             transform=ax2.transAxes, ha="right", va="bottom", fontsize=6,
             color="#404040",
             bbox=dict(boxstyle="square,pad=0.3", facecolor="white",
                       edgecolor="#808080", linewidth=0.6))

    fig.tight_layout(pad=0.4)
    out = os.path.join(OUT, "fig_speedup.pdf")
    fig.savefig(out, bbox_inches="tight")
    print("wrote", out)


if __name__ == "__main__":
    fig_capacity()
    fig_speedup()
