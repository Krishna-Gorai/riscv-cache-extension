// =============================================================================
//  tb_coherent_subsystem.sv -- multi-core coherence testbench (M2 + M3)
//
//  Drives NumCores DCUs tied together by the snoopy bus against a shared data
//  memory model, and checks the properties the paper's protocol has to provide.
//
//    S1  directed producer / consumer ping-pong across two cores
//    S2  Link Register and store-conditional semantics (Fig. 4)
//    S3  randomised four-core stress checked with a version monotonicity
//        invariant: a core that has observed version k of a location may never
//        afterwards observe a version below k. A missed or late invalidation
//        shows up here immediately, because it is exactly what lets a stale
//        cached line be served after a fresher one was already seen.
//    S4  quiesce, then have every core read the whole window: any line still
//        held stale in any cache is caught against the shared memory content.
// =============================================================================
`timescale 1ns/1ps

module tb_coherent_subsystem;
  import cache_pkg::*;

  localparam int unsigned NumCores     = 4;
  localparam int unsigned NumWays      = 2;
  localparam int unsigned NumSets      = 64;
  localparam int unsigned LineBytes    = 16;
  localparam int unsigned AddrW        = 32;
  localparam int unsigned DataW        = 32;
  localparam int unsigned WordBytes    = DataW/8;
  localparam int unsigned WordsPerLine = LineBytes/WordBytes;
  localparam int unsigned LineBits     = LineBytes*8;
  localparam int unsigned MemWords     = 8192;

  // shared window: small enough that all four cores collide constantly
  localparam int unsigned WIN_BASE = 1024;
  localparam int unsigned WIN_SIZE = 256;

  localparam time CLK_P = 10ns;

  logic clk   = 1'b0;
  logic rst_n = 1'b0;
  always #(CLK_P/2) clk = ~clk;

  // ---------------------------------------------------------------------------
  //  Per-core driver signals, packed into the flattened DUT ports
  // ---------------------------------------------------------------------------
  logic                 t_req   [NumCores];
  logic [AddrW-1:0]     t_addr  [NumCores];
  logic                 t_we    [NumCores];
  logic [WordBytes-1:0] t_be    [NumCores];
  logic [DataW-1:0]     t_wdata [NumCores];
  amo_e                 t_amo   [NumCores];

  logic [NumCores-1:0]           core_req, core_gnt, core_we, core_rvalid, core_sc_ok;
  logic [NumCores*AddrW-1:0]     core_addr;
  logic [NumCores*WordBytes-1:0] core_be;
  logic [NumCores*DataW-1:0]     core_wdata, core_rdata;
  logic [NumCores*2-1:0]         core_amo;

  always @(*) begin
    for (int unsigned c = 0; c < NumCores; c++) begin
      core_req[c]                       = t_req[c];
      core_we[c]                        = t_we[c];
      core_addr [c*AddrW     +: AddrW]  = t_addr[c];
      core_be   [c*WordBytes +: WordBytes] = t_be[c];
      core_wdata[c*DataW     +: DataW]  = t_wdata[c];
      core_amo  [c*2         +: 2]      = t_amo[c];
    end
  end

  // ---------------------------------------------------------------------------
  //  DUT + shared memory
  // ---------------------------------------------------------------------------
  logic [NumCores-1:0]           mem_rd_req, mem_rd_gnt, mem_rd_rvalid;
  logic [NumCores*AddrW-1:0]     mem_rd_addr;
  logic [NumCores*LineBits-1:0]  mem_rd_rdata;

  logic [NumCores-1:0]           mem_wr_req, mem_wr_gnt;
  logic [NumCores*AddrW-1:0]     mem_wr_addr;
  logic [NumCores*WordBytes-1:0] mem_wr_be;
  logic [NumCores*DataW-1:0]     mem_wr_wdata;

  logic [NumCores*32-1:0] p_rd_hit, p_rd_miss, p_wr_hit, p_wr_miss;

  coherent_subsystem #(
    .NumCores  (NumCores),
    .NumWays   (NumWays),
    .NumSets   (NumSets),
    .LineBytes (LineBytes),
    .AddrW     (AddrW),
    .DataW     (DataW)
  ) dut (
    .clk_i           (clk),
    .rst_ni          (rst_n),

    .core_req_i      (core_req),
    .core_gnt_o      (core_gnt),
    .core_addr_i     (core_addr),
    .core_we_i       (core_we),
    .core_be_i       (core_be),
    .core_wdata_i    (core_wdata),
    .core_amo_i      (core_amo),
    .core_rvalid_o   (core_rvalid),
    .core_rdata_o    (core_rdata),
    .core_sc_ok_o    (core_sc_ok),

    .mem_rd_req_o    (mem_rd_req),
    .mem_rd_addr_o   (mem_rd_addr),
    .mem_rd_gnt_i    (mem_rd_gnt),
    .mem_rd_rvalid_i (mem_rd_rvalid),
    .mem_rd_rdata_i  (mem_rd_rdata),

    .mem_wr_req_o    (mem_wr_req),
    .mem_wr_addr_o   (mem_wr_addr),
    .mem_wr_be_o     (mem_wr_be),
    .mem_wr_wdata_o  (mem_wr_wdata),
    .mem_wr_gnt_i    (mem_wr_gnt),

    .perf_rd_hit_o   (p_rd_hit),
    .perf_rd_miss_o  (p_rd_miss),
    .perf_wr_hit_o   (p_wr_hit),
    .perf_wr_miss_o  (p_wr_miss)
  );

  shared_mem_model #(
    .NumPorts  (NumCores),
    .AddrW     (AddrW),
    .DataW     (DataW),
    .LineBytes (LineBytes),
    .MemWords  (MemWords),
    .RdLat     (6),
    .Backpress (1'b1)
  ) u_mem (
    .clk_i       (clk),
    .rst_ni      (rst_n),
    .rd_req_i    (mem_rd_req),
    .rd_addr_i   (mem_rd_addr),
    .rd_gnt_o    (mem_rd_gnt),
    .rd_rvalid_o (mem_rd_rvalid),
    .rd_rdata_o  (mem_rd_rdata),
    .wr_req_i    (mem_wr_req),
    .wr_addr_i   (mem_wr_addr),
    .wr_be_i     (mem_wr_be),
    .wr_wdata_i  (mem_wr_wdata),
    .wr_gnt_o    (mem_wr_gnt)
  );

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

  // version bookkeeping for the monotonicity invariant
  int unsigned wr_seq    [MemWords];              // versions published so far
  int unsigned last_seen [NumCores][MemWords];    // newest version each core saw

  function automatic logic [DataW-1:0] encode(input int unsigned a, input int unsigned seq);
    return {16'(a), 16'(seq)};
  endfunction

  function automatic logic [AddrW-1:0] word_addr(input int unsigned widx);
    return AddrW'(widx * WordBytes);
  endfunction

  // ---------------------------------------------------------------------------
  //  Core drivers
  // ---------------------------------------------------------------------------
  task automatic core_xact(input  int unsigned         c,
                           input  bit                  we,
                           input  logic [AddrW-1:0]    addr,
                           input  logic [WordBytes-1:0] be,
                           input  logic [DataW-1:0]    wdata,
                           input  amo_e                amo,
                           output logic [DataW-1:0]    rdata,
                           output bit                  sc_ok);
    t_req[c]   <= 1'b1;
    t_addr[c]  <= addr;
    t_we[c]    <= we;
    t_be[c]    <= be;
    t_wdata[c] <= wdata;
    t_amo[c]   <= amo;
    forever begin
      @(posedge clk);
      if (core_gnt[c]) break;
    end
    t_req[c] <= 1'b0;
    t_amo[c] <= AMO_NONE;
    forever begin
      @(posedge clk);
      if (core_rvalid[c]) begin
        rdata = core_rdata[c*DataW +: DataW];
        sc_ok = core_sc_ok[c];
        break;
      end
    end
    #1;   // let the non-blocking updates of memory and counters settle
  endtask

  task automatic rd(input int unsigned c, input logic [AddrW-1:0] a,
                    output logic [DataW-1:0] d);
    bit dummy;
    core_xact(c, 1'b0, a, '1, '0, AMO_NONE, d, dummy);
  endtask

  task automatic wr(input int unsigned c, input logic [AddrW-1:0] a,
                    input logic [DataW-1:0] d);
    logic [DataW-1:0] dd;
    bit               ds;
    core_xact(c, 1'b1, a, '1, d, AMO_NONE, dd, ds);
  endtask

  // A read that also enforces the coherence invariants.
  task automatic checked_read(input int unsigned c, input int unsigned wi,
                              input string tag);
    logic [DataW-1:0] d;
    int unsigned      got_addr, got_seq;
    rd(c, word_addr(wi), d);
    got_addr = int'(d[31:16]);
    got_seq  = int'(d[15:0]);

    chk(got_addr == wi,
        $sformatf("%s core%0d word%0d: value belongs to word %0d", tag, c, wi, got_addr));
    chk(got_seq <= wr_seq[wi],
        $sformatf("%s core%0d word%0d: saw version %0d, only %0d published",
                  tag, c, wi, got_seq, wr_seq[wi]));
    chk(got_seq >= last_seen[c][wi],
        $sformatf("%s COHERENCE VIOLATION core%0d word%0d: version went backwards, %0d after %0d",
                  tag, c, wi, got_seq, last_seen[c][wi]));
    if (got_seq > last_seen[c][wi]) last_seen[c][wi] = got_seq;
  endtask

  task automatic checked_write(input int unsigned c, input int unsigned wi);
    wr_seq[wi]++;
    wr(c, word_addr(wi), encode(wi, wr_seq[wi]));
    // the writer itself must never observe an older version afterwards
    if (wr_seq[wi] > last_seen[c][wi]) last_seen[c][wi] = wr_seq[wi];
  endtask


  // --- snoopy bus tracing, enabled with +TRACE_BUS ---------------------------
  //     Prints every request, grant and invalidation broadcast of the first
  //     microsecond, which is the quickest way to see the protocol in action.
  bit trace_bus = 0;
  initial trace_bus = $test$plusargs("TRACE_BUS");
  always_ff @(posedge clk) begin
    if (trace_bus && $time < 1200ns && rst_n) begin
      for (int unsigned c = 0; c < NumCores; c++) begin
        if (dut.snp_req[c])
          $display("[%0t] c%0d SNPREQ is_inv=%0b addr=%h gnt=%0b rdblk=%0b",
                   $time, c, dut.snp_is_inv[c], dut.snp_addr[c*AddrW +: AddrW],
                   dut.snp_gnt[c], dut.u_snoopy_bus.read_blocked[c]);
        if (dut.inv_valid[c])
          $display("[%0t] c%0d <-- INV BROADCAST addr=%h ready=%0b",
                   $time, c, dut.inv_addr[c*AddrW +: AddrW], dut.inv_ready[c]);
      end
      if (dut.u_snoopy_bus.inv_arb_valid)
        $display("[%0t] BUS invarb idx=%0d gntvalid=%0b bcast=%0b others_rdy=%0b",
                 $time, dut.u_snoopy_bus.inv_arb_idx, dut.u_snoopy_bus.inv_gnt_valid,
                 dut.u_snoopy_bus.bcast_needed, dut.u_snoopy_bus.others_ready);
    end
  end

  // ---------------------------------------------------------------------------
  //  Stimulus
  // ---------------------------------------------------------------------------
  logic [DataW-1:0] d;
  bit               ok0, ok1;
  logic [DataW-1:0] dd;

  // Control for the INVUSE counters: this testbench shares deliberately, with a
  // producer/consumer ping-pong, so it must report a non-zero useful count. If
  // it does not, the counter is broken and the zeroes the benchmarks report
  // mean nothing.
`ifndef SYNTHESIS
  logic [31:0] inv_rx_w  [NumCores];
  logic [31:0] inv_use_w [NumCores];
  for (genvar c = 0; c < NumCores; c++) begin : g_invuse
    assign inv_rx_w[c]  = dut.g_dcu[c].u_dcu.dbg_inv_rx;
    assign inv_use_w[c] = dut.g_dcu[c].u_dcu.dbg_inv_useful;
  end

  final begin
    automatic longint unsigned rx = 0;
    automatic longint unsigned useful = 0;
    for (int unsigned c = 0; c < NumCores; c++) begin
      rx     += inv_rx_w[c];
      useful += inv_use_w[c];
    end
    $display(" INVUSE tb_coherent_subsystem rx=%0d useful=%0d pct=%0.2f",
             rx, useful, (rx == 0) ? 0.0 : 100.0 * real'(useful) / real'(rx));
  end
`endif

  initial begin
    for (int unsigned c = 0; c < NumCores; c++) begin
      t_req[c]   = 1'b0;
      t_addr[c]  = '0;
      t_we[c]    = 1'b0;
      t_be[c]    = '1;
      t_wdata[c] = '0;
      t_amo[c]   = AMO_NONE;
    end

    for (int unsigned i = 0; i < MemWords; i++) begin
      wr_seq[i]    = 0;
      u_mem.mem[i] = encode(i, 0);
      for (int unsigned c = 0; c < NumCores; c++) last_seen[c][i] = 0;
    end

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    // =========================================================================
    $display("\n--- S1: producer / consumer ping-pong across two cores --------");
    begin
      automatic int unsigned wi = WIN_BASE + 5;
      // core 1 caches the line first, so every later update must invalidate it
      checked_read(1, wi, "S1");
      for (int unsigned n = 0; n < 40; n++) begin
        checked_write(0, wi);
        checked_read (1, wi, "S1");
        chk(last_seen[1][wi] == wr_seq[wi],
            $sformatf("S1 consumer saw version %0d, producer published %0d",
                      last_seen[1][wi], wr_seq[wi]));
      end
    end

    // =========================================================================
    $display("--- S2: Link Register and store-conditional -------------------");
    begin
      automatic int unsigned wi = WIN_BASE + 64;

      // a) plain LR then SC by the same core succeeds
      core_xact(0, 1'b0, word_addr(wi), '1, '0, AMO_LR, dd, ok0);
      core_xact(0, 1'b1, word_addr(wi), '1, 32'h1111_1111, AMO_SC, dd, ok0);
      chk(ok0 === 1'b1, "S2a uncontended SC succeeds");
      chk(u_mem.peek(wi) === 32'h1111_1111, "S2a successful SC reached memory");

      // b) a second LR takes over the single Link Register, so the first
      //    core's SC must fail
      core_xact(0, 1'b0, word_addr(wi), '1, '0, AMO_LR, dd, ok0);
      core_xact(1, 1'b0, word_addr(wi), '1, '0, AMO_LR, dd, ok1);
      core_xact(0, 1'b1, word_addr(wi), '1, 32'h2222_2222, AMO_SC, dd, ok0);
      chk(ok0 === 1'b0, "S2b SC fails after another core reserved the line");
      chk(u_mem.peek(wi) === 32'h1111_1111, "S2b failed SC performed no write");
      core_xact(1, 1'b1, word_addr(wi), '1, 32'h3333_3333, AMO_SC, dd, ok1);
      chk(ok1 === 1'b1, "S2b the newer reservation holder succeeds");
      chk(u_mem.peek(wi) === 32'h3333_3333, "S2b successful SC reached memory");

      // c) an intervening plain write breaks the reservation
      core_xact(0, 1'b0, word_addr(wi), '1, '0, AMO_LR, dd, ok0);
      wr(2, word_addr(wi), 32'h4444_4444);
      core_xact(0, 1'b1, word_addr(wi), '1, 32'h5555_5555, AMO_SC, dd, ok0);
      chk(ok0 === 1'b0, "S2c SC fails after a remote write invalidated the line");
      chk(u_mem.peek(wi) === 32'h4444_4444, "S2c failed SC performed no write");

      // restore the version encoding for this word before the stress phase
      wr(2, word_addr(wi), encode(wi, wr_seq[wi]));
    end

    // =========================================================================
    $display("--- S3: randomised four-core stress ---------------------------");
    begin
      automatic int unsigned N_OPS = 900;
      for (int unsigned c = 0; c < NumCores; c++) begin
        fork
          automatic int unsigned cc = c;
          begin
            for (int unsigned n = 0; n < N_OPS; n++) begin
              automatic int unsigned wi;
              if ($urandom_range(0, 99) < 30) begin
                // each word is written by exactly one core, so the published
                // version sequence per word stays well defined
                wi = WIN_BASE + cc + NumCores * $urandom_range(0, WIN_SIZE/NumCores - 1);
                checked_write(cc, wi);
              end else begin
                wi = WIN_BASE + $urandom_range(0, WIN_SIZE-1);
                checked_read(cc, wi, "S3");
              end
            end
          end
        join_none
      end
      wait fork;
    end

    // =========================================================================
    $display("--- S4: quiesce, then every core re-reads the whole window ----");
    repeat (50) @(posedge clk);
    begin
      for (int unsigned c = 0; c < NumCores; c++) begin
        for (int unsigned i = 0; i < WIN_SIZE; i++) begin
          automatic int unsigned wi = WIN_BASE + i;
          rd(c, word_addr(wi), d);
          chk(d === u_mem.peek(wi),
              $sformatf("S4 stale line: core%0d word%0d got %h, memory holds %h",
                        c, wi, d, u_mem.peek(wi)));
        end
      end
    end

    // =========================================================================
    $display("\n================================================================");
    for (int unsigned c = 0; c < NumCores; c++) begin
      automatic int unsigned h = int'(p_rd_hit[c*32 +: 32]) + int'(p_wr_hit[c*32 +: 32]);
      automatic int unsigned m = int'(p_rd_miss[c*32 +: 32]) + int'(p_wr_miss[c*32 +: 32]);
      $display(" DCU%0d  rd_hit=%0d rd_miss=%0d wr_hit=%0d wr_miss=%0d  hit rate = %0.2f %%",
               c, p_rd_hit[c*32 +: 32], p_rd_miss[c*32 +: 32],
               p_wr_hit[c*32 +: 32], p_wr_miss[c*32 +: 32],
               100.0 * real'(h) / real'(h + m));
    end
    $display("----------------------------------------------------------------");
    if (errors == 0) $display(" tb_coherent_subsystem PASSED  (%0d checks)", checks);
    else             $display(" tb_coherent_subsystem FAILED  (%0d errors / %0d checks)",
                              errors, checks);
    $display("================================================================\n");
    if (errors != 0) $fatal(1);
    $finish;
  end

  initial begin
    #200ms;
    $display("*** tb_coherent_subsystem TIMEOUT ***");
    $fatal(1);
  end

endmodule
