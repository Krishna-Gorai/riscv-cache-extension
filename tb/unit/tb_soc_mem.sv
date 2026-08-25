// =============================================================================
//  tb_soc_mem.sv -- unit tests for the SoC-level blocks added in M5.
//
//  Covers the four modules that sit between the PEs and the outside world:
//
//    shared_instr_mem   multi-port pipelined boot memory
//    shared_data_mem    dual-ported scratchpad, line reads and word reads
//    soc_ctrl           control region, including the hardware barrier
//    dcu_bypass         the non-coherent baseline data path
//
//  None of them needs a RISC-V core, so this testbench elaborates on any
//  SystemVerilog simulator and is the fastest way to check the M5 plumbing
//  before spending minutes booting four CV32E40Ps in tb_soc.
//
//  Written without procedural `automatic` variables or `break`, so that it runs
//  on Icarus Verilog (-g2012) as well as xsim.
// =============================================================================
`timescale 1ns/1ps

module tb_soc_mem;
  import cache_pkg::*;

  localparam int unsigned NP        = 4;
  localparam int unsigned AddrW     = 32;
  localparam int unsigned DataW     = 32;
  localparam int unsigned WB        = DataW/8;
  localparam int unsigned LineBytes = 16;
  localparam int unsigned LineBits  = LineBytes*8;
  localparam int unsigned WPL       = LineBytes/(DataW/8);

  localparam time CLK_P = 10ns;

  logic clk   = 1'b0;
  logic rst_n = 1'b0;
  always #(CLK_P/2) clk = ~clk;

  int unsigned errors = 0;
  int unsigned checks = 0;

  task chk(input bit cond, input string msg);
    begin
      checks = checks + 1;
      if (!cond) begin
        errors = errors + 1;
        $display("  [%0t] CHECK FAILED: %s", $time, msg);
      end
    end
  endtask

  // ===========================================================================
  //  DUT 1 -- shared instruction memory
  // ===========================================================================
  logic [NP-1:0]       si_req, si_gnt, si_rvalid;
  logic [NP*AddrW-1:0] si_addr;
  logic [NP*DataW-1:0] si_rdata;

  shared_instr_mem #(
    .NumPorts (NP), .AddrW (AddrW), .DataW (DataW),
    .SizeBytes (4096), .AccessLat (2)
  ) u_si (
    .clk_i (clk), .rst_ni (rst_n),
    .req_i (si_req), .addr_i (si_addr),
    .gnt_o (si_gnt), .rvalid_o (si_rvalid), .rdata_o (si_rdata)
  );

  // ===========================================================================
  //  DUT 2 -- shared data memory
  // ===========================================================================
  logic [NP-1:0]          sd_rd_req, sd_rd_line, sd_rd_gnt, sd_rd_rvalid;
  logic [NP*AddrW-1:0]    sd_rd_addr;
  logic [NP*LineBits-1:0] sd_rd_rdata;

  logic [NP-1:0]          sd_wr_req, sd_wr_gnt;
  logic [NP*AddrW-1:0]    sd_wr_addr;
  logic [NP*WB-1:0]       sd_wr_be;
  logic [NP*DataW-1:0]    sd_wr_wdata;

  shared_data_mem #(
    .NumPorts (NP), .AddrW (AddrW), .DataW (DataW),
    .LineBytes (LineBytes), .SizeBytes (8192), .AccessLat (2)
  ) u_sd (
    .clk_i (clk), .rst_ni (rst_n),
    .rd_req_i (sd_rd_req), .rd_addr_i (sd_rd_addr), .rd_line_i (sd_rd_line),
    .rd_gnt_o (sd_rd_gnt), .rd_rvalid_o (sd_rd_rvalid), .rd_rdata_o (sd_rd_rdata),
    .wr_req_i (sd_wr_req), .wr_addr_i (sd_wr_addr), .wr_be_i (sd_wr_be),
    .wr_wdata_i (sd_wr_wdata), .wr_gnt_o (sd_wr_gnt)
  );

  // ===========================================================================
  //  DUT 3 -- control region
  // ===========================================================================
  logic [NP-1:0]       ct_req, ct_gnt, ct_we, ct_rvalid;
  logic [NP*AddrW-1:0] ct_addr;
  logic [NP*WB-1:0]    ct_be;
  logic [NP*DataW-1:0] ct_wdata, ct_rdata;
  logic [NP-1:0]       ct_done;
  logic [NP*DataW-1:0] ct_exit;
  logic                ct_pc_valid;
  logic [7:0]          ct_pc_data;
  logic [31:0]         ct_cycle;

  soc_ctrl #(.NumPes (NP), .AddrW (AddrW), .DataW (DataW)) u_ct (
    .clk_i (clk), .rst_ni (rst_n),
    .req_i (ct_req), .gnt_o (ct_gnt), .addr_i (ct_addr), .we_i (ct_we),
    .be_i (ct_be), .wdata_i (ct_wdata), .rvalid_o (ct_rvalid), .rdata_o (ct_rdata),
    .done_o (ct_done), .exit_code_o (ct_exit),
    .putchar_valid_o (ct_pc_valid), .putchar_data_o (ct_pc_data),
    .cycle_o (ct_cycle)
  );

  // registered views, so the stimulus can see what actually took effect
  logic [NP-1:0] si_gnt_q, sd_rd_gnt_q, sd_wr_gnt_q, ct_gnt_q;
  always_ff @(posedge clk) begin
    si_gnt_q    <= si_gnt;
    sd_rd_gnt_q <= sd_rd_gnt;
    sd_wr_gnt_q <= sd_wr_gnt;
    ct_gnt_q    <= ct_gnt;
  end

  // ===========================================================================
  //  DUT 4 -- the non-coherent baseline, driven against its own memory
  // ===========================================================================
  logic             bp_req, bp_gnt, bp_we, bp_rvalid;
  logic [AddrW-1:0] bp_addr;
  logic [WB-1:0]    bp_be;
  logic [DataW-1:0] bp_wdata, bp_rdata;

  logic             bpm_rd_req, bpm_rd_line, bpm_rd_gnt, bpm_rd_rvalid;
  logic [AddrW-1:0] bpm_rd_addr;
  logic [LineBits-1:0] bpm_rd_rdata;
  logic             bpm_wr_req, bpm_wr_gnt;
  logic [AddrW-1:0] bpm_wr_addr;
  logic [WB-1:0]    bpm_wr_be;
  logic [DataW-1:0] bpm_wr_wdata;

  logic [31:0]      bp_rd_hit, bp_rd_miss, bp_wr_hit, bp_wr_miss;

  // Give the qualifier an explicitly typed net: an enum literal connected
  // straight to a port is sized inconsistently across simulators.
  logic [1:0]       bp_amo;
  assign bp_amo = AMO_NONE;

  dcu_bypass #(.AddrW (AddrW), .DataW (DataW), .LineBytes (LineBytes)) u_bp (
    .clk_i (clk), .rst_ni (rst_n),
    .core_req_i (bp_req), .core_gnt_o (bp_gnt), .core_addr_i (bp_addr),
    .core_we_i (bp_we), .core_be_i (bp_be), .core_wdata_i (bp_wdata),
    .core_amo_i (bp_amo),
    .core_rvalid_o (bp_rvalid), .core_rdata_o (bp_rdata), .core_sc_ok_o (),
    .mem_rd_req_o (bpm_rd_req), .mem_rd_addr_o (bpm_rd_addr),
    .mem_rd_gnt_i (bpm_rd_gnt), .mem_rd_rvalid_i (bpm_rd_rvalid),
    .mem_rd_rdata_i (bpm_rd_rdata),
    .mem_wr_req_o (bpm_wr_req), .mem_wr_addr_o (bpm_wr_addr),
    .mem_wr_be_o (bpm_wr_be), .mem_wr_wdata_o (bpm_wr_wdata),
    .mem_wr_gnt_i (bpm_wr_gnt),
    .perf_rd_hit_o (bp_rd_hit), .perf_rd_miss_o (bp_rd_miss),
    .perf_wr_hit_o (bp_wr_hit), .perf_wr_miss_o (bp_wr_miss)
  );

  assign bpm_rd_line = 1'b0;    // the baseline only ever reads single words

  shared_data_mem #(
    .NumPorts (1), .AddrW (AddrW), .DataW (DataW),
    .LineBytes (LineBytes), .SizeBytes (8192), .AccessLat (2)
  ) u_bpmem (
    .clk_i (clk), .rst_ni (rst_n),
    .rd_req_i (bpm_rd_req), .rd_addr_i (bpm_rd_addr), .rd_line_i (bpm_rd_line),
    .rd_gnt_o (bpm_rd_gnt), .rd_rvalid_o (bpm_rd_rvalid), .rd_rdata_o (bpm_rd_rdata),
    .wr_req_i (bpm_wr_req), .wr_addr_i (bpm_wr_addr), .wr_be_i (bpm_wr_be),
    .wr_wdata_i (bpm_wr_wdata), .wr_gnt_o (bpm_wr_gnt)
  );

  // ===========================================================================
  //  Stimulus
  // ===========================================================================
  integer i, p, w, g;
  integer got_cnt;
  logic [DataW-1:0] expect_word;
  logic [31:0] gen_before, gen_after;
  logic [31:0] cyc_a, cyc_b;
  logic [NP-1:0] pending;
  logic [NP-1:0] served;

  initial begin
    si_req = '0; si_addr = '0;
    sd_rd_req = '0; sd_rd_addr = '0; sd_rd_line = '0;
    sd_wr_req = '0; sd_wr_addr = '0; sd_wr_be = '0; sd_wr_wdata = '0;
    ct_req = '0; ct_addr = '0; ct_we = '0; ct_be = '0; ct_wdata = '0;
    bp_req = 1'b0; bp_addr = '0; bp_we = 1'b0; bp_be = '0; bp_wdata = '0;

    // Preload both memories with recognisable patterns.
    for (i = 0; i < 1024; i = i + 1) begin
      u_si.mem[i]    = 32'hA000_0000 + i;
      u_sd.mem[i]    = 32'hD000_0000 + i;
      u_bpmem.mem[i] = 32'hB000_0000 + i;
    end

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (3) @(posedge clk);

    // =========================================================================
    $display("\n--- P1: shared_instr_mem, one port -------------------------------");
    // =========================================================================
    for (i = 0; i < 8; i = i + 1) begin
      si_addr[0*AddrW +: AddrW] = i*4;
      si_req[0] = 1'b1;
      @(posedge clk); #1;
      si_req[0] = 1'b0;
      // wait for the response
      got_cnt = 0;
      while (!si_rvalid[0] && got_cnt < 20) begin
        @(posedge clk); #1;
        got_cnt = got_cnt + 1;
      end
      chk(si_rvalid[0], $sformatf("simem port0 responded to word %0d", i));
      chk(si_rdata[0*DataW +: DataW] == (32'hA000_0000 + i),
          $sformatf("simem[%0d] = %08x expected %08x",
                    i, si_rdata[0*DataW +: DataW], 32'hA000_0000 + i));
      @(posedge clk); #1;
    end

    // =========================================================================
    $display("--- P2: shared_instr_mem, four ports contending ------------------");
    // =========================================================================
    //  Every port asks for a different word at the same time. Each must get
    //  its own data, and the round robin must serve all four.
    for (p = 0; p < NP; p = p + 1) si_addr[p*AddrW +: AddrW] = (100 + p) * 4;
    si_req  = '1;
    pending = '1;
    served  = '0;
    got_cnt = 0;
    while ((pending != 0 || served != {NP{1'b1}}) && got_cnt < 40) begin
      @(posedge clk); #1;
      // drop each request once it has been granted
      si_req  = si_req  & ~si_gnt_q;
      pending = pending & ~si_gnt_q;
      for (p = 0; p < NP; p = p + 1) begin
        if (si_rvalid[p]) begin
          served[p] = 1'b1;
          chk(si_rdata[p*DataW +: DataW] == (32'hA000_0000 + 100 + p),
              $sformatf("simem port%0d got %08x expected %08x", p,
                        si_rdata[p*DataW +: DataW], 32'hA000_0000 + 100 + p));
        end
      end
      got_cnt = got_cnt + 1;
    end
    chk(served == {NP{1'b1}}, "all four instruction ports were served");

    // =========================================================================
    $display("--- P3: shared_data_mem, word read ------------------------------");
    // =========================================================================
    sd_rd_addr[0*AddrW +: AddrW] = 32'd40;      // word 10
    sd_rd_line[0] = 1'b0;
    sd_rd_req[0]  = 1'b1;
    @(posedge clk); #1;
    sd_rd_req[0] = 1'b0;
    got_cnt = 0;
    while (!sd_rd_rvalid[0] && got_cnt < 20) begin
      @(posedge clk); #1; got_cnt = got_cnt + 1;
    end
    chk(sd_rd_rvalid[0], "sdmem word read responded");
    chk(sd_rd_rdata[0*LineBits +: DataW] == (32'hD000_0000 + 10),
        $sformatf("sdmem word read = %08x expected %08x",
                  sd_rd_rdata[0*LineBits +: DataW], 32'hD000_0000 + 10));

    // =========================================================================
    $display("--- P4: shared_data_mem, line read ------------------------------");
    // =========================================================================
    //  A line read must return WPL consecutive words, lane 0 lowest.
    sd_rd_addr[1*AddrW +: AddrW] = 32'd64;      // line base, word 16
    sd_rd_line[1] = 1'b1;
    sd_rd_req[1]  = 1'b1;
    @(posedge clk); #1;
    sd_rd_req[1] = 1'b0;
    got_cnt = 0;
    while (!sd_rd_rvalid[1] && got_cnt < 30) begin
      @(posedge clk); #1; got_cnt = got_cnt + 1;
    end
    chk(sd_rd_rvalid[1], "sdmem line read responded");
    for (w = 0; w < WPL; w = w + 1) begin
      expect_word = 32'hD000_0000 + 16 + w;
      chk(sd_rd_rdata[1*LineBits + w*DataW +: DataW] == expect_word,
          $sformatf("line lane %0d = %08x expected %08x", w,
                    sd_rd_rdata[1*LineBits + w*DataW +: DataW], expect_word));
    end

    // =========================================================================
    $display("--- P5: shared_data_mem, four concurrent line reads -------------");
    // =========================================================================
    for (p = 0; p < NP; p = p + 1) sd_rd_addr[p*AddrW +: AddrW] = (32 + p*4) * 4;
    sd_rd_line = '1;
    sd_rd_req  = '1;
    served     = '0;
    got_cnt    = 0;
    while (served != {NP{1'b1}} && got_cnt < 80) begin
      @(posedge clk); #1;
      sd_rd_req = sd_rd_req & ~sd_rd_gnt_q;
      for (p = 0; p < NP; p = p + 1) begin
        if (sd_rd_rvalid[p]) begin
          served[p] = 1'b1;
          for (w = 0; w < WPL; w = w + 1) begin
            chk(sd_rd_rdata[p*LineBits + w*DataW +: DataW]
                  == (32'hD000_0000 + 32 + p*4 + w),
                $sformatf("port%0d line lane %0d = %08x expected %08x", p, w,
                          sd_rd_rdata[p*LineBits + w*DataW +: DataW],
                          32'hD000_0000 + 32 + p*4 + w));
          end
        end
      end
      got_cnt = got_cnt + 1;
    end
    chk(served == {NP{1'b1}}, "all four data ports got their line");
    sd_rd_line = '0;

    // =========================================================================
    $display("--- P6: shared_data_mem, byte-enabled writes --------------------");
    // =========================================================================
    sd_wr_addr [0*AddrW +: AddrW] = 32'd200;    // word 50
    sd_wr_wdata[0*DataW +: DataW] = 32'h1122_3344;
    sd_wr_be   [0*WB    +: WB]    = 4'b1111;
    sd_wr_req[0] = 1'b1;
    @(posedge clk); #1;
    sd_wr_req[0] = 1'b0;
    @(posedge clk); #1;
    chk(u_sd.peek(50) == 32'h1122_3344,
        $sformatf("full word write: got %08x", u_sd.peek(50)));

    // now only the two low bytes
    sd_wr_wdata[0*DataW +: DataW] = 32'hAABB_CCDD;
    sd_wr_be   [0*WB    +: WB]    = 4'b0011;
    sd_wr_req[0] = 1'b1;
    @(posedge clk); #1;
    sd_wr_req[0] = 1'b0;
    @(posedge clk); #1;
    chk(u_sd.peek(50) == 32'h1122_CCDD,
        $sformatf("byte-enabled write: got %08x expected 1122ccdd", u_sd.peek(50)));

    // =========================================================================
    $display("--- P7: shared_data_mem is dual ported --------------------------");
    // =========================================================================
    //  A write and a read must proceed in the same cycle on different servers.
    sd_wr_addr [2*AddrW +: AddrW] = 32'd240;    // word 60
    sd_wr_wdata[2*DataW +: DataW] = 32'hFEED_BEEF;
    sd_wr_be   [2*WB    +: WB]    = 4'b1111;
    sd_rd_addr [3*AddrW +: AddrW] = 32'd40;     // word 10
    sd_rd_line[3] = 1'b0;
    sd_wr_req[2] = 1'b1;
    sd_rd_req[3] = 1'b1;
    @(posedge clk); #1;
    chk(sd_wr_gnt_q[2] && sd_rd_gnt_q[3],
        "a read and a write were granted in the same cycle");
    sd_wr_req[2] = 1'b0;
    sd_rd_req[3] = 1'b0;
    got_cnt = 0;
    while (!sd_rd_rvalid[3] && got_cnt < 20) begin
      @(posedge clk); #1; got_cnt = got_cnt + 1;
    end
    chk(sd_rd_rdata[3*LineBits +: DataW] == (32'hD000_0000 + 10),
        "the concurrent read returned the right word");
    chk(u_sd.peek(60) == 32'hFEED_BEEF, "the concurrent write landed");

    // =========================================================================
    $display("--- P8: soc_ctrl, NUM_PES and the cycle counter -----------------");
    // =========================================================================
    ct_addr[0*AddrW +: AddrW] = 32'h8000_0010;  // NUM_PES
    ct_we[0]  = 1'b0;
    ct_req[0] = 1'b1;
    @(posedge clk); #1;
    ct_req[0] = 1'b0;
    got_cnt = 0;
    while (!ct_rvalid[0] && got_cnt < 10) begin
      @(posedge clk); #1; got_cnt = got_cnt + 1;
    end
    chk(ct_rdata[0*DataW +: DataW] == NP,
        $sformatf("NUM_PES = %0d expected %0d", ct_rdata[0*DataW +: DataW], NP));

    cyc_a = ct_cycle;
    repeat (10) @(posedge clk);
    #1;
    cyc_b = ct_cycle;
    chk(cyc_b == cyc_a + 10,
        $sformatf("cycle counter advanced by 10: %0d -> %0d", cyc_a, cyc_b));

    // =========================================================================
    $display("--- P9: soc_ctrl, the hardware barrier --------------------------");
    // =========================================================================
    //  All four PEs arrive. The generation must advance exactly once, and only
    //  after the last arrival.
    ct_addr[0*AddrW +: AddrW] = 32'h8000_000C;
    ct_we[0] = 1'b0; ct_req[0] = 1'b1;
    @(posedge clk); #1; ct_req[0] = 1'b0;
    got_cnt = 0;
    while (!ct_rvalid[0] && got_cnt < 10) begin @(posedge clk); #1; got_cnt = got_cnt + 1; end
    gen_before = ct_rdata[0*DataW +: DataW];

    // three of the four arrive
    for (p = 0; p < NP; p = p + 1) begin
      ct_addr[p*AddrW +: AddrW] = 32'h8000_000C;
      ct_wdata[p*DataW +: DataW] = 32'd1;
    end
    ct_we  = '1;
    ct_req = 4'b0111;
    got_cnt = 0;
    while (ct_req != 0 && got_cnt < 20) begin
      @(posedge clk); #1;
      ct_req = ct_req & ~ct_gnt_q;
      got_cnt = got_cnt + 1;
    end
    ct_we = '0;
    repeat (3) @(posedge clk); #1;

    // read the generation back -- it must not have moved yet
    ct_addr[0*AddrW +: AddrW] = 32'h8000_000C;
    ct_req[0] = 1'b1;
    @(posedge clk); #1; ct_req[0] = 1'b0;
    got_cnt = 0;
    while (!ct_rvalid[0] && got_cnt < 10) begin @(posedge clk); #1; got_cnt = got_cnt + 1; end
    chk(ct_rdata[0*DataW +: DataW] == gen_before,
        "barrier holds while one PE has not arrived");

    // the fourth arrives
    ct_wdata[3*DataW +: DataW] = 32'd1;
    ct_addr [3*AddrW +: AddrW] = 32'h8000_000C;
    ct_we[3] = 1'b1; ct_req[3] = 1'b1;
    got_cnt = 0;
    while (ct_req[3] && got_cnt < 20) begin
      @(posedge clk); #1;
      ct_req = ct_req & ~ct_gnt_q;
      got_cnt = got_cnt + 1;
    end
    ct_we = '0;
    repeat (3) @(posedge clk); #1;

    ct_addr[0*AddrW +: AddrW] = 32'h8000_000C;
    ct_req[0] = 1'b1;
    @(posedge clk); #1; ct_req[0] = 1'b0;
    got_cnt = 0;
    while (!ct_rvalid[0] && got_cnt < 10) begin @(posedge clk); #1; got_cnt = got_cnt + 1; end
    gen_after = ct_rdata[0*DataW +: DataW];
    chk(gen_after == gen_before + 1,
        $sformatf("barrier released once: %0d -> %0d", gen_before, gen_after));

    // =========================================================================
    $display("--- P10: soc_ctrl, tohost ---------------------------------------");
    // =========================================================================
    ct_addr [2*AddrW +: AddrW] = 32'h8000_0000;
    ct_wdata[2*DataW +: DataW] = 32'd1;
    ct_we[2] = 1'b1; ct_req[2] = 1'b1;
    got_cnt = 0;
    while (ct_req[2] && got_cnt < 20) begin
      @(posedge clk); #1;
      ct_req = ct_req & ~ct_gnt_q;
      got_cnt = got_cnt + 1;
    end
    ct_we = '0;
    repeat (2) @(posedge clk); #1;
    chk(ct_done[2], "tohost marked PE2 finished");
    chk(ct_exit[2*DataW +: DataW] == 32'd1, "tohost latched PE2's exit code");
    chk(!ct_done[1], "tohost did not mark an innocent PE finished");

    // =========================================================================
    $display("--- P11: dcu_bypass, the non-coherent data path -----------------");
    // =========================================================================
    //  A read must fetch straight from memory, and a write must land there.
    bp_addr  = 32'd80;               // word 20
    bp_we    = 1'b0;
    bp_be    = 4'b1111;
    bp_req   = 1'b1;
    @(posedge clk); #1;
    bp_req = 1'b0;
    got_cnt = 0;
    while (!bp_rvalid && got_cnt < 30) begin @(posedge clk); #1; got_cnt = got_cnt + 1; end
    chk(bp_rvalid, "bypass read responded");
    chk(bp_rdata == (32'hB000_0000 + 20),
        $sformatf("bypass read = %08x expected %08x", bp_rdata, 32'hB000_0000 + 20));

    bp_addr  = 32'd84;               // word 21
    bp_we    = 1'b1;
    bp_wdata = 32'h5A5A_1234;
    bp_req   = 1'b1;
    @(posedge clk); #1;
    bp_req = 1'b0;
    got_cnt = 0;
    while (!bp_rvalid && got_cnt < 30) begin @(posedge clk); #1; got_cnt = got_cnt + 1; end
    chk(bp_rvalid, "bypass write acknowledged");
    @(posedge clk); #1;
    chk(u_bpmem.peek(21) == 32'h5A5A_1234,
        $sformatf("bypass write landed: got %08x", u_bpmem.peek(21)));

    // read it back through the bypass
    bp_addr = 32'd84;
    bp_we   = 1'b0;
    bp_req  = 1'b1;
    @(posedge clk); #1;
    bp_req = 1'b0;
    got_cnt = 0;
    while (!bp_rvalid && got_cnt < 30) begin @(posedge clk); #1; got_cnt = got_cnt + 1; end
    chk(bp_rdata == 32'h5A5A_1234, "bypass read back its own write");

    // Every access through the baseline is a miss, by construction: that is
    // what makes the Fig. 7 comparison meaningful.
    chk(bp_rd_hit == 0 && bp_wr_hit == 0, "the baseline never reports a hit");
    chk(bp_rd_miss == 2, $sformatf("baseline counted 2 read misses, got %0d", bp_rd_miss));
    chk(bp_wr_miss == 1, $sformatf("baseline counted 1 write miss, got %0d", bp_wr_miss));

    // =========================================================================
    $display("\n------------------------------------------------------------------");
    if (errors == 0) $display(" tb_soc_mem PASSED  (%0d checks)\n", checks);
    else             $display(" tb_soc_mem FAILED  (%0d errors / %0d checks)\n",
                              errors, checks);
    $finish;
  end

  initial begin
    #500us;
    $display("*** tb_soc_mem TIMEOUT ***");
    $finish;
  end

endmodule
