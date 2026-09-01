# =============================================================================
#  write_funcsim.tcl -- export the implemented design as a simulation netlist.
#
#  Usage:  vivado -mode batch -nojournal -source fpga/write_funcsim.tcl \
#                 -tclargs coherent
#
#  funcsim rather than timesim: this asks whether the routed logic computes the
#  right answer and whether the program survived into the block RAM INIT
#  strings, not whether it does so within a clock period. Timing is what the
#  static analysis in reports_prj_*/ is for, and it already says the design
#  meets every constraint.
# =============================================================================

set root [file normalize [file join [file dirname [info script]] ..]]

set variant [lindex $argv 0]
if {$variant eq ""} { set variant "coherent" }

set xpr [file join $root fpga vivado_prj_$variant $variant.xpr]
set out [file join $root fpga netlist_$variant.v]

set_param general.maxThreads 2
open_project $xpr
open_run impl_1

# -force so a re-export overwrites; -mode funcsim leaves out the SDF timing.
write_verilog -force -mode funcsim $out

puts ""
puts "=============================================================="
puts " netlist : $out"
puts " size    : [file size $out] bytes"
puts "=============================================================="
close_project
