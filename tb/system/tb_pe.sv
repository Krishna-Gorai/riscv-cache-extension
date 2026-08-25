// =============================================================================
//  tb_pe.sv -- single Processing Element bring-up (M4)
//
//  An unmodified CV32E40P runs a compiled bare-metal program out of its ITCM,
//  reaches the coherent shared data memory through the Data-Bridge and its
//  private DCU, and reports completion through the uncached control region.
//
//  The point of this testbench is that nothing in the core or in the program
//  knows the cache sub-system is there: the core issues ordinary loads and
//  stores, and the DCU counters afterwards show that they were cached.
//
//  Run with:  sim/run_xsim.ps1 -Tb tb_pe -Hex sw/build/smoke.hex
// =============================================================================
`timescale 1ns/1ps

module tb_pe;
  import cache_pkg::*;

  localparam int unsigned NumCores  = 1;
  localparam int unsigned AddrW     = 32;
  localparam int unsigned DataW     = 32;
  localparam int unsigned WordBytes = DataW/8;
  localparam int unsigned LineBytes = 16;
  localparam int unsigned LineBits  = LineBytes*8;
  localparam int unsigned MemWords  = 65536;     // 256 KiB of shared data memory

  localparam time CLK_P = 10ns;

  logic clk   = 1'b0;
  logic rst_n = 1'b0;
  logic fetch_en = 1'b0;
  always #(CLK_P/2) clk = ~clk;

  // ---------------------------------------------------------------------------
  //  PE <-> DCU
  // ---------------------------------------------------------------------------
  logic                 dcu_req, dcu_gnt, dcu_we, dcu_rvalid;
  logic [AddrW-1:0]     dcu_addr;
  logic [WordBytes-1:0] dcu_be;
  logic [DataW-1:0]     dcu_wdata, dcu_rdata;
  amo_e                 dcu_amo;

  // ---------------------------------------------------------------------------
  //  PE <-> everything off-PE, through the Data-Bridge's external port.
  //
  //  In the SoC this port goes to the AXI crossbar, which decodes it. A single
  //  PE has no crossbar, so the testbench decodes it here: the control region
  //  at 0x8, and the shared instruction memory at 0x2, which a single PE
  //  booting from its own ITCM never touches.
  // ---------------------------------------------------------------------------
  logic                 simem_i_req, simem_i_gnt, simem_i_rvalid;
  logic [AddrW-1:0]     simem_i_addr;
  logic [DataW-1:0]     simem_i_rdata;

  logic                 ext_req, ext_gnt, ext_we, ext_rvalid;
  logic [AddrW-1:0]     ext_addr;
  logic [WordBytes-1:0] ext_be;
  logic [DataW-1:0]     ext_wdata, ext_rdata;

  assign simem_i_gnt   = simem_i_req;
  assign simem_i_rdata = '0;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) simem_i_rvalid <= 1'b0;
    else        simem_i_rvalid <= simem_i_gnt;
  end

  logic        tohost_seen = 1'b0;
  logic [31:0] tohost_val  = '0;
  int unsigned cycle_count = 0;

  always_ff @(posedge clk) if (rst_n) cycle_count <= cycle_count + 1;

  assign ext_gnt = ext_req;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ext_rvalid <= 1'b0;
      ext_rdata  <= '0;
    end else begin
      ext_rvalid <= ext_gnt;
      ext_rdata  <= '0;
      if (ext_gnt && (ext_addr[AddrW-1 -: 4] == 4'h8)) begin
        if (ext_we) begin
          case (ext_addr[7:0])
            8'h00: begin
              tohost_val  <= ext_wdata;
              tohost_seen <= 1'b1;
            end
            8'h04: $write("%c", ext_wdata[7:0]);
            default: ;
          endcase
        end else if (ext_addr[7:0] == 8'h08) begin
          ext_rdata <= 32'(cycle_count);
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  //  DUT: one PE + the D-Cache Sub-system + the shared data memory
  // ---------------------------------------------------------------------------
  pe_top #(
    .AddrW     (AddrW),
    .DataW     (DataW),
    .ItcmBytes (32768),
    .BootAddr  (32'h0000_0000),
    .HartId    (0)
  ) u_pe (
    .clk_i          (clk),
    .rst_ni         (rst_n),
    .fetch_enable_i (fetch_en),

    .dcu_req_o      (dcu_req),
    .dcu_gnt_i      (dcu_gnt),
    .dcu_addr_o     (dcu_addr),
    .dcu_we_o       (dcu_we),
    .dcu_be_o       (dcu_be),
    .dcu_wdata_o    (dcu_wdata),
    .dcu_amo_o      (dcu_amo),
    .dcu_rvalid_i   (dcu_rvalid),
    .dcu_rdata_i    (dcu_rdata),

    .simem_i_req_o    (simem_i_req),
    .simem_i_gnt_i    (simem_i_gnt),
    .simem_i_addr_o   (simem_i_addr),
    .simem_i_rvalid_i (simem_i_rvalid),
    .simem_i_rdata_i  (simem_i_rdata),

    .ext_req_o        (ext_req),
    .ext_gnt_i        (ext_gnt),
    .ext_addr_o       (ext_addr),
    .ext_we_o         (ext_we),
    .ext_be_o         (ext_be),
    .ext_wdata_o      (ext_wdata),
    .ext_rvalid_i     (ext_rvalid),
    .ext_rdata_i      (ext_rdata),

    .core_sleep_o   ()
  );

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
    .NumWays   (2),
    .NumSets   (64),
    .LineBytes (LineBytes),
    .AddrW     (AddrW),
    .DataW     (DataW)
  ) u_dcache (
    .clk_i           (clk),
    .rst_ni          (rst_n),

    .core_req_i      (dcu_req),
    .core_gnt_o      (dcu_gnt),
    .core_addr_i     (dcu_addr),
    .core_we_i       (dcu_we),
    .core_be_i       (dcu_be),
    .core_wdata_i    (dcu_wdata),
    .core_amo_i      (dcu_amo),
    .core_rvalid_o   (dcu_rvalid),
    .core_rdata_o    (dcu_rdata),
    .core_sc_ok_o    (),

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

  string hexfile;

  initial begin
    if (!$value$plusargs("HEX=%s", hexfile)) hexfile = "program.hex";
    $display("\n--- loading ITCM from %s ---", hexfile);
    $readmemh(hexfile, u_pe.u_itcm.mem);

    for (int unsigned i = 0; i < MemWords; i++) u_mem.mem[i] = 32'hDEAD_0000 + i;

    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);
    fetch_en = 1'b1;

    $display("--- running ------------------------------------------------------");
    wait (tohost_seen);
    repeat (5) @(posedge clk);

    $display("\n--- results ------------------------------------------------------");
    $display(" tohost      = %0d  (1 = program returned success)", tohost_val);
    $display(" cycles      = %0d", cycle_count);
    $display(" DCU  rd_hit=%0d rd_miss=%0d wr_hit=%0d wr_miss=%0d",
             p_rd_hit, p_rd_miss, p_wr_hit, p_wr_miss);
    // Reported the way Fig. 7 of the paper does: read, write and average hit
    // rate separately. Under write-through / no-allocate a store never installs
    // a line, so a store-then-read kernel shows a write hit rate of zero while
    // the reads still hit on every reuse.
    begin
      automatic int unsigned rh = int'(p_rd_hit),  rm = int'(p_rd_miss);
      automatic int unsigned wh = int'(p_wr_hit),  wm = int'(p_wr_miss);
      $display(" read  hit rate = %0.2f %%  (%0d of %0d)",
               (rh+rm) ? 100.0*real'(rh)/real'(rh+rm) : 0.0, rh, rh+rm);
      $display(" write hit rate = %0.2f %%  (%0d of %0d)",
               (wh+wm) ? 100.0*real'(wh)/real'(wh+wm) : 0.0, wh, wh+wm);
      $display(" average        = %0.2f %%  (%0d of %0d)",
               100.0*real'(rh+wh)/real'(rh+rm+wh+wm), rh+wh, rh+rm+wh+wm);
    end

    chk(tohost_val == 32'd1, $sformatf("program reported success, got tohost=%0d", tohost_val));
    // 2 * sum_{i<64}(3i+1) = 2 * 6112
    chk(u_mem.peek(32'h1000 >> 2) == 32'd12224,
        $sformatf("checksum in shared memory: got %0d expected 12224",
                  u_mem.peek(32'h1000 >> 2)));
    chk(u_mem.peek((32'h1000 >> 2) + 1) == 32'hC0FFEE,
        "sentinel written to shared memory");
    chk(int'(p_rd_hit) + int'(p_rd_miss) > 0, "the DCU actually served the core");
    // the array is 64 words over 16 lines, touched three times: the second and
    // third pass must hit, so most reads have to be hits
    chk(int'(p_rd_hit) > int'(p_rd_miss), "the second pass over the array hit in the cache");

    $display("------------------------------------------------------------------");
    if (errors == 0) $display(" tb_pe PASSED  (%0d checks)\n", checks);
    else             $display(" tb_pe FAILED  (%0d errors / %0d checks)\n", errors, checks);
    if (errors != 0) $fatal(1);
    $finish;
  end

  initial begin
    #5ms;
    $display("*** tb_pe TIMEOUT (tohost never written) ***");
    $fatal(1);
  end

endmodule
