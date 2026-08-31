# =============================================================================
#  create_project.tcl -- build a managed Vivado project for the GUI.
#
#  Usage:  vivado -mode batch -source fpga/create_project.tcl -tclargs coherent
#          vivado -mode batch -source fpga/create_project.tcl -tclargs baseline
#
#  then open fpga/vivado_prj_<variant>/<variant>.xpr
#
#  run_impl.tcl is the flow of record: non-project mode, no .xpr, nothing to
#  regenerate, and every number in fpga/reports_* came out of it. This script
#  exists for the other job -- editing RTL and re-running from the GUI, or
#  poking at a design interactively. The two read the same source list, so a
#  file added here must be added there as well.
#
#  To look at results rather than build them, do not use this: open the routed
#  checkpoint instead, which is the actual implemented design.
#      vivado fpga/reports_<variant>/post_route.dcp
# =============================================================================

set root [file normalize [file join [file dirname [info script]] ..]]

set variant [lindex $argv 0]
if {$variant eq ""} { set variant "coherent" }

switch -- $variant {
  coherent { set coh 1 }
  baseline { set coh 0 }
  default  { error "variant must be 'coherent' or 'baseline', got '$variant'" }
}

# 300 MHz board clock / 3 = 100 MHz, the same divide run_impl.tcl uses.
set clkdiv 3
set part   xczu7ev-ffvc1156-2-e
set prjdir [file join $root fpga vivado_prj_$variant]

create_project -force $variant $prjdir -part $part

# The board file adds the ZCU104 pin/preset definitions. It is only present if
# the board files are installed, so a missing one is not fatal.
if {[catch {set_property board_part xilinx.com:zcu104:part0:1.1 [current_project]} msg]} {
  puts "note: ZCU104 board part not set ($msg); the part alone is enough here"
}

# -----------------------------------------------------------------------------
#  Sources, in the order run_impl.tcl reads them.
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

# Referenced in place rather than copied, so the project and the batch flow
# always build the same text and an edit in the GUI is an edit to the repo.
add_files -norecurse -fileset sources_1 [concat $cv_srcs $prj_srcs]
set_property file_type SystemVerilog [get_files -of [get_filesets sources_1] *.sv]

add_files -norecurse -fileset constrs_1 [file join $root fpga zcu104.xdc]

set_property top fpga_top [get_filesets sources_1]
set_property include_dirs [list [file join $cv_rtl include]] [get_filesets sources_1]

# The cache extension is one parameter, and SYNTHESIS swaps the behavioural
# clock gate for the BUFGCE cell.
set_property generic [list Coherent=$coh ClkDiv=$clkdiv] [get_filesets sources_1]
set_property verilog_define {SYNTHESIS} [get_filesets sources_1]

# The batch flow is single-run and keeps the tool inside this host's memory;
# match it so a GUI run does not thrash an 8 GB machine.
set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value {-verilog_define SYNTHESIS} -objects [get_runs synth_1]

update_compile_order -fileset sources_1

puts ""
puts "=============================================================="
puts " project  : [file join $prjdir $variant.xpr]"
puts " variant  : $variant  (Coherent=$coh)"
puts " part     : $part"
puts " top      : fpga_top   ClkDiv=$clkdiv -> 100 MHz"
puts ""
puts " open with:  vivado [file join $prjdir $variant.xpr]"
puts ""
puts " Numbers of record come from run_impl.tcl, not from this project."
puts " To inspect the implemented design instead of rebuilding it:"
puts "   vivado [file join $root fpga reports_$variant post_route.dcp]"
puts "=============================================================="
