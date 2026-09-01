# Which numbers are the numbers

Four configurations were built on the ZCU104 (`xczu7ev-ffvc1156-2-e`). Only the
last one closes timing in both variants, and it is the one to quote.

## Current: 75 MHz with the reset fix — `reports_prj_*/`

Built from the managed projects (`fpga/run_project.tcl`), Vivado default
strategies, `ClkDiv=4` and `(* MAX_FANOUT = 200 *)` on `rst_n_q`.

| | coherent | baseline | delta |
|---|---:|---:|---:|
| LUT | 26,635 | 21,518 | **+5,117** |
| FF | 15,155 | 11,668 | **+3,487** |
| CARRY8 | 548 | 412 | +136 |
| BRAM tiles | 124 | 104 | +20 |
| DSP | 20 | 20 | 0 |
| WNS setup | +0.530 | +1.273 | |
| WHS hold | +0.012 | +0.011 | |
| Removal (`async_default`) | +0.061 | +0.048 | |
| Failing endpoints | 0 | 0 | |
| **Constraints met** | **yes** | **yes** | |

DRC clean in both: 64 checks, all DSP pipelining advisories, no errors.

## Superseded: `reports_coherent/` and `reports_baseline/`

These hold the **100 MHz build with the reset fix**, a configuration that was
tried and rejected: `reports_baseline/summary.txt` reports `wns_ns -1.475` with
1546 failing setup endpoints. They are kept because the comparison is the
argument for the current configuration, not because they describe it. The batch
flow has not been re-run at 75 MHz, so these two directories and
`reports_prj_*/` are not the same configuration and their rows must not be mixed.

## How it got here

| build | outcome |
|---|---|
| coherent, 100 MHz, batch, no fix | met — by 12 ps |
| coherent, 100 MHz, project, no fix | failed: 1719 removal |
| baseline, 100 MHz, batch, no fix | failed: 1899 removal |
| baseline, 100 MHz, batch, fix | failed: 1546 setup, −1.475 ns |
| **both, 75 MHz, project, fix** | **met, +0.530 / +1.273 ns** |

Two things this sequence establishes. The 100 MHz coherent result that reads
"all constraints met" passed by twelve picoseconds and failed in two other
placements of the same RTL, so it was placement luck rather than a property of
the design. And the cache extension's cost is a property of the design: +5,127
LUT at 100 MHz against +5,117 here, essentially unchanged by the configuration
around it.

## On 75 MHz

The clock is the 300 MHz board clock through one `BUFGCE_DIV`, which divides by
an integer 1..8, so the reachable frequencies are 150, 100, 75, 60 MHz and so
on -- there is nothing between 100 and 75, and 87 MHz would need an MMCM this
design deliberately does not instantiate.

The paper being reproduced targets an XCVU9P at 60 MHz, so 75 MHz is 25% above
its operating point, on a smaller device, with timing closed rather than met by
a hair.

## Not yet trustworthy

Power in every report here is Vivado's vectorless estimate at **Low**
confidence: it cannot evaluate the BUFGCE core clock enables, so it models the
cores as idle and reports under a milliwatt of register power for fifteen
thousand flops. The SAIF flow exists (`fpga/power_saif.tcl`, `run_xsim.ps1
-Saif`) and the coherent capture is done; the baseline capture and both
`report_power` runs are not. **Do not quote the dynamic figures.**
