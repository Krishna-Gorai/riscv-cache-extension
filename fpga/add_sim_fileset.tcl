# =============================================================================
#  add_sim_fileset.tcl -- give an EXISTING project its simulation fileset.
#
#  Usage:  vivado -mode batch -nojournal -nolog \
#                 -source fpga/add_sim_fileset.tcl -tclargs filtered
#
#  create_project.tcl now sets this up at creation time. This script exists for
#  projects made before it did, so that they do not have to be recreated:
#  create_project.tcl uses "create_project -force", which deletes the synth_1
#  and impl_1 runs along with the project, and re-running implementation to
#  recover a two-line settings change is not a trade worth making.
#
#  Close the GUI first. A project open in Vivado holds a write lock and this
#  will fail to open it.
# =============================================================================

set root [file normalize [file join [file dirname [info script]] ..]]

set variant [lindex $argv 0]
if {$variant eq ""} { set variant "filtered" }

set xpr [file join $root fpga vivado_prj_$variant $variant.xpr]
if {![file exists $xpr]} { error "no project at $xpr" }

open_project $xpr

set tb [file join $root tb system tb_fpga_top.sv]
if {![file exists $tb]} { error "no testbench at $tb" }

# Idempotent: adding a file already in the fileset is a no-op, but checking
# keeps the log honest about whether anything changed.
set existing [get_files -quiet -of [get_filesets sim_1] *tb_fpga_top.sv]
if {$existing eq ""} {
  add_files -norecurse -fileset sim_1 $tb
  puts "added $tb to sim_1"
} else {
  puts "tb_fpga_top.sv already in sim_1"
}

set_property file_type SystemVerilog [get_files -of [get_filesets sim_1] *.sv]
set_property top tb_fpga_top [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]

# See create_project.tcl for why the NETLIST define belongs on the fileset: this
# sim_1 is configured for post-synthesis and post-implementation runs.
# `ifdef is a preprocessor directive, so the define must reach xvlog; on xelab
# alone the testbench compiles its RTL-path branch and dies at elaboration.
set_property -name {xsim.compile.xvlog.more_options} -value {-d NETLIST} \
             -objects [get_filesets sim_1]
set_property -name {xsim.elaborate.xelab.more_options} -value {-d NETLIST} \
             -objects [get_filesets sim_1]
set_property -name {xsim.elaborate.load_glbl} -value {true} \
             -objects [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {all} \
             -objects [get_filesets sim_1]

update_compile_order -fileset sim_1

puts ""
puts "=============================================================="
puts " project : $xpr"
puts " sim top : [get_property top [get_filesets sim_1]]"
puts " sources : [get_files -of [get_filesets sim_1]]"
puts " xvlog   : [get_property xsim.compile.xvlog.more_options [get_filesets sim_1]]"
puts " xelab   : [get_property xsim.elaborate.xelab.more_options [get_filesets sim_1]]"
puts " glbl    : [get_property xsim.elaborate.load_glbl [get_filesets sim_1]]"
puts " runtime : [get_property xsim.simulate.runtime [get_filesets sim_1]]"
puts ""
puts " In the GUI: Flow Navigator > SIMULATION > Run Simulation"
puts "             > Run Post-Implementation Functional Simulation"
puts "=============================================================="
close_project
