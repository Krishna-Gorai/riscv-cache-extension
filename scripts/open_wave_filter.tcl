# =============================================================================
#  open_wave_filter.tcl -- open the coherence waveform with the MECHANISM on it.
#
#  Usage:  vivado -mode gui -source scripts/open_wave_filter.tcl \
#                 -tclargs <path-to.wdb>
#
#  The netlist waveform shows the outcome: done goes high, exit codes read 1.
#  This one is for the question behind it -- how the snoop filter decides, and
#  what the bus does with the answer. tb_coherent_subsystem is the right run to
#  look at because it deliberately shares: roughly a third of its invalidations
#  are useful, so the filter is seen both suppressing and broadcasting. On the
#  four benchmark kernels it only ever suppresses, which shows half the story.
#
#  Signals are added in the order the decision is actually made, so the window
#  reads top to bottom as one invalidation's journey:
#
#     1. a core asks           req / is_inv / addr
#     2. the arbiter picks     inv_arb_valid / inv_arb_idx / win_addr
#     3. the mirror answers    qry_addr -> held_o / any_other_o
#     4. fills in flight       filling_line        (the correctness term)
#     5. the union decides     sharers / bcast_needed
#     6. the bus acts          bcast_tgt / others_ready / inv_gnt_valid
#     7. the DCUs hear it      inv_valid_o / inv_ready_i
#
#  What to look for, and why it is the point of the paper:
#
#    * bcast_needed LOW while inv_arb_valid is HIGH -- a write was granted and
#      no broadcast was sent, because no other cache held the line and none was
#      fetching it. inv_gnt_valid rises in the same cycle: no barrier, no wait.
#      That is the 1.122x.
#
#    * bcast_needed HIGH -- inv_gnt_valid now waits for others_ready, and the
#      grant is held until every DCU in bcast_tgt can accept. That is the
#      serialisation the filter removes when it can, and honours when it must.
#
#    * filling_line HIGH while held_o is zero -- the case that makes the filter
#      correct rather than merely fast. A cache with a refill in flight holds
#      nothing yet and must still be told; on committed tags alone this
#      invalidation would have been suppressed and a stale line installed.
#      Rare, so search rather than scroll: 20 of 2241 over ten seeds.
# =============================================================================

set wdb [lindex $argv 0]
if {$wdb eq ""} {
  set wdb C:/work/riscv-cache-extension/sim/out_mech/tb_coherent_subsystem_snap.wdb
}
if {![file exists $wdb]} { error "no waveform database at $wdb" }
puts "opening   : $wdb"
puts "written   : [clock format [file mtime $wdb] -format {%Y-%m-%d %H:%M:%S}]"
open_wave_database $wdb

set bus /tb_coherent_subsystem/dut/u_snoopy_bus
set flt $bus/g_filter.u_filter

# Each signal is added on its own and failures are reported rather than fatal:
# a name that optimisation or a rename has moved must not empty the window.
proc wsig {path {label ""}} {
  if {[catch {add_wave $path} msg]} {
    puts "note: could not add $path -- $msg"
  } elseif {$label ne ""} {
    catch {add_wave_group_marker $label}
  }
}

puts "--- 1. the request ---"
foreach s {clk rst_n} { wsig /tb_coherent_subsystem/$s }
foreach s {req_i is_inv_i addr_i} { wsig $bus/$s }

puts "--- 2. arbitration ---"
foreach s {inv_arb_valid inv_arb_idx win_addr} { wsig $bus/$s }

puts "--- 3. the mirror's answer ---"
foreach s {qry_addr_i qry_core_i held_o any_other_o} { wsig $flt/$s }

puts "--- 4. fills in flight, and the union ---"
foreach s {fill_busy_i filling_line sharers any_sharer} { wsig $bus/$s }

puts "--- 5. the decision and the handshake ---"
foreach s {bcast_needed bcast_tgt others_ready inv_gnt_valid} { wsig $bus/$s }

puts "--- 6. what the DCUs see ---"
foreach s {inv_valid_o inv_addr_o inv_ready_i} { wsig $bus/$s }

puts "--- 7. mirror updates ---"
foreach s {dir_upd_i dir_inst_i dir_set_i} { wsig $bus/$s }

catch {wave_zoom_fit}
puts "WAVE_READY"
