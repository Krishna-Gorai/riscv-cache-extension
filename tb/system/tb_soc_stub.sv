// =============================================================================
//  tb_soc_stub.sv -- core-independent test of the whole SoC (M5).
//
//  Builds the complete soc_top -- bridges, ITCMs, DCUs, snoopy bus, shared
//  memories, control region -- with tb/models/core_stub.sv compiled in place of
//  the CV32E40P submodule. The stub drives the same phase pattern as the
//  compiled kernel, so this exercises the SoC integration and its coherence
//  behaviour without needing a simulator that can elaborate the real core.
//
//    tb_soc_stub      the coherent SoC
//    tb_soc_stub_nc   the non-coherent baseline
//
//  The non-coherent variant is expected to pass too: with no caches anywhere
//  there is only one copy of the data, so it is trivially coherent. What
//  separates the two is how long they take, which is what Figs. 5 and 6
//  measure. Both are checked here so that a bug in the baseline data path
//  cannot masquerade as a coherence result later.
//
//  Run with:  sim/run_iverilog.sh tb_soc_stub
//             sim/run_iverilog.sh tb_soc_stub_nc
// =============================================================================
`timescale 1ns/1ps

// Elements in the shared array. The coherence property under test does not
// depend on the array size, so an interpreting simulator can run a smaller
// problem: override with -DSOC_STUB_N=<n> (n must divide the PE count).
`ifndef SOC_STUB_N
  `define SOC_STUB_N 64
`endif

module soc_stub_harness #(
  parameter bit             Coherent = 1'b1,
  parameter string          Label    = "coherent",
  parameter int unsigned    NumPes   = 4
);

  localparam int unsigned DataW  = 32;

  localparam int unsigned N        = `SOC_STUB_N;
  localparam int unsigned ARR_WORD = 32'h0000 >> 2;
  localparam int unsigned RES_WORD = 32'h1000 >> 2;
  localparam int unsigned EXPECT   = 7*N*(N-1)/2 + N;   // sum_{i<N}(7i+1)

  localparam int unsigned HEARTBEAT = 200;   // cycles between progress lines

  logic clk      = 1'b0;
  logic rst_n    = 1'b0;
  logic fetch_en = 1'b0;
  always #5 clk = ~clk;

  logic [NumPes-1:0]       done;
  logic [NumPes*DataW-1:0] exit_code;
  logic                    pc_valid;
  logic [7:0]              pc_data;
  logic [31:0]             cycle;
  logic [NumPes-1:0]       core_sleep;
  logic [NumPes*32-1:0]    p_rd_hit, p_rd_miss, p_wr_hit, p_wr_miss;

  soc_top #(
    .NumPes     (NumPes),
    .Coherent   (Coherent),
    .NumWays    (2),
    .NumSets    (64),
    .LineBytes  (16),
    .ItcmBytes  (4096),
    .SimemBytes (4096),
    .SdmemBytes (262144),
    .MemLat     (2)
  ) u_soc (
    .clk_i           (clk),
    .rst_ni          (rst_n),
    .fetch_enable_i  (fetch_en),
    .done_o          (done),
    .exit_code_o     (exit_code),
    .putchar_valid_o (pc_valid),
    .putchar_data_o  (pc_data),
    .cycle_o         (cycle),
    .core_sleep_o    (core_sleep),
    .perf_rd_hit_o   (p_rd_hit),
    .perf_rd_miss_o  (p_rd_miss),
    .perf_wr_hit_o   (p_wr_hit),
    .perf_wr_miss_o  (p_wr_miss)
  );

  integer errors = 0;
  integer checks = 0;
  integer i, p;
  integer trh, trm, twh, twm;
  integer rh, rm, wh, wm;

  task chk(input bit cond, input string msg);
    begin
      checks = checks + 1;
      if (!cond) begin
        errors = errors + 1;
        $display("  [%0t] CHECK FAILED: %s", $time, msg);
      end
    end
  endtask

  initial begin
    $display("\n=== %s: %0d PEs, core stub ===", Label, NumPes);
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (3) @(posedge clk);
    fetch_en = 1'b1;

    wait (&done);
    repeat (20) @(posedge clk);

    $display("--- results (%s) ------------------------------------", Label);
    $display(" cycles to all-done = %0d", cycle);

    for (p = 0; p < NumPes; p = p + 1) begin
      chk(exit_code[p*DataW +: DataW] == 32'd1,
          $sformatf("PE%0d finished", p));
    end

    // The coherence result: phase 2 re-reads lines cached in phase 0 that
    // another PE has written since. EXPECT is only reachable if every stale
    // copy was invalidated.
    for (p = 0; p < NumPes; p = p + 1) begin
      chk(u_soc.u_sdmem.peek(RES_WORD + p) == EXPECT,
          $sformatf("PE%0d saw every other PE's writes: got %0d expected %0d",
                    p, u_soc.u_sdmem.peek(RES_WORD + p), EXPECT));
      chk(u_soc.u_sdmem.peek(RES_WORD + 8 + p) == 0,
          $sformatf("PE%0d started from zeros: got %0d",
                    p, u_soc.u_sdmem.peek(RES_WORD + 8 + p)));
      chk(u_soc.u_sdmem.peek(RES_WORD + 16 + p) == EXPECT,
          $sformatf("PE%0d re-read is stable: got %0d expected %0d",
                    p, u_soc.u_sdmem.peek(RES_WORD + 16 + p), EXPECT));
    end

    for (i = 0; i < N; i = i + 1) begin
      chk(u_soc.u_sdmem.peek(ARR_WORD + i) == (7*i + 1),
          $sformatf("arr[%0d] = %0d expected %0d",
                    i, u_soc.u_sdmem.peek(ARR_WORD + i), 7*i + 1));
    end

    // ---- Fig. 7 style reporting --------------------------------------------
    trh = 0; trm = 0; twh = 0; twm = 0;
    $display("\n per-PE cache statistics:");
    for (p = 0; p < NumPes; p = p + 1) begin
      rh = p_rd_hit [p*32 +: 32];
      rm = p_rd_miss[p*32 +: 32];
      wh = p_wr_hit [p*32 +: 32];
      wm = p_wr_miss[p*32 +: 32];
      trh = trh + rh; trm = trm + rm; twh = twh + wh; twm = twm + wm;
      $display("  PE%0d  rd %0d/%0d hit   wr %0d/%0d hit", p, rh, rh+rm, wh, wh+wm);
    end
    $display("\n aggregate over %0d PEs:", NumPes);
    if (trh + trm > 0)
      $display("  read  hit rate = %0.2f %%  (%0d of %0d)",
               100.0*trh/(trh+trm), trh, trh+trm);
    if (twh + twm > 0)
      $display("  write hit rate = %0.2f %%  (%0d of %0d)",
               100.0*twh/(twh+twm), twh, twh+twm);
    if (trh + trm + twh + twm > 0)
      $display("  average        = %0.2f %%  (%0d of %0d)",
               100.0*(trh+twh)/(trh+trm+twh+twm), trh+twh, trh+trm+twh+twm);

    $display("------------------------------------------------------------------");
    if (errors == 0) $display(" %s PASSED  (%0d checks)\n", Label, checks);
    else             $display(" %s FAILED  (%0d errors / %0d checks)\n",
                              Label, errors, checks);
    $finish;
  end

  // Progress heartbeat. The coherent build is heavy for an interpreting
  // simulator, so a long run needs to be distinguishable from a deadlock.
  always @(posedge clk) begin
    if (rst_n && cycle != 0 && (cycle % HEARTBEAT == 0)) begin
      $display("   [heartbeat] cycle %0d  done=%b", cycle, done);
      $fflush;          // stdout is block-buffered when redirected to a file
    end
  end


  initial begin
    #50ms;
    $display("*** %s TIMEOUT: done = %b ***", Label, done);
    $finish;
  end

endmodule


module tb_soc_stub;
  soc_stub_harness #(.Coherent(1'b1), .Label("tb_soc_stub [coherent]")) h ();
endmodule

module tb_soc_stub_nc;
  soc_stub_harness #(.Coherent(1'b0), .Label("tb_soc_stub_nc [non-coherent]")) h ();
endmodule

// A single-PE coherent build, used to tell an arbitration problem apart from
// one in the cache itself.
module tb_soc_stub_1pe;
  soc_stub_harness #(.Coherent(1'b1), .Label("tb_soc_stub_1pe [coherent, 1 PE]"),
                     .NumPes(1)) h ();
endmodule
