#!/usr/bin/env python3
"""Print post-implementation utilisation in the shape of the paper's Table I.

Table I is a per-module resource breakdown, not a device total: the paper gives
the PE and its parts, the cache extension and its parts, and the interconnect
each their own line. fpga_report.py answers "what did the extension cost"; this
answers "where does the area go", which is the question Table I asks.

    python scripts/table1.py coherent
    python scripts/table1.py baseline
    python scripts/table1.py coherent --latex

Numbers come from post_route_util_hier.rpt, so they are placed-and-routed.
"""
import io
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NPE = 4

COLS = ("Total LUTs", "FFs", "RAMB36", "RAMB18", "DSP Blocks")


def parse(variant):
    """Full instance path -> resource row, rebuilt from the report's indentation.

    The report prints bare instance names indented by depth, so u_core appears
    four times. Walking a stack turns those back into unique paths.
    """
    path = os.path.join(ROOT, "fpga", "reports_" + variant,
                        "post_route_util_hier.rpt")
    if not os.path.exists(path):
        sys.exit("missing report: " + path)
    rows, hdr, stack = {}, None, []
    for line in io.open(path, encoding="utf-8", errors="replace"):
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        raw = line.strip().strip("|").split("|")[0]
        if cells[0] == "Instance":
            hdr = cells
            continue
        if hdr is None or len(cells) != len(hdr):
            continue
        depth = (len(raw) - len(raw.lstrip())) // 2
        name = cells[0]
        del stack[depth:]
        stack.append(name)
        vals = {}
        for col, val in zip(hdr, cells):
            try:
                vals[col] = int(val)
            except ValueError:
                pass
        rows["/".join(stack)] = vals
    return rows


ZERO = dict.fromkeys(COLS, 0)


def get(rows, path):
    return rows.get(path, ZERO)


def add(*items):
    return {c: sum(i.get(c, 0) for i in items) for c in COLS}


def sub(a, b):
    return {c: a.get(c, 0) - b.get(c, 0) for c in COLS}


def pe_sum(rows, tail):
    """Sum one per-PE instance across all four PEs."""
    return add(*[get(rows, "fpga_top/u_soc/g_pe[%d].u_pe%s" % (p, tail))
                 for p in range(NPE)])


def masters(rows):
    return add(*[get(rows, "fpga_top/u_soc/g_pe[%d].%s" % (p, m))
                 for p in range(NPE)
                 for m in ("u_axi_dcu", "u_axi_ext", "u_axi_ifetch")])


def build(rows, variant):
    """(label, instances, resources, is_subtotal) in Table I order."""
    soc = "fpga_top/u_soc/"
    pes = pe_sum(rows, "")
    core = pe_sum(rows, "/u_core")
    dbr = pe_sum(rows, "/u_data_bridge")
    axim = masters(rows)
    # The ITCM and the Instruction-Bridge sit below the report's depth limit;
    # what the PE holds beyond the core and the Data-Bridge is exactly those.
    itcm = sub(pes, add(core, dbr))

    t = [("Processing Element (PE)", NPE, add(pes, axim), True),
         ("  RISC-V core (CV32E40P)", NPE, core, False),
         ("  ITCM + Instruction-Bridge", NPE, itcm, False),
         ("  Data-Bridge", NPE, dbr, False),
         ("  AXI4 masters (3 per PE)", NPE * 3, axim, False)]

    if variant == "baseline":
        byp = add(*[get(rows, soc + "g_nodcache.g_bypass[%d].u_bypass" % p)
                    for p in range(NPE)])
        t += [("Cache bypass shim", NPE, byp, True)]
    else:
        dcus = add(*[get(rows, soc + "g_dcache.u_dcache/g_dcu[%d].u_dcu" % p)
                     for p in range(NPE)])
        ctrl = add(*[get(rows, soc + "g_dcache.u_dcache/g_dcu[%d].u_dcu/(g_dcu[%d].u_dcu)" % (p, p))
                     for p in range(NPE)])
        tag = add(*[get(rows, soc + "g_dcache.u_dcache/g_dcu[%d].u_dcu/u_tag_ram" % p)
                    for p in range(NPE)])
        dat = add(*[get(rows, soc + "g_dcache.u_dcache/g_dcu[%d].u_dcu/u_data_ram" % p)
                    for p in range(NPE)])
        bus = get(rows, soc + "g_dcache.u_dcache/u_snoopy_bus")
        t += [("Cache extension", 1, get(rows, soc + "g_dcache.u_dcache"), True),
              ("  Data Cache Unit (DCU)", NPE, dcus, False),
              ("    controller + HCL", NPE, ctrl, False),
              ("    tag RAM", NPE, tag, False),
              ("    data RAM", NPE, dat, False),
              ("  Snoopy bus", 1, bus, False),
              ("    round-robin arbiter", 1,
               get(rows, soc + "g_dcache.u_dcache/u_snoopy_bus/u_inv_arb"), False),
              ("    invalidation table", 1,
               get(rows, soc + "g_dcache.u_dcache/u_snoopy_bus/u_inv_table"), False)]

    t += [("AXI4 crossbar", 1, get(rows, soc + "u_xbar"), True),
          ("Shared data memory", 1, get(rows, soc + "u_sdmem"), True),
          ("Shared instruction memory", 1, get(rows, soc + "u_simem"), True),
          ("Control region", 1, get(rows, soc + "u_ctrl"), True),
          ("Total SoC", 1, get(rows, "fpga_top/u_soc"), True)]
    return t


def bram(r):
    """Block RAM tiles: a RAMB18 is half a tile, which is how the device counts."""
    tiles = r.get("RAMB36", 0) + r.get("RAMB18", 0) / 2.0
    return "%d" % tiles if tiles == int(tiles) else "%.1f" % tiles


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    latex = "--latex" in sys.argv
    variant = args[0] if args else "coherent"
    rows = parse(variant)
    table = build(rows, variant)

    if latex:
        print(r"\begin{tabular}{lrrrrr}")
        print(r"\hline")
        print(r"Module & $\times$ & LUTs & FFs & BRAM & DSPs \\")
        print(r"\hline")
        for label, n, r, top in table:
            lbl = label.strip()
            ind = len(label) - len(label.lstrip())
            lbl = (r"\quad " * (ind // 2)) + (r"\textbf{%s}" % lbl if top else lbl)
            print(r"%s & %d & %d & %d & %s & %d \\" %
                  (lbl, n, r["Total LUTs"], r["FFs"], bram(r), r["DSP Blocks"]))
        print(r"\hline")
        print(r"\end{tabular}")
        return

    print()
    # The clock is whatever the build was constrained to, not a constant: a
    # header that says 100 MHz over a 75 MHz build is a quietly wrong number in
    # the one place a reader trusts without checking.
    freq = None
    smpath = os.path.join(ROOT, "fpga", "reports_" + variant, "summary.txt")
    sm = ""
    if os.path.exists(smpath):
        sm = io.open(smpath, encoding="utf-8", errors="replace").read()
    for line in sm.splitlines():
        f = line.split()
        if len(f) == 2 and f[0] == "clk_freq_mhz":
            try:
                freq = float(f[1])
            except ValueError:
                pass
    print("TABLE I.  POST-IMPLEMENTATION RESOURCE UTILISATION -- %s"
          % variant.upper())
    print("          ZCU104, xczu7ev-ffvc1156-2-e, %s, %d PEs"
          % ("%.0f MHz" % freq if freq else "unknown clock", NPE))
    print()
    print("%-30s %4s %8s %8s %7s %6s" % ("Module", "x", "LUTs", "FFs", "BRAM", "DSPs"))
    print("-" * 68)
    for label, n, r, top in table:
        if top and label != "Total SoC":
            print()
        if label == "Total SoC":
            print("-" * 68)
        print("%-30s %4d %8d %8d %7s %6d"
              % (label, n, r["Total LUTs"], r["FFs"], bram(r), r["DSP Blocks"]))
    print()
    dev = get(rows, "fpga_top")
    print("Device total incl. board wrapper: %d LUT, %d FF, %s BRAM, %d DSP"
          % (dev["Total LUTs"], dev["FFs"], bram(dev), dev["DSP Blocks"]))
    print("A RAMB18 counts as half a Block RAM tile.")
    print("Sub-rows may exceed their parent: LUTs combine across hierarchy.")


if __name__ == "__main__":
    main()
