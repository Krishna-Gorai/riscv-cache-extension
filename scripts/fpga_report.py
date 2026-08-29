#!/usr/bin/env python3
"""Pull the headline numbers out of a Vivado run and print them as a table.

Reads fpga/reports_<variant>/ for each variant named on the command line and
prints utilisation, timing and power side by side, plus the coherent-minus-
baseline difference. That difference is the cost of the cache extension, which
is the quantity Table I of the paper reports.

    python scripts/fpga_report.py coherent baseline
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Site types worth reporting, in the order Table I would list them.
SITES = [
    ("CLB LUTs",       "LUT"),
    ("CLB Registers",  "FF"),
    ("CARRY8",         "CARRY8"),
    ("Block RAM Tile", "BRAM"),
    ("DSPs",           "DSP"),
    ("Bonded IOB",     "IOB"),
    ("BUFGCE",         "BUFGCE"),
]

TARGET_NS = 10.0   # 300 MHz board clock / BUFGCE_DIV of 3


def read(path):
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def cells_of(line):
    return [c.strip() for c in line.strip().strip("|").split("|")]


def util(text):
    """Rows of a report_utilization table: | name | used | ... | avail | util% |"""
    out = {}
    if not text:
        return out
    for line in text.splitlines():
        if not line.startswith("|"):
            continue
        cells = cells_of(line)
        if len(cells) < 3:
            continue
        for site, key in SITES:
            if cells[0] != site or key in out:
                continue
            try:
                used = int(cells[1])
            except ValueError:
                continue
            pct = avail = None
            for c in cells[2:]:
                try:
                    v = float(c)
                except ValueError:
                    continue
                if "." in c:
                    pct = v
                else:
                    avail = int(v)
            out[key] = (used, avail, pct)
    return out


def timing(text):
    """The design-wide row of a report_timing_summary.

    Setup, hold and pulse-width all sit on one row, in this order:
        WNS TNS TNS-failing TNS-total  WHS THS THS-failing THS-total  WPWS ...
    so the hold numbers are columns 4-7 of the same line, not a section of
    their own. Reading column 3 as the failing count picks up the *total*
    endpoint count instead, which reads as catastrophic failure on a design
    that in fact met every constraint.
    """
    out = {}
    if not text:
        return out
    lines = text.splitlines()
    num = re.compile(r"^-?\d+\.\d+$")
    for i, line in enumerate(lines):
        if not line.strip().startswith("WNS(ns)"):
            continue
        for nxt in lines[i + 1:i + 4]:
            f = nxt.split()
            if len(f) < 8 or not num.match(f[0]):
                continue
            out["WNS"] = float(f[0])
            out["TNS"] = float(f[1])
            out["failing"] = int(f[2])
            out["endpoints"] = int(f[3])
            out["WHS"] = float(f[4])
            out["THS"] = float(f[5])
            out["hold_failing"] = int(f[6])
            if len(f) > 8 and num.match(f[8]):
                out["WPWS"] = float(f[8])
            break
        if out:
            break
    out["met"] = "All user specified timing constraints are met." in text
    return out


def power(text):
    """Total / dynamic / static power and the estimate's confidence."""
    out = {}
    if not text:
        return out
    labels = (("Total On-Chip Power (W)", "total"),
              ("Dynamic (W)", "dynamic"),
              ("Device Static (W)", "static"))
    for line in text.splitlines():
        if not line.startswith("|"):
            continue
        cells = cells_of(line)
        if len(cells) < 2:
            continue
        for label, key in labels:
            if cells[0].startswith(label) and key not in out:
                try:
                    out[key] = float(cells[1])
                except ValueError:
                    pass
        if cells[0].startswith("Confidence Level"):
            out["confidence"] = cells[1]
    return out


def hier(text):
    """Every row of report_utilization -hierarchical, keyed by instance name."""
    out = {}
    if not text:
        return out
    hdr = None
    for line in text.splitlines():
        if not line.startswith("|"):
            continue
        cells = cells_of(line)
        if cells and cells[0] == "Instance":
            hdr = cells
            continue
        if hdr is None or len(cells) != len(hdr):
            continue
        row = {}
        for col, val in zip(hdr, cells):
            try:
                row[col] = int(float(val))
            except ValueError:
                row[col] = val
        out[cells[0]] = row
    return out


def load(variant):
    d = os.path.join(ROOT, "fpga", "reports_" + variant)
    return {
        "util":   util(read(os.path.join(d, "post_route_util.rpt"))),
        "timing": timing(read(os.path.join(d, "post_route_timing.rpt"))),
        "power":  power(read(os.path.join(d, "post_route_power.rpt"))),
        "hier":   hier(read(os.path.join(d, "post_route_util_hier.rpt"))),
        "dir":    d,
    }


def main():
    variants = sys.argv[1:] or ["coherent", "baseline"]
    data = {v: load(v) for v in variants}
    w = 14
    span = 26 + w * (len(variants) + (1 if len(variants) == 2 else 0))

    print()
    print("ZCU104   xczu7ev-ffvc1156-2-e   100 MHz target   post-route")
    print("=" * span)
    head = "%-26s" % "" + "".join("%*s" % (w, v) for v in variants)
    if len(variants) == 2:
        head += "%*s" % (w, "delta")
    print(head)
    print("-" * span)

    def row(label, fn, fmt="%s"):
        vals = [fn(data[v]) for v in variants]
        line = "%-26s" % label + "".join(
            "%*s" % (w, "n/a" if x is None else fmt % x) for x in vals)
        if len(variants) == 2 and all(isinstance(x, (int, float)) for x in vals):
            d = vals[0] - vals[1]
            line += "%*s" % (w, fmt.replace("%", "%+", 1) % d)
        print(line)

    for _site, key in SITES:
        row(key, lambda D, k=key: D["util"].get(k, (None,))[0], "%d")
    print()
    for _site, key in SITES:
        pcts = [data[v]["util"].get(key, (None, None, None))[2] for v in variants]
        if any(p is not None for p in pcts):
            print("%-26s" % (key + " (% of device)") + "".join(
                "%*s" % (w, "n/a" if p is None else "%.2f" % p) for p in pcts))

    print()
    row("WNS setup (ns)", lambda D: D["timing"].get("WNS"), "%.3f")
    row("WHS hold (ns)", lambda D: D["timing"].get("WHS"), "%.3f")
    row("WPWS pulse (ns)", lambda D: D["timing"].get("WPWS"), "%.3f")
    row("endpoints", lambda D: D["timing"].get("endpoints"), "%d")
    row("failing setup", lambda D: D["timing"].get("failing"), "%d")
    row("failing hold", lambda D: D["timing"].get("hold_failing"), "%d")
    row("Fmax (MHz)",
        lambda D: (None if D["timing"].get("WNS") is None
                   else 1000.0 / (TARGET_NS - D["timing"]["WNS"])), "%.2f")
    print("%-26s" % "all constraints met" + "".join(
        "%*s" % (w, "yes" if data[v]["timing"].get("met") else "NO") for v in variants))

    print()
    row("power total (W)", lambda D: D["power"].get("total"), "%.3f")
    row("power dynamic (W)", lambda D: D["power"].get("dynamic"), "%.3f")
    row("power static (W)", lambda D: D["power"].get("static"), "%.3f")
    print("%-26s" % "vectorless confidence" + "".join(
        "%*s" % (w, data[v]["power"].get("confidence", "n/a")) for v in variants))

    # Per-block breakdown, the Table I shape.
    cols = ("Total LUTs", "FFs", "RAMB36", "DSPs")
    for v in variants:
        h = data[v]["hier"]
        if not h:
            continue
        print()
        print("hierarchy -- %s" % v)
        print("  %-34s" % "instance" + "".join("%11s" % c for c in cols))
        for inst in sorted(h):
            if inst == "Instance":
                continue
            print("  %-34s" % inst + "".join(
                "%11s" % (h[inst].get(c, "-")) for c in cols))


if __name__ == "__main__":
    main()
