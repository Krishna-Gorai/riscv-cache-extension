# =============================================================================
#  run_project.tcl -- run synthesis and implementation inside the GUI project.
#
#  Usage:  vivado -mode batch -source fpga/run_project.tcl -tclargs coherent
#
#  This drives the managed project created by create_project.tcl, i.e. the same
#  runs the GUI's "Run Synthesis" and "Run Implementation" buttons launch.
#
#  It does NOT reproduce the committed numbers, and is not meant to. run_impl.tcl
#  calls synth_design directly with tool defaults; synth_1 here carries the
#  Flow_PerfOptimized_high strategy and impl_1 the default implementation
#  strategy, so the results are a second, legitimate data point rather than the
#  same one. They are written to fpga/reports_prj_<variant>/ so that nothing can
#  be confused with fpga/reports_<variant>/, which is the flow of record.
#
#  A GUI holding the project open takes a write lock; close it before running.
# =============================================================================

set root [file normalize [file join [file dirname [info script]] ..]]

set variant [lindex $argv 0]
if {$variant eq ""} { set variant "coherent" }
if {$variant ni {coherent baseline}} {
  error "variant must be 'coherent' or 'baseline', got '$variant'"
}

set xpr    [file join $root fpga vivado_prj_$variant $variant.xpr]
set outdir [file join $root fpga reports_prj_$variant]
if {![file exists $xpr]} {
  error "no project at $xpr -- run fpga/create_project.tcl -tclargs $variant first"
}
file mkdir $outdir

# Keep the tool inside the memory this host has: 8 GB, and place_design alone
# peaks above 5 GB.
set_param general.maxThreads 2

open_project $xpr
puts "opened [current_project]  (Coherent=[get_property generic [get_filesets sources_1]])"

# Start from a known state, so a half-finished GUI run cannot be mistaken for
# a result produced here.
reset_run synth_1

launch_runs synth_1 -jobs 2
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
  error "synthesis failed: [get_property STATUS [get_runs synth_1]]"
}
puts "synthesis complete: [get_property STATUS [get_runs synth_1]]"

launch_runs impl_1 -jobs 2
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
  error "implementation failed: [get_property STATUS [get_runs impl_1]]"
}
puts "implementation complete: [get_property STATUS [get_runs impl_1]]"

# Reports in the same shape run_impl.tcl writes, so scripts/fpga_report.py and
# scripts/table1.py can read this directory too.
open_run impl_1
report_utilization        -file [file join $outdir post_route_util.rpt]
report_utilization -hierarchical -hierarchical_depth 5 -file [file join $outdir post_route_util_hier.rpt]
report_timing_summary  -delay_type min_max -max_paths 10 -report_unconstrained -file [file join $outdir post_route_timing.rpt]
report_timing -sort_by group -max_paths 20 -path_type summary -file [file join $outdir post_route_paths.rpt]
report_clock_utilization  -file [file join $outdir post_route_clock.rpt]
report_power              -file [file join $outdir post_route_power.rpt]
report_drc                -file [file join $outdir post_route_drc.rpt]
report_ram_utilization    -file [file join $outdir post_route_ram.rpt]

set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]

# The clock is the 300 MHz board clock divided by the project's own ClkDiv
# generic, so read it back rather than assuming: a build at another frequency
# would otherwise report an Fmax computed against the wrong period.
set clkdiv 3
foreach g [get_property generic [get_filesets sources_1]] {
  if {[string match "ClkDiv=*" $g]} { set clkdiv [string range $g 7 end] }
}
set period [expr {$clkdiv * 1000.0/300.0}]

set fh [open [file join $outdir summary.txt] w]
puts $fh "variant        $variant (project mode)"
puts $fh "project        $xpr"
puts $fh "synth strategy [get_property strategy [get_runs synth_1]]"
puts $fh "impl strategy  [get_property strategy [get_runs impl_1]]"
puts $fh "clk_period_ns  [format %.3f $period]"
puts $fh "clk_freq_mhz   [format %.2f [expr {1000.0/$period}]]"
puts $fh "wns_ns         [format %.3f $wns]"
puts $fh "whs_ns         [format %.3f $whs]"
puts $fh "fmax_mhz       [format %.2f [expr {1000.0/($period - $wns)}]]"
puts $fh ""
puts $fh "Not comparable with fpga/reports_$variant/: different strategies."
close $fh

puts ""
puts "=============================================================="
puts " project run complete: $variant"
puts " WNS [format %.3f $wns] ns   WHS [format %.3f $whs] ns"
puts " reports: $outdir"
puts "=============================================================="
close_project
