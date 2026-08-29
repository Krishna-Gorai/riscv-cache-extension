// =============================================================================
//  cv32e40p_fpga_clock_gate.sv -- FPGA implementation of the core's clock gate.
//
//  CV32E40P ships a behavioural clock gate built from an always_latch, and its
//  header says in as many words that it must not be used for FPGA synthesis:
//  a latch driving an AND into a clock is not a clock gate on an FPGA, it is a
//  combinational clock path that no static timing analysis can close.
//
//  On UltraScale+ the cell that does this job is BUFGCE, a global buffer with
//  a clock enable. The sleep unit drives en_i from a register, which is exactly
//  the timing BUFGCE's CE input expects.
//
//  With NUM_MHPMCOUNTERS=1 and COREV_CLUSTER=0 there is one of these per core,
//  so a four-PE SoC spends four BUFGCEs on WFI clock gating -- which is what
//  makes the reported power reflect cores that are actually asleep between
//  barriers rather than cores that only pretend to be.
// =============================================================================
module cv32e40p_clock_gate (
    input  logic clk_i,
    input  logic en_i,
    input  logic scan_cg_en_i,
    output logic clk_o
);

  BUFGCE #(
    .CE_TYPE     ("SYNC"),
    .IS_CE_INVERTED (1'b0),
    .IS_I_INVERTED  (1'b0),
    .SIM_DEVICE  ("ULTRASCALE_PLUS")
  ) u_bufgce (
    .I  (clk_i),
    .CE (en_i | scan_cg_en_i),
    .O  (clk_o)
  );

endmodule
