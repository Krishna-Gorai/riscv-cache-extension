# Out-of-context synthesis of the snoop filter alone, to confirm that giving
# each (core, way) its own valid array -- done so the design can be analysed
# formally -- did not change what it costs. The paper quotes 408 LUTs and 512
# flip-flops for this module.
read_verilog -sv rtl/snoop/snoop_filter.sv
synth_design -top snoop_filter -part xczu7ev-ffvc1156-2-e -mode out_of_context \
             -generic NumCores=4 -generic NumWays=2 -generic NumSets=64 \
             -generic AddrW=32 -generic OffsW=4
report_utilization -file fpga/filter_ooc_util.txt
puts "OOC DONE"
