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
| WNS setup | +0.880 | +0.929 | |
| WHS hold | +0.003 | +0.010 | |
| Failing endpoints | 0 | 0 | |
| **Constraints met** | **yes** | **yes** | |

DRC clean in both: 64 checks, all DSP pipelining advisories, no errors.

The design also carries its program now. `ProgramHex` reaches the shared
instruction memory's `InitFile`, `$readmemh` runs at synthesis, and Vivado turns
it into the block RAM's `INIT` strings. Area is unchanged by it -- the same
26,635 and 21,518 LUTs as the build before, and the same 124 and 104 BRAM tiles
-- because the program fills memory that already existed.

## Verified on the routed netlist

`tb/system/tb_fpga_top.sv` drives the board's pins and loads nothing: the 300
MHz differential clock, `cpu_reset_i`, then `dip_i[0]`. Anything the cores
execute came out of the block RAM's own contents.

    powershell -File sim/run_fpga_sim.ps1                            # RTL
    vivado -mode batch -nojournal -source fpga/write_funcsim.tcl -tclargs coherent
    powershell -File sim/run_fpga_sim.ps1 -Netlist fpga/netlist_coherent.v

Both pass, five checks each: all four PEs finish and each reports
`exit_code == 1`. The netlist run tracks RTL cycle for cycle -- at
t = 336732000 both read `soc_edges=25243, done=1110` -- so implementation
introduced no functional divergence. Checks are taken at the flip-flops
(`u_soc/u_ctrl/done_o_reg[0..3]`, `exit_code_o_reg[...]`) because synthesis
renames every vector port; the LEDs cannot serve, since reading one 32-bit word
through the nibble walk costs seconds of simulated time.

That the netlist passes establishes three things at once: the program survived
synthesis, placement and routing into the RAMB36 INIT strings; the routed logic
computes the right answer; and the board interface works as built.

**Known, not fixed:** `fpga_top` says it leaves reset on its own "whether or not
the button is ever pressed". True on hardware, where configuration zeroes every
flop. Not true from an unknown state: `rst_cnt_q` is X, `X != '1'` is X, and
`rst_n_q` falls through to 1, so reset never asserts and the SoC stays full of X.
Initialisers on `rst_sync_q`, `rst_cnt_q` and `rst_n_q` would make simulation
match hardware and cost nothing at synthesis. The testbench works around it by
holding the button past glbl's 100 ns global reset, which is what a real press
does anyway.

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
| **both, 75 MHz, project, fix** | **met, +0.880 / +0.929 ns** |

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
