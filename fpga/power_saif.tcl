# =============================================================================
#  power_saif.tcl -- re-estimate power from measured switching activity.
#
#  Usage:  vivado -mode batch -source fpga/power_saif.tcl -tclargs coherent
#
#  report_power's vectorless mode has to guess how often every net toggles. On
#  this design it guesses badly: each core's clock passes through a BUFGCE
#  whose enable the estimator cannot evaluate, so it assumes the gated clocks
#  are mostly off and reports under a milliwatt of register power for fifteen
#  thousand flip-flops. The result is a number that describes an idle chip.
#
#  A SAIF captured while the SoC actually runs a benchmark replaces the guess
#  with measurement. The paths in it are stripped to start at u_soc, which is
#  where soc_top sits inside fpga_top, so they land on the implemented cells.
#
#  Both the vectorless and the SAIF-based reports are kept, because the gap
#  between them is worth seeing rather than hiding.
# =============================================================================

set root [file normalize [file join [file dirname [info script]] ..]]

set variant [lindex $argv 0]
if {$variant eq ""} { set variant "coherent" }

set outdir [file join $root fpga reports_$variant]
set dcp    [file join $outdir post_route.dcp]
set saif   [file join $outdir bench.saif]

foreach f [list $dcp $saif] {
  if {![file exists $f]} { error "missing $f" }
}

set_param general.maxThreads 2
open_checkpoint $dcp

# The SAIF was logged at /tb_bench/h/u_soc (or /tb_bench_nc/h/u_soc), so the
# prefix up to and including the harness instance comes off, leaving u_soc/...
set tb [expr {$variant eq "baseline" ? "tb_bench_nc" : "tb_bench"}]
read_saif -strip_path "/$tb/h" -out_file [file join $outdir saif_match.rpt] $saif

report_power -file [file join $outdir post_route_power_saif.rpt]

set fh [open [file join $outdir power_saif_summary.txt] w]
puts $fh "variant   $variant"
puts $fh "saif      $saif"
puts $fh "tb_scope  /$tb/h/u_soc"
puts $fh "match     see saif_match.rpt"
puts $fh "report    post_route_power_saif.rpt"
close $fh

puts "SAIF power report written for $variant"
