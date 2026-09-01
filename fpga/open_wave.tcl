# Open the post-implementation waveform and populate the Wave window.
#
# open_wave_database on its own loads the database but shows nothing: which
# signals appear is normally carried by a .wcfg, and a batch run writes none.
# Adding them here means the window comes up with the run's story already on it.
set wdb C:/work/riscv-cache-extension/sim/out_netlist/tb_fpga_top_snap.wdb
open_wave_database $wdb

# The board pins and the boot sequence, then the probes taken off the routed
# flip-flops. Each is added on its own so one bad name cannot empty the window.
foreach sig {clk_p clk_n cpu_reset dip pb led soc_edges done_bits} {
  if {[catch {add_wave /tb_fpga_top/$sig} msg]} {
    puts "note: could not add $sig -- $msg"
  }
}
for {set p 0} {$p < 4} {incr p} {
  if {[catch {add_wave /tb_fpga_top/exit_lo\[$p\]} msg]} {
    puts "note: could not add exit_lo\[$p\] -- $msg"
  }
}
if {[catch {add_wave /tb_fpga_top/dut/clk} msg]} { puts "note: dut/clk -- $msg" }

puts "WAVE_READY objects=[llength [get_objects /tb_fpga_top/*]]"
