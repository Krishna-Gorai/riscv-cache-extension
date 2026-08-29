# =============================================================================
#  run_impl.tcl -- synthesis and implementation of fpga_top on a ZCU104.
#
#  Usage (from the repository root):
#     vivado -mode batch -source fpga/run_impl.tcl -tclargs coherent 10.0
#     vivado -mode batch -source fpga/run_impl.tcl -tclargs baseline 10.0
#
#  argv:  0  variant   coherent | baseline   -- soc_top's Coherent parameter
#         1  period    SoC clock period in ns (informational: the real period
#                      comes from the 300 MHz board clock divided by ClkDiv,
#                      so this only picks ClkDiv)
#
#  Non-project mode throughout: no .xpr, no IP, nothing to regenerate. The
#  design is RTL plus two Xilinx primitives (IBUFDS, BUFGCE_DIV) plus the four
#  BUFGCEs that gate the cores' clocks.
#
#  The two variants differ in exactly one parameter, so the difference between
#  their utilisation reports is the cost of the cache extension -- which is the
#  number Table I of the paper states.
# =============================================================================

set root [file normalize [file join [file dirname [info script]] ..]]

set variant [lindex $argv 0]
set period  [lindex $argv 1]
if {$variant eq ""} { set variant "coherent" }
if {$period  eq ""} { set period  10.0 }

switch -- $variant {
  coherent { set coh 1 }
  baseline { set coh 0 }
  default  { error "variant must be 'coherent' or 'baseline', got '$variant'" }
}

# 300 MHz board clock / ClkDiv = SoC clock. BUFGCE_DIV divides by 1..8.
set clkdiv [expr {int(round($period / (1000.0/300.0)))}]
if {$clkdiv < 1} { set clkdiv 1 }
if {$clkdiv > 8} { set clkdiv 8 }
set actual_period [expr {$clkdiv * 1000.0/300.0}]
set actual_freq   [expr {1000.0/$actual_period}]

set outdir [file join $root fpga reports_$variant]
file mkdir $outdir

puts "=============================================================="
puts " variant   : $variant  (Coherent=$coh)"
puts " ClkDiv    : $clkdiv   -> [format %.3f $actual_period] ns  ([format %.2f $actual_freq] MHz)"
puts " reports   : $outdir"
puts "=============================================================="

# Keep the tool inside the memory this host has.
set_param general.maxThreads 2

set part xczu7ev-ffvc1156-2-e

# -----------------------------------------------------------------------------
#  Sources. Same order the simulator compiles them in, minus the behavioural
#  clock gate, which its own header forbids for FPGA synthesis, plus the BUFGCE
#  cell that replaces it.
# -----------------------------------------------------------------------------
set cv     [file join $root vendor cv32e40p]
set cv_rtl [file join $cv rtl]

set cv_srcs {}
foreach f {
  include/cv32e40p_apu_core_pkg.sv include/cv32e40p_fpu_pkg.sv
  include/cv32e40p_pkg.sv
  cv32e40p_if_stage.sv cv32e40p_cs_registers.sv
  cv32e40p_register_file_ff.sv cv32e40p_load_store_unit.sv
  cv32e40p_id_stage.sv cv32e40p_aligner.sv cv32e40p_decoder.sv
  cv32e40p_compressed_decoder.sv cv32e40p_fifo.sv
  cv32e40p_prefetch_buffer.sv cv32e40p_hwloop_regs.sv
  cv32e40p_mult.sv cv32e40p_int_controller.sv cv32e40p_ex_stage.sv
  cv32e40p_alu_div.sv cv32e40p_alu.sv cv32e40p_ff_one.sv
  cv32e40p_popcnt.sv cv32e40p_apu_disp.sv cv32e40p_controller.sv
  cv32e40p_obi_interface.sv cv32e40p_prefetch_controller.sv
  cv32e40p_sleep_unit.sv cv32e40p_core.sv cv32e40p_top.sv
} { lappend cv_srcs [file join $cv_rtl $f] }

set prj_srcs {}
foreach f {
  rtl/include/cache_pkg.sv
  rtl/cache/cache_ram.sv rtl/cache/dcu_hcl.sv rtl/cache/dcu.sv rtl/cache/dcu_bypass.sv
  rtl/axi/axi_xbar.sv rtl/axi/axi_sram.sv rtl/axi/axi_ctrl.sv
  rtl/axi/axi_master_simple.sv rtl/axi/axi_master_dcu.sv
  rtl/snoop/rr_arbiter.sv rtl/snoop/invalidation_table.sv
  rtl/snoop/link_register.sv rtl/snoop/snoopy_bus.sv
  rtl/soc/coherent_subsystem.sv
  rtl/pe/bridge_router.sv rtl/pe/itcm.sv rtl/pe/instr_bridge.sv
  rtl/pe/data_bridge.sv rtl/pe/pe_top.sv
  rtl/soc/soc_top.sv
  fpga/cv32e40p_fpga_clock_gate.sv
  fpga/fpga_top.sv
} { lappend prj_srcs [file join $root $f] }

read_verilog -sv [concat $cv_srcs $prj_srcs]
read_xdc [file join $root fpga zcu104.xdc]

# -----------------------------------------------------------------------------
#  Synthesis
# -----------------------------------------------------------------------------
synth_design -top fpga_top -part $part \
  -include_dirs [list [file join $cv_rtl include]] \
  -generic Coherent=$coh \
  -generic ClkDiv=$clkdiv \
  -verilog_define SYNTHESIS

write_checkpoint -force [file join $outdir post_synth.dcp]
report_utilization       -file [file join $outdir post_synth_util.rpt]
report_timing_summary    -file [file join $outdir post_synth_timing.rpt]

# -----------------------------------------------------------------------------
#  Implementation
# -----------------------------------------------------------------------------
opt_design
place_design
phys_opt_design
route_design

write_checkpoint -force [file join $outdir post_route.dcp]

# -----------------------------------------------------------------------------
#  Reports. The hierarchical utilisation is the one Table I is read from: it
#  separates the SoC from the board wrapper, and inside the SoC it separates
#  the caches and the snoopy bus from the cores and the interconnect.
# -----------------------------------------------------------------------------
report_utilization        -file [file join $outdir post_route_util.rpt]
report_utilization -hierarchical -hierarchical_depth 5 \
                          -file [file join $outdir post_route_util_hier.rpt]
report_timing_summary  -delay_type min_max -max_paths 10 -report_unconstrained \
                          -file [file join $outdir post_route_timing.rpt]
report_timing -sort_by group -max_paths 20 -path_type summary \
                          -file [file join $outdir post_route_paths.rpt]
report_clock_utilization  -file [file join $outdir post_route_clock.rpt]
report_power              -file [file join $outdir post_route_power.rpt]
report_drc                -file [file join $outdir post_route_drc.rpt]
report_ram_utilization    -file [file join $outdir post_route_ram.rpt]

# -----------------------------------------------------------------------------
#  One-line summary, so a sweep can be read without opening the reports.
# -----------------------------------------------------------------------------
set wns  [get_property SLACK [get_timing_paths -delay_type max]]
set whs  [get_property SLACK [get_timing_paths -delay_type min]]
set fmax [expr {1000.0 / ($actual_period - $wns)}]

set fh [open [file join $outdir summary.txt] w]
puts $fh "variant        $variant (Coherent=$coh)"
puts $fh "part           $part"
puts $fh "clk_period_ns  [format %.3f $actual_period]"
puts $fh "clk_freq_mhz   [format %.2f $actual_freq]"
puts $fh "wns_ns         [format %.3f $wns]"
puts $fh "whs_ns         [format %.3f $whs]"
puts $fh "fmax_mhz       [format %.2f $fmax]"
close $fh

puts "=============================================================="
puts " $variant: WNS [format %.3f $wns] ns, WHS [format %.3f $whs] ns, Fmax [format %.2f $fmax] MHz"
puts "=============================================================="
