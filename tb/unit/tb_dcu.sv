// =============================================================================
//  tb_dcu.sv -- self-checking testbench for the Data Cache Unit (M1)
//
//  Covers every behaviour the paper specifies for a single DCU:
//    P1  compulsory read misses return memory content
//    P2  re-reads hit
//    P3  write-through and no-allocate, including byte enables
//    P4  INV REQ from the snoopy bus invalidates the line (Fig. 3c)
//    P5  special case 2 of Section III-B -- an INV REQ that arrives before the
//        MEM RESP forwards the data to the core without filling the line
//    P6  2-way associativity and the 1-bit LRU replacement decision
//    P7  randomised stress against a golden model with concurrent snoop
//        invalidation traffic
//    P8  store-conditional whose reservation was lost performs no write
// =============================================================================
`timescale 1ns/1ps

module tb_dcu;
  import cache_pkg::*;

  // ---- configuration: 2 KiB, 2-way, 16 B lines -> matches the paper's DCU ----
  localparam int unsigned NumWays      = 2;
  localparam int unsigned NumSets      = 64;
  localparam int unsigned LineBytes    = 16;
  localparam int unsigned AddrW        = 32;
  localparam int unsigned DataW        = 32;
  localparam int unsigned WordBytes    = DataW/8;
  localparam int unsigned WordsPerLine = LineBytes/WordBytes;
  localparam int unsigned LineBits     = LineBytes*8;
  localparam int unsigned OffsW        = $clog2(LineBytes);
  localparam int unsigned IdxW         = $clog2(NumSets);
  localparam int unsigned MemWords     = 4096;

  localparam time CLK_P = 10ns;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #(CLK_P/2) clk = ~clk;

  // ---------------------------------------------------------------------------
  //  DUT wiring
  // ---------------------------------------------------------------------------
  logic                 core_req, core_gnt;
  logic [AddrW-1:0]     core_addr;
  logic                 core_we;
  logic [WordBytes-1:0] core_be;
  logic [DataW-1:0]     core_wdata;
  amo_e                 core_amo;
  logic                 core_rvalid;
  logic [DataW-1:0]     core_rdata;
  logic                 core_sc_ok;

  logic                 snp_req, snp_is_inv;
  logic [AddrW-1:0]     snp_addr;
  amo_e                 snp_amo;
  logic                 snp_gnt;
  logic                 snp_excl_ok;

  logic                 snp_inv_valid, snp_inv_ready;
  logic [AddrW-1:0]     snp_inv_addr;

  logic                 mem_rd_req, mem_rd_gnt, mem_rd_rvalid;
  logic [AddrW-1:0]     mem_rd_addr;
  logic [LineBits-1:0]  mem_rd_rdata;

  logic                 mem_wr_req, mem_wr_gnt;
  logic [AddrW-1:0]     mem_wr_addr;
  logic [WordBytes-1:0] mem_wr_be;
  logic [DataW-1:0]     mem_wr_wdata;

  logic [31:0] p_rd_hit, p_rd_miss, p_wr_hit, p_wr_miss;

  dcu #(
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

    .snp_req_o       (snp_req),
    .snp_is_inv_o    (snp_is_inv),
    .snp_addr_o      (snp_addr),
    .snp_amo_o       (snp_amo),
    .snp_gnt_i       (snp_gnt),
    .snp_excl_ok_i   (snp_excl_ok),

    .snp_inv_valid_i (snp_inv_valid),
    .snp_inv_addr_i  (snp_inv_addr),
    .snp_inv_ready_o (snp_inv_ready),

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

  mem_model #(
    .AddrW     (AddrW),
    .DataW     (DataW),
    .LineBytes (LineBytes),
    .MemWords  (MemWords),
    .RdLat     (4),
    .WrLat     (1),
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
  //  Snoopy bus stub: grants stage-1 forwards after a pseudo-random delay.
  // ---------------------------------------------------------------------------
  logic [15:0] gnt_lfsr = 16'h1234;
  always_ff @(posedge clk) gnt_lfsr <= {gnt_lfsr[14:0],
                                        gnt_lfsr[15]^gnt_lfsr[13]^gnt_lfsr[12]^gnt_lfsr[10]};
  assign snp_gnt = snp_req && (gnt_lfsr[1] || gnt_lfsr[5]);

  logic tb_excl_ok = 1'b1;
  assign snp_excl_ok = tb_excl_ok;

  // ---------------------------------------------------------------------------
  //  Scoreboard bookkeeping
  // ---------------------------------------------------------------------------
  int unsigned errors  = 0;
  int unsigned checks  = 0;

  function automatic void chk(input bit cond, input string msg);
    checks++;
    if (!cond) begin
      errors++;
      $error("[%0t] CHECK FAILED: %s", $time, msg);
      if (errors > 25) begin
        $display("\n*** too many errors, aborting ***");
        $fatal(1);
      end
    end
  endfunction

  // golden model of memory content, indexed by word address
  logic [DataW-1:0] gold [MemWords];

  // ---------------------------------------------------------------------------
  //  Core driver
  // ---------------------------------------------------------------------------
  task automatic core_xact(input bit                 we,
                           input logic [AddrW-1:0]   addr,
                           input logic [WordBytes-1:0] be,
                           input logic [DataW-1:0]   wdata,
                           input amo_e               amo,
                           output logic [DataW-1:0]  rdata,
                           output bit                sc_ok);
    core_req   <= 1'b1;
    core_addr  <= addr;
    core_we    <= we;
    core_be    <= be;
    core_wdata <= wdata;
    core_amo   <= amo;
    forever begin
      @(posedge clk);
      if (core_gnt) break;
    end
    core_req <= 1'b0;
    core_amo <= AMO_NONE;
    forever begin
      @(posedge clk);
      if (core_rvalid) begin
        rdata = core_rdata;
        sc_ok = core_sc_ok;
        break;
      end
    end
    // The transaction retires on this very edge, so let the non-blocking
    // updates of the counters and of the memory array settle before the
    // caller inspects them.
    #1;
  endtask

  task automatic rd(input logic [AddrW-1:0] a, output logic [DataW-1:0] d);
    bit dummy;
    core_xact(1'b0, a, '1, '0, AMO_NONE, d, dummy);
  endtask

  task automatic wr(input logic [AddrW-1:0] a,
                    input logic [WordBytes-1:0] be,
                    input logic [DataW-1:0] d);
    logic [DataW-1:0] dummy_d;
    bit               dummy_s;
    core_xact(1'b1, a, be, d, AMO_NONE, dummy_d, dummy_s);
  endtask

  task automatic snoop_inv(input logic [AddrW-1:0] a);
    snp_inv_valid <= 1'b1;
    snp_inv_addr  <= a;
    forever begin
      @(posedge clk);
      if (snp_inv_ready) break;
    end
    snp_inv_valid <= 1'b0;
    // let the invalidation walk both pipeline stages before anything else looks
    repeat (3) @(posedge clk);
  endtask

  // helpers -------------------------------------------------------------------
  function automatic logic [AddrW-1:0] word_addr(input int unsigned widx);
    return AddrW'(widx * WordBytes);
  endfunction

  function automatic logic [DataW-1:0] be_merge(input logic [DataW-1:0] old_d,
                                                input logic [DataW-1:0] new_d,
                                                input logic [WordBytes-1:0] be);
    logic [DataW-1:0] r;
    for (int unsigned b = 0; b < WordBytes; b++) begin
      r[b*8 +: 8] = be[b] ? new_d[b*8 +: 8] : old_d[b*8 +: 8];
    end
    return r;
  endfunction

  // ---------------------------------------------------------------------------
  //  Stimulus
  // ---------------------------------------------------------------------------
  logic [DataW-1:0] d;
  logic [31:0]      snap_hit, snap_miss, snap_whit, snap_wmiss;

  initial begin
    core_req      = 1'b0;
    core_addr     = '0;
    core_we       = 1'b0;
    core_be       = '1;
    core_wdata    = '0;
    core_amo      = AMO_NONE;
    snp_inv_valid = 1'b0;
    snp_inv_addr  = '0;

    // seed memory and the golden model
    for (int unsigned i = 0; i < MemWords; i++) begin
      gold[i] = 32'hA5A5_0000 + i;
      u_mem.mem[i] = gold[i];
    end

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    // =========================================================================
    $display("\n--- P1: compulsory read misses --------------------------------");
    snap_miss = p_rd_miss;
    for (int unsigned i = 0; i < 32; i++) begin
      automatic int unsigned wi = i * WordsPerLine * 3;   // stride across sets
      rd(word_addr(wi), d);
      chk(d === gold[wi], $sformatf("P1 read a=%0h got %h exp %h", word_addr(wi), d, gold[wi]));
    end
    chk(p_rd_miss - snap_miss == 32, $sformatf("P1 expected 32 misses, got %0d", p_rd_miss - snap_miss));

    // =========================================================================
    $display("--- P2: the same lines now hit ---------------------------------");
    snap_hit  = p_rd_hit;
    snap_miss = p_rd_miss;
    for (int unsigned i = 0; i < 32; i++) begin
      automatic int unsigned wi = i * WordsPerLine * 3;
      rd(word_addr(wi), d);
      chk(d === gold[wi], "P2 read data");
    end
    chk(p_rd_hit - snap_hit == 32, $sformatf("P2 expected 32 hits, got %0d", p_rd_hit - snap_hit));
    chk(p_rd_miss == snap_miss,    "P2 expected no new misses");

    // =========================================================================
    $display("--- P3: write-through, no-allocate, byte enables ---------------");
    begin
      automatic int unsigned wi = 1000;              // untouched so far -> not cached
      snap_wmiss = p_wr_miss;
      wr(word_addr(wi), 4'hF, 32'hDEAD_BEEF);
      gold[wi] = 32'hDEAD_BEEF;
      chk(p_wr_miss - snap_wmiss == 1, "P3 write miss counted");
      chk(u_mem.peek(wi) === gold[wi], "P3 write reached memory (write-through)");

      // no-allocate: the very next read of that line must still miss
      snap_miss = p_rd_miss;
      rd(word_addr(wi), d);
      chk(d === gold[wi], "P3 read back written word");
      chk(p_rd_miss - snap_miss == 1, "P3 no-allocate: read after write-miss must miss");

      // now the line is cached -> a write to it is a write hit and updates both
      snap_whit = p_wr_hit;
      wr(word_addr(wi), 4'hF, 32'h1234_5678);
      gold[wi] = 32'h1234_5678;
      chk(p_wr_hit - snap_whit == 1, "P3 write hit counted");
      chk(u_mem.peek(wi) === gold[wi], "P3 write hit reached memory");
      snap_hit = p_rd_hit;
      rd(word_addr(wi), d);
      chk(d === gold[wi], "P3 cached read sees the updated word");
      chk(p_rd_hit - snap_hit == 1, "P3 write hit kept the line valid");

      // byte enables: touch only byte 1
      wr(word_addr(wi), 4'b0010, 32'hFFFF_AAFF);
      gold[wi] = be_merge(gold[wi], 32'hFFFF_AAFF, 4'b0010);
      chk(u_mem.peek(wi) === gold[wi],
          $sformatf("P3 byte-enabled write in memory: got %h exp %h", u_mem.peek(wi), gold[wi]));
      rd(word_addr(wi), d);
      chk(d === gold[wi], $sformatf("P3 byte-enabled write in cache: got %h exp %h", d, gold[wi]));
    end

    // =========================================================================
    $display("--- P4: INV REQ from the snoopy bus (Fig. 3c) ------------------");
    begin
      automatic int unsigned wi = 1500;
      rd(word_addr(wi), d);                     // miss, fills the line
      snap_hit = p_rd_hit;
      rd(word_addr(wi), d);                     // hit
      chk(p_rd_hit - snap_hit == 1, "P4 line is cached before invalidation");

      snoop_inv(word_addr(wi));

      // change memory behind the cache: only a real invalidation exposes this
      gold[wi] = 32'hCAFE_0001;
      u_mem.poke(wi, gold[wi]);

      snap_miss = p_rd_miss;
      rd(word_addr(wi), d);
      chk(p_rd_miss - snap_miss == 1, "P4 invalidated line must miss");
      chk(d === gold[wi], $sformatf("P4 got %h exp %h after invalidation", d, gold[wi]));
    end

    // =========================================================================
    $display("--- P5: INV REQ arriving before MEM RESP (special case 2) ------");
    begin
      automatic int unsigned wi = 1600;
      logic [DataW-1:0] got;
      snoop_inv(word_addr(wi));                 // make sure it is not cached

      fork
        rd(word_addr(wi), got);
        begin
          // land the invalidation inside the refill window
          wait (mem_rd_req === 1'b1);
          @(posedge clk);
          snoop_inv(word_addr(wi));
        end
      join

      chk(got === gold[wi], $sformatf("P5 refill data still correct: got %h exp %h", got, gold[wi]));

      // the line must NOT have been installed -> a backdoor change is visible
      gold[wi] = 32'hFEED_0002;
      u_mem.poke(wi, gold[wi]);
      snap_miss = p_rd_miss;
      rd(word_addr(wi), d);
      chk(p_rd_miss - snap_miss == 1, "P5 line was not filled during the INV race");
      chk(d === gold[wi], $sformatf("P5 got %h exp %h", d, gold[wi]));
    end

    // =========================================================================
    $display("--- P6: 2-way associativity and LRU replacement ----------------");
    begin
      automatic int unsigned set   = 7;
      automatic int unsigned stride = NumSets * WordsPerLine;   // same index, next tag
      automatic int unsigned w0 = set * WordsPerLine + 0*stride;
      automatic int unsigned w1 = set * WordsPerLine + 1*stride;
      automatic int unsigned w2 = set * WordsPerLine + 2*stride;

      snoop_inv(word_addr(w0));
      snoop_inv(word_addr(w1));
      snoop_inv(word_addr(w2));

      rd(word_addr(w0), d);  chk(d === gold[w0], "P6 w0 data");
      rd(word_addr(w1), d);  chk(d === gold[w1], "P6 w1 data");

      snap_hit = p_rd_hit;
      rd(word_addr(w0), d);                       // w0 becomes most recently used
      chk(p_rd_hit - snap_hit == 1, "P6 w0 cached");
      snap_hit = p_rd_hit;
      rd(word_addr(w1), d);                       // w1 becomes most recently used
      chk(p_rd_hit - snap_hit == 1, "P6 w1 cached");

      // both ways are valid, w0 is the LRU -> w2 must evict w0, not w1
      rd(word_addr(w2), d);  chk(d === gold[w2], "P6 w2 data");

      snap_hit = p_rd_hit;
      rd(word_addr(w1), d);
      chk(p_rd_hit - snap_hit == 1, "P6 LRU kept w1 resident");
      snap_miss = p_rd_miss;
      rd(word_addr(w0), d);
      chk(p_rd_miss - snap_miss == 1, "P6 LRU evicted w0");
    end

    // =========================================================================
    $display("--- P8: store-conditional with a lost reservation --------------");
    begin
      automatic int unsigned wi = 2000;
      logic [DataW-1:0] got;
      bit               ok;
      logic [DataW-1:0] prev_val;

      rd(word_addr(wi), d);                    // cache it
      prev_val = gold[wi];

      tb_excl_ok = 1'b0;
      core_xact(1'b1, word_addr(wi), '1, 32'hBAD0_BAD0, AMO_SC, got, ok);
      chk(ok === 1'b0, "P8 SC reports failure when the reservation is lost");
      chk(u_mem.peek(wi) === prev_val, "P8 failed SC performed no memory write");
      rd(word_addr(wi), d);
      chk(d === prev_val, "P8 failed SC left the cached word untouched");

      tb_excl_ok = 1'b1;
      core_xact(1'b1, word_addr(wi), '1, 32'h600D_600D, AMO_SC, got, ok);
      gold[wi] = 32'h600D_600D;
      chk(ok === 1'b1, "P8 SC reports success when the reservation is held");
      chk(u_mem.peek(wi) === gold[wi],
          $sformatf("P8 successful SC wrote memory: got %h exp %h", u_mem.peek(wi), gold[wi]));
      rd(word_addr(wi), d);
      chk(d === gold[wi], "P8 successful SC updated the cached word");
    end

    // =========================================================================
    $display("--- P7: randomised stress with concurrent snoop traffic --------");
    begin
      automatic int unsigned WIN_BASE = 2560;   // window that heavily aliases sets
      automatic int unsigned WIN_SIZE = 512;
      automatic int unsigned N_OPS    = 3000;
      automatic bit stress_done = 1'b0;

      fork
        // --- background invalidation traffic
        begin
          while (!stress_done) begin
            repeat ($urandom_range(4, 40)) @(posedge clk);
            if (!stress_done) begin
              automatic int unsigned wi = WIN_BASE + $urandom_range(0, WIN_SIZE-1);
              snoop_inv(word_addr(wi));
            end
          end
        end
        // --- core traffic checked against the golden model
        begin
          for (int unsigned n = 0; n < N_OPS; n++) begin
            automatic int unsigned wi = WIN_BASE + $urandom_range(0, WIN_SIZE-1);
            if ($urandom_range(0, 99) < 65) begin
              rd(word_addr(wi), d);
              chk(d === gold[wi],
                  $sformatf("P7 op%0d read a=%0h got %h exp %h", n, word_addr(wi), d, gold[wi]));
            end else begin
              automatic logic [WordBytes-1:0] be = WordBytes'($urandom_range(1, 15));
              automatic logic [DataW-1:0]     dv = $urandom();
              wr(word_addr(wi), be, dv);
              gold[wi] = be_merge(gold[wi], dv, be);
            end
          end
          stress_done = 1'b1;
        end
      join

      // write-through means the shared memory is always up to date
      for (int unsigned i = WIN_BASE; i < WIN_BASE + WIN_SIZE; i++) begin
        chk(u_mem.peek(i) === gold[i],
            $sformatf("P7 memory coherence at word %0d: got %h exp %h", i, u_mem.peek(i), gold[i]));
      end
    end

    // =========================================================================
    $display("\n================================================================");
    $display(" DCU counters: rd_hit=%0d rd_miss=%0d wr_hit=%0d wr_miss=%0d",
             p_rd_hit, p_rd_miss, p_wr_hit, p_wr_miss);
    $display(" hit rate = %0.2f %%",
             100.0 * real'(p_rd_hit + p_wr_hit) /
             real'(p_rd_hit + p_rd_miss + p_wr_hit + p_wr_miss));
    $display("----------------------------------------------------------------");
    if (errors == 0) $display(" tb_dcu PASSED  (%0d checks)", checks);
    else             $display(" tb_dcu FAILED  (%0d errors / %0d checks)", errors, checks);
    $display("================================================================\n");
    if (errors != 0) $fatal(1);
    $finish;
  end

  // watchdog
  initial begin
    #20ms;
    $display("*** tb_dcu TIMEOUT ***");
    $fatal(1);
  end

endmodule
