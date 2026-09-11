# Open the post-implementation waveform and populate the Wave window.
#
# open_wave_database on its own loads the database but shows nothing: which
# signals appear is normally carried by a .wcfg, and a batch run writes none.
# Adding them here means the window comes up with the run's story already on it.
#
# Usage:  vivado -mode gui -source fpga/open_wave.tcl -tclargs <path-to.wdb>
#
# The path is an argument rather than a constant. It used to be hard-coded to
# sim/out_netlist/, which is where an older run happened to write; a later run
# defaulting to sim/out_fpga/ would then have opened the earlier design's
# waveform without saying so. A stale waveform looks exactly like a fresh one,
# so this refuses to guess and prints what it opened.
set wdb [lindex $argv 0]
if {$wdb eq ""} {
  set wdb C:/work/riscv-cache-extension/sim/out_fpga/tb_fpga_top_snap.wdb
}
if {![file exists $wdb]} { error "no waveform database at $wdb" }
puts "opening   : $wdb"
puts "written   : [clock format [file mtime $wdb] -format {%Y-%m-%d %H:%M:%S}]"
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
