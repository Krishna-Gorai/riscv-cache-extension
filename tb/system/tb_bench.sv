// =============================================================================
//  tb_bench.sv -- the M6 benchmark harness (Figs. 5, 6 and 7)
//
//  One harness for every benchmark kernel, coherent and non-coherent. It does
//  not know which kernel it is running: the kernel publishes a results block
//  (sw/lib/bench.h) naming the region it computed into and the golden checksum
//  that region must hash to, and the harness scores the run from that.
//
//  The checking lives HERE rather than in the kernel on purpose. A kernel that
//  verified itself would only be confirming that it agrees with itself; the
//  golden constants come from scripts/bench_golden.py, an independent Python
//  model. Keeping the check out of the kernel also keeps the DCU hit-rate
//  counters clean -- no verification traffic is folded into the Fig. 7 numbers.
//
//    tb_bench     the coherent SoC  -- private DCUs and the snoopy bus
//    tb_bench_nc  the non-coherent baseline -- no data cache at all
//
//  Run with:  sim/run_xsim.ps1 -Tb tb_bench    -Hex <abs>/sw/build/soc_bench_fft.hex
//             sim/run_xsim.ps1 -Tb tb_bench_nc -Hex <abs>/sw/build/soc_bench_fft.hex
// =============================================================================
`timescale 1ns/1ps

module bench_harness #(
  parameter bit          Coherent = 1'b1,
  parameter string       Label    = "coherent",
  parameter int unsigned MemLat   = 2
);

  import cache_pkg::*;

  localparam int unsigned NumPes    = 4;
  localparam int unsigned AddrW     = 32;
  localparam int unsigned DataW     = 32;
  localparam int unsigned LineBytes = 16;
  localparam int unsigned SdmemSize = 262144;

  localparam time CLK_P = 10ns;

  // The results block, mirrored from sw/lib/bench.h. Byte 0xF000 of the shared
  // data memory; the indices below are words inside it.
  localparam int unsigned RES_WORD    = 32'hF000 >> 2;
  localparam int unsigned BR_CYCLES   = 0;
  localparam int unsigned BR_STATUS   = 8;
  localparam int unsigned BR_RES_OFF  = 16;
  localparam int unsigned BR_RES_WRDS = 17;
  localparam int unsigned BR_GOLDEN   = 18;
  localparam int unsigned BR_SENTINEL = 19;
  localparam int unsigned BR_TOTCYC   = 20;
  localparam int unsigned BR_NPE      = 21;

  localparam logic [31:0] SENTINEL = 32'h00C0FFEE;

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
    .MemLat     (MemLat)
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

  function automatic logic [31:0] res(input int unsigned idx);
    return u_soc.u_sdmem.peek(RES_WORD + idx);
  endfunction

  // The checksum of sw/lib/bench.h and scripts/bench_golden.py. Change all
  // three together or none of them.
  function automatic logic [31:0] csum(input int unsigned word0,
                                       input int unsigned n);
    logic [31:0] h;
    h = 32'd0;
    for (int unsigned i = 0; i < n; i++)
      h = h * 32'd31 + u_soc.u_sdmem.peek(word0 + i);
    return h;
  endfunction

  string hexfile;

  initial begin
    logic [31:0] sentinel, golden, got, res_off, res_words, npe, totcyc;
    int unsigned kcyc_max;

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

    // ---- what the kernel published -----------------------------------------
    sentinel  = res(BR_SENTINEL);
    res_off   = res(BR_RES_OFF);
    res_words = res(BR_RES_WRDS);
    golden    = res(BR_GOLDEN);
    npe       = res(BR_NPE);
    totcyc    = res(BR_TOTCYC);

    $display("\n--- results (%s) --------------------------------------------", Label);

    chk(sentinel == SENTINEL,
        $sformatf("PE0 published its results block, got %08x expected %08x",
                  sentinel, SENTINEL));

    // Everything below reads the published block, so stop if it is not there:
    // a checksum over a region named by a garbage offset says nothing.
    if (sentinel !== SENTINEL) begin
      $display(" %s FAILED  (%0d errors / %0d checks) -- no results block\n",
               Label, errors, checks);
      $fatal(1);
    end

    chk(npe == NumPes,
        $sformatf("all %0d PEs took part, kernel saw %0d", NumPes, npe));

    for (int unsigned p = 0; p < NumPes; p++) begin
      chk(exit_code[p*DataW +: DataW] == 32'd1,
          $sformatf("PE%0d reported success, got %0d",
                    p, exit_code[p*DataW +: DataW]));
      chk(res(BR_STATUS + p) == 32'd1,
          $sformatf("PE%0d reached the end of its slice, status %0d",
                    p, res(BR_STATUS + p)));
    end

    // ---- the result itself --------------------------------------------------
    got = csum(res_off >> 2, res_words);
    chk(got == golden,
        $sformatf("checksum over %0d words at 0x%05x = %08x, expected %08x",
                  res_words, res_off, got, golden));

    // ---- Fig. 5 / 6: what it cost -------------------------------------------
    kcyc_max = 0;
    $display("\n per-PE kernel cycles:");
    for (int unsigned p = 0; p < NumPes; p++) begin
      $display("  PE%0d  %0d", p, res(BR_CYCLES + p));
      if (res(BR_CYCLES + p) > kcyc_max) kcyc_max = res(BR_CYCLES + p);
    end
    $display("\n BENCH %s  memlat=%0d  slowest_pe_cycles=%0d  wall_cycles=%0d  all_done=%0d",
             Label, MemLat, kcyc_max, totcyc, cycle);

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
  //  Write-through / no-allocate never installs a line on a store, so a store
  //  hits only where a load had already pulled the line in. Kernels that write
  //  a result they never read back therefore show a write hit rate near zero
  //  by construction, which is why the three series are reported separately
  //  rather than as one number.
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
    // one machine-readable line, so a sweep can be scraped out of the logs
    $display(" BENCHSTAT %s rd_hit=%0d rd_tot=%0d wr_hit=%0d wr_tot=%0d",
             Label, trh, trh+trm, twh, twh+twm);
  endfunction

  initial begin
    #40ms;
    $display("*** %s TIMEOUT: done = %b ***", Label, done);
    $fatal(1);
  end

endmodule


// =============================================================================
//  The two architectures Section IV-B compares.
// =============================================================================
module tb_bench;
  bench_harness #(.Coherent(1'b1), .Label("tb_bench [coherent]")) h ();
endmodule

module tb_bench_nc;
  bench_harness #(.Coherent(1'b0), .Label("tb_bench_nc [non-coherent]")) h ();
endmodule

// -----------------------------------------------------------------------------
//  The same two, with a slower shared memory behind the fabric.
//
//  MemLat is the burst latency of the AXI SRAM: a read burst costs MemLat
//  cycles and then one beat per cycle. A cache only earns its keep when it is
//  hiding something, so the whole comparison moves with this number. At
//  MemLat=2 -- an on-chip BRAM answering almost immediately -- there is very
//  little to hide, which is why the streaming kernel does not gain there.
// -----------------------------------------------------------------------------
module tb_bench_l8;
  bench_harness #(.Coherent(1'b1), .Label("tb_bench [coherent]"),        .MemLat(8)) h ();
endmodule

module tb_bench_nc_l8;
  bench_harness #(.Coherent(1'b0), .Label("tb_bench_nc [non-coherent]"), .MemLat(8)) h ();
endmodule

module tb_bench_l20;
  bench_harness #(.Coherent(1'b1), .Label("tb_bench [coherent]"),        .MemLat(20)) h ();
endmodule

module tb_bench_nc_l20;
  bench_harness #(.Coherent(1'b0), .Label("tb_bench_nc [non-coherent]"), .MemLat(20)) h ();
endmodule
