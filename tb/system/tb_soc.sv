// =============================================================================
//  tb_soc.sv -- the 4-PE SoC of Fig. 1, coherent and non-coherent (M5)
//
//  Boots four unmodified CV32E40P cores out of the shared instruction memory,
//  lets each transfer its code into its private ITCM, and runs a parallel
//  kernel across all of them.
//
//  Two top modules are defined here so that selecting an architecture needs no
//  elaboration-time parameter overrides:
//
//    tb_soc      the coherent SoC   -- private DCUs and the snoopy bus
//    tb_soc_nc   the non-coherent baseline -- no data cache at all
//
//  Both instantiate the same harness and run the same program image. That is
//  the point: the software cannot tell which one it is running on, except by
//  how long it takes.
//
//  Run with:  sim/run_xsim.ps1 -Tb tb_soc    -Hex sw/build/soc_par_smoke.hex
//             sim/run_xsim.ps1 -Tb tb_soc_nc -Hex sw/build/soc_par_smoke.hex
// =============================================================================
`timescale 1ns/1ps

module soc_harness #(
  parameter bit    Coherent = 1'b1,
  parameter string Label    = "coherent"
);

  import cache_pkg::*;

  localparam int unsigned NumPes    = 4;
  localparam int unsigned AddrW     = 32;
  localparam int unsigned DataW     = 32;
  localparam int unsigned LineBytes = 16;
  localparam int unsigned SdmemSize = 262144;

  localparam time CLK_P = 10ns;

  // The kernel's expectations, mirrored from sw/soc_kernels/par_smoke.c
  localparam int unsigned N        = 256;
  localparam int unsigned ARR_WORD = 32'h0000 >> 2;
  localparam int unsigned RES_WORD = 32'h1000 >> 2;
  localparam int unsigned EXPECT   = 228736;

  logic clk      = 1'b0;
  logic rst_n    = 1'b0;
  logic fetch_en = 1'b0;
  always #(CLK_P/2) clk = ~clk;

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
    .LineBytes  (LineBytes),
    .AddrW      (AddrW),
    .DataW      (DataW),
    .ItcmBytes  (32768),
    .SimemBytes (32768),
    .SdmemBytes (SdmemSize),
    .BootAddr   (32'h2000_0000),
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

  // --- console ---------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst_n && pc_valid) $write("%c", pc_data);
  end

  // ---------------------------------------------------------------------------
  //  Scoreboard
  // ---------------------------------------------------------------------------
  int unsigned errors = 0;
  int unsigned checks = 0;

  function automatic void chk(input bit cond, input string msg);
    checks++;
    if (!cond) begin
      errors++;
      $error("[%0t] CHECK FAILED: %s", $time, msg);
    end
  endfunction

  string hexfile;

  initial begin
    if (!$value$plusargs("HEX=%s", hexfile)) hexfile = "program.hex";
    $display("\n=== %s SoC: %0d PEs ===", Label, NumPes);
    $display("--- loading shared instruction memory from %s ---", hexfile);
    $readmemh(hexfile, u_soc.u_simem.mem);

    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);
    fetch_en = 1'b1;

    $display("--- running ------------------------------------------------------");
    wait (&done);
    repeat (20) @(posedge clk);

    // ---- results ------------------------------------------------------------
    $display("\n--- results (%s) --------------------------------------------", Label);
    $display(" cycles to all-done = %0d", cycle);
    for (int unsigned p = 0; p < NumPes; p++) begin
      $display("  PE%0d exit=%0d  kernel cycles=%0d",
               p, exit_code[p*DataW +: DataW], u_soc.u_sdmem.peek(RES_WORD + 24 + p));
    end

    for (int unsigned p = 0; p < NumPes; p++) begin
      chk(exit_code[p*DataW +: DataW] == 32'd1,
          $sformatf("PE%0d reported success, got %0d", p, exit_code[p*DataW +: DataW]));
    end

    // ---- the coherence result ----------------------------------------------
    //  Phase 2 of the kernel re-reads lines that were cached in phase 0 and
    //  written by another PE in phase 1. Getting EXPECT back is only possible
    //  if every one of those stale copies was invalidated.
    for (int unsigned p = 0; p < NumPes; p++) begin
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

    chk(u_soc.u_sdmem.peek(RES_WORD + 32) == 32'hC0FFEE,
        $sformatf("PE0 cross-checked everyone, got %08x",
                  u_soc.u_sdmem.peek(RES_WORD + 32)));

    // Every element must be in the shared memory, whoever wrote it.
    for (int unsigned i = 0; i < N; i++) begin
      chk(u_soc.u_sdmem.peek(ARR_WORD + i) == 32'(7*i + 1),
          $sformatf("arr[%0d] = %0d, expected %0d",
                    i, u_soc.u_sdmem.peek(ARR_WORD + i), 7*i + 1));
    end

    report_hit_rates();

    $display("------------------------------------------------------------------");
    if (errors == 0) $display(" %s PASSED  (%0d checks)\n", Label, checks);
    else             $display(" %s FAILED  (%0d errors / %0d checks)\n",
                              Label, errors, checks);
    if (errors != 0) $fatal(1);
    $finish;
  end

  // ---------------------------------------------------------------------------
  //  Fig. 7 style reporting: read, write and average hit rate.
  //
  //  Under write-through / no-allocate a store to a line that is not resident
  //  never installs it, so a kernel that writes before it reads shows a low
  //  write hit rate while its reads still hit on every reuse. That is why the
  //  paper plots the three series separately rather than one number.
  // ---------------------------------------------------------------------------
  function automatic void report_hit_rates();
    int unsigned rh, rm, wh, wm;
    int unsigned trh = 0, trm = 0, twh = 0, twm = 0;

    $display("\n per-PE cache statistics:");
    for (int unsigned p = 0; p < NumPes; p++) begin
      rh = p_rd_hit [p*32 +: 32];
      rm = p_rd_miss[p*32 +: 32];
      wh = p_wr_hit [p*32 +: 32];
      wm = p_wr_miss[p*32 +: 32];
      trh += rh; trm += rm; twh += wh; twm += wm;
      $display("  PE%0d  rd %0d/%0d hit  wr %0d/%0d hit", p, rh, rh+rm, wh, wh+wm);
    end

    $display("\n aggregate over %0d PEs:", NumPes);
    $display("  read  hit rate = %0.2f %%  (%0d of %0d)",
             (trh+trm) ? 100.0*real'(trh)/real'(trh+trm) : 0.0, trh, trh+trm);
    $display("  write hit rate = %0.2f %%  (%0d of %0d)",
             (twh+twm) ? 100.0*real'(twh)/real'(twh+twm) : 0.0, twh, twh+twm);
    $display("  average        = %0.2f %%  (%0d of %0d)",
             (trh+trm+twh+twm) ? 100.0*real'(trh+twh)/real'(trh+trm+twh+twm) : 0.0,
             trh+twh, trh+trm+twh+twm);
  endfunction

  initial begin
    #20ms;
    $display("*** %s TIMEOUT: done = %b ***", Label, done);
    $fatal(1);
  end

endmodule


// =============================================================================
//  The two architectures Section IV-A compares.
// =============================================================================
module tb_soc;
  soc_harness #(.Coherent(1'b1), .Label("tb_soc [coherent]")) h ();
endmodule

module tb_soc_nc;
  soc_harness #(.Coherent(1'b0), .Label("tb_soc_nc [non-coherent]")) h ();
endmodule
