// =============================================================================
//  tb_fpga_top.sv -- drive the board's pins and let the design boot itself.
//
//  Every other testbench here loads a program by reaching into the hierarchy
//  and writing the memory array directly. A netlist has no hierarchy to reach
//  into, so that trick cannot verify an implemented design; it also hides the
//  question of whether the design can obtain a program at all, which until the
//  ProgramHex parameter existed it could not.
//
//  This one loads nothing. It drives the 300 MHz differential board clock,
//  releases CPU_RESET, raises the run switch, and waits -- exactly what the
//  ZCU104 does. Anything the cores execute came out of the block RAM's
//  initial contents.
//
//  Run it two ways. Against RTL with SYNTHESIS defined it proves the parameter
//  reaches the memory and the SoC self-boots. Against the post-implementation
//  netlist it proves the program survived synthesis, placement and routing into
//  the RAMB36 INIT strings, and that the routed logic still computes the right
//  answer.
// =============================================================================
`timescale 1ns/1ps

module tb_fpga_top;

  localparam int unsigned NumPes = 4;

  // 300 MHz board clock. ClkDiv of 4 makes the SoC clock 75 MHz.
  // realtime, not time: `time` is integral, so 3.333ns became 3ns and the half
  // period 1ns, clocking the board at 500 MHz. Harmless in a zero-delay
  // functional run, wrong everywhere else, and exactly the sort of harness bug
  // that gets mistaken for a design bug.
  localparam realtime CLK300_P = 3.3333ns;

  // Mirrored from sw/soc_kernels/par_smoke.c, the same values tb_soc checks.
  localparam int unsigned RES_WORD = 32'h1000 >> 2;
  localparam int unsigned EXPECT   = 228736;

  logic clk_p = 1'b0;
  logic clk_n = 1'b1;
  always #(CLK300_P/2) begin
    clk_p = ~clk_p;
    clk_n = ~clk_n;
  end

  logic       cpu_reset = 1'b1;
  logic [3:0] dip       = 4'b0000;
  logic [3:0] pb        = 4'b0000;
  wire  [3:0] led;

`ifdef NETLIST
  // The routed netlist carries its parameters baked in and takes glbl's global
  // reset, so it is instantiated bare.
  fpga_top dut (
`else
  fpga_top #(
    .Coherent   (1'b1),
    .NumPes     (NumPes),
    .ClkDiv     (4),
    .ProgramHex ("C:/work/riscv-cache-extension/sw/build/soc_par_smoke.hex")
  ) dut (
`endif
    .clk300_p_i  (clk_p),
    .clk300_n_i  (clk_n),
    .cpu_reset_i (cpu_reset),
    .dip_i       (dip),
    .pb_i        (pb),
    .led_o       (led)
  );

  int unsigned errors = 0;
  int unsigned checks = 0;

  function automatic void chk(input bit cond, input string msg);
    checks++;
    if (!cond) begin
      errors++;
      $display("  [FAIL] %s", msg);
    end else begin
      $display("  [ ok ] %s", msg);
    end
  endfunction

  // Count SoC clock edges independently, so a design that never gets a clock
  // is distinguishable from one that gets a clock and does nothing with it.
  int unsigned soc_edges = 0;
  always @(posedge dut.clk) soc_edges++;

  // The design's only outputs are four LEDs carrying one nibble at a time,
  // advanced by a counter that takes about a third of a second per nibble.
  // Reading a 32-bit word through them costs seconds of simulated time, which
  // is fine at a board and hopeless in a gate-level run, so the checks look
  // inside instead.
`ifdef NETLIST
  // Synthesis renamed every vector port of soc_top and axi_ctrl -- they come
  // out as DOUTADOUT, SR, D and the like -- but the flip-flops kept the names
  // they had in the source, so the registers are the reliable handle. Each
  // reference is one FDRE's Q output.
  wire [NumPes-1:0] done_bits = {
    dut.u_soc.u_ctrl.\done_o_reg[3] .Q,
    dut.u_soc.u_ctrl.\done_o_reg[2] .Q,
    dut.u_soc.u_ctrl.\done_o_reg[1] .Q,
    dut.u_soc.u_ctrl.\done_o_reg[0] .Q
  };

  // The low byte of each PE's exit code. exit_code_o_reg[p*32 + b] is bit b of
  // PE p, and eight bits is enough to tell success from any other small code.
  wire [7:0] exit_lo [NumPes];
  assign exit_lo[0] = {
    dut.u_soc.u_ctrl.\exit_code_o_reg[7] .Q, dut.u_soc.u_ctrl.\exit_code_o_reg[6] .Q,
    dut.u_soc.u_ctrl.\exit_code_o_reg[5] .Q, dut.u_soc.u_ctrl.\exit_code_o_reg[4] .Q,
    dut.u_soc.u_ctrl.\exit_code_o_reg[3] .Q, dut.u_soc.u_ctrl.\exit_code_o_reg[2] .Q,
    dut.u_soc.u_ctrl.\exit_code_o_reg[1] .Q, dut.u_soc.u_ctrl.\exit_code_o_reg[0] .Q };
  assign exit_lo[1] = {
    dut.u_soc.u_ctrl.\exit_code_o_reg[39] .Q, dut.u_soc.u_ctrl.\exit_code_o_reg[38] .Q,
    dut.u_soc.u_ctrl.\exit_code_o_reg[37] .Q, dut.u_soc.u_ctrl.\exit_code_o_reg[36] .Q,
    dut.u_soc.u_ctrl.\exit_code_o_reg[35] .Q, dut.u_soc.u_ctrl.\exit_code_o_reg[34] .Q,
    dut.u_soc.u_ctrl.\exit_code_o_reg[33] .Q, dut.u_soc.u_ctrl.\exit_code_o_reg[32] .Q };
  assign exit_lo[2] = {
    dut.u_soc.u_ctrl.\exit_code_o_reg[71] .Q, dut.u_soc.u_ctrl.\exit_code_o_reg[70] .Q,
    dut.u_soc.u_ctrl.\exit_code_o_reg[69] .Q, dut.u_soc.u_ctrl.\exit_code_o_reg[68] .Q,
    dut.u_soc.u_ctrl.\exit_code_o_reg[67] .Q, dut.u_soc.u_ctrl.\exit_code_o_reg[66] .Q,
    dut.u_soc.u_ctrl.\exit_code_o_reg[65] .Q, dut.u_soc.u_ctrl.\exit_code_o_reg[64] .Q };
  assign exit_lo[3] = {
    dut.u_soc.u_ctrl.\exit_code_o_reg[103] .Q, dut.u_soc.u_ctrl.\exit_code_o_reg[102] .Q,
    dut.u_soc.u_ctrl.\exit_code_o_reg[101] .Q, dut.u_soc.u_ctrl.\exit_code_o_reg[100] .Q,
    dut.u_soc.u_ctrl.\exit_code_o_reg[99] .Q,  dut.u_soc.u_ctrl.\exit_code_o_reg[98] .Q,
    dut.u_soc.u_ctrl.\exit_code_o_reg[97] .Q,  dut.u_soc.u_ctrl.\exit_code_o_reg[96] .Q };
`else
  wire [NumPes-1:0] done_bits = dut.done;
  wire [7:0] exit_lo [NumPes];
  for (genvar p = 0; p < NumPes; p++) begin : g_exit
    assign exit_lo[p] = dut.exit_code[p*32 +: 8];
  end
`endif

  initial begin
    automatic int unsigned cyc = 0;
    automatic bit timed_out = 1'b0;

    $display("\n=== tb_fpga_top: booting from the design's own memory ===");
    $display("--- no backdoor load; the program is whatever is in the RAM ---");

    // Hold CPU_RESET well past glbl's global set/reset, which parks the Xilinx
    // primitives for the first 100 ns. BUFGCE_DIV produces no clock during that
    // window, so a button released inside it is a button the design never sees:
    // the synchroniser only ever samples the released value, rst_cnt_q is never
    // assigned, and rst_n_q falls through to 1 with the SoC still full of X.
    // Holding it for 400 board clocks models a real press and clears the window.
    repeat (400) @(posedge clk_p);
    cpu_reset = 1'b0;

    // Let the stretch expire before raising the run switch.
    repeat (600) @(posedge clk_p);
    $display("--- reset released, raising the run switch ---");
    dip[0] = 1'b1;

`ifndef NETLIST
    $display("  simem[0..3] = %08x %08x %08x %08x",
             dut.u_soc.u_simem.mem[0], dut.u_soc.u_simem.mem[1],
             dut.u_soc.u_simem.mem[2], dut.u_soc.u_simem.mem[3]);
`endif
`ifndef NETLIST
    $display("  rst_n=%b fetch_en=%b soc_clk_edges=%0d",
             dut.rst_n_q, dut.fetch_enable, soc_edges);
`else
    $display("  soc_clk_edges=%0d", soc_edges);
`endif

    fork begin
      repeat (8) begin
        repeat (100_000) @(posedge clk_p);
        $display("  t=%0t soc_edges=%0d done=%b exit0=%02x",
                 $time, soc_edges, done_bits, exit_lo[0]);
      end
    end join_none

    // Wait for all four PEs, with a ceiling so a dead design fails rather than
    // hangs. The smoke kernel finishes in a few thousand SoC clocks.
    fork
      begin
        wait (&done_bits);
      end
      begin
        repeat (4_000_000) @(posedge clk_p);
        timed_out = 1'b1;
      end
    join_any
    disable fork;

    repeat (100) @(posedge clk_p);

    $display("\n--- results ---------------------------------------------------");
    chk(!timed_out, "all four PEs finished before the timeout");

    if (!timed_out) begin
      for (int unsigned p = 0; p < NumPes; p++) begin
        chk(exit_lo[p] == 8'd1,
            $sformatf("PE%0d reported success, got %0d", p, exit_lo[p]));
      end
    end

    $display("---------------------------------------------------------------");
    if (errors == 0) $display(" tb_fpga_top PASSED  (%0d checks)", checks);
    else             $display(" tb_fpga_top FAILED  (%0d errors / %0d checks)",
                              errors, checks);
    $display("");
    $finish;
  end

endmodule
