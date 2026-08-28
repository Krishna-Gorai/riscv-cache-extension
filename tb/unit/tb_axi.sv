// =============================================================================
//  tb_axi.sv -- unit tests for the AXI4 fabric added in M5b.
//
//  Exercises the crossbar together with the adapters and slaves that sit on it,
//  with no PEs involved, so a fabric problem is found here rather than inside a
//  four-core SoC simulation:
//
//    axi_xbar           address decode, per-slave arbitration, ID routing,
//                       the W-channel lock, and the decode-error responder
//    axi_sram           single reads, INCR burst reads, WSTRB writes
//    axi_ctrl           register reads and the hardware barrier
//    axi_master_simple  single-beat read and write
//    axi_master_dcu     line fill as one burst, write-through as one beat
//
//  Master 3 is wired straight to the crossbar rather than through an adapter,
//  so the decode-error path can be driven with an address no slave claims.
//
//  Written without procedural `automatic` or `break` so it runs on Icarus.
// =============================================================================
`timescale 1ns/1ps

module tb_axi;

  localparam int unsigned NM    = 4;
  localparam int unsigned NS    = 3;
  localparam int unsigned AddrW = 32;
  localparam int unsigned DataW = 32;
  localparam int unsigned StrbW = DataW/8;
  localparam int unsigned LenW  = 8;
  localparam int unsigned IdW   = 2;
  localparam int unsigned LB    = 16;                 // line bytes
  localparam int unsigned WPL   = LB/(DataW/8);
  localparam int unsigned LineBits = LB*8;

  logic clk   = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  integer errors = 0;
  integer checks = 0;
  integer i, w, guard;

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
  //  Crossbar wiring
  // ===========================================================================
  logic [NM-1:0]       m_arvalid, m_arready, m_rvalid, m_rready, m_rlast;
  logic [NM*AddrW-1:0] m_araddr;
  logic [NM*LenW-1:0]  m_arlen;
  logic [NM*DataW-1:0] m_rdata;
  logic [NM*2-1:0]     m_rresp;

  logic [NM-1:0]       m_awvalid, m_awready, m_wvalid, m_wready, m_wlast;
  logic [NM*AddrW-1:0] m_awaddr;
  logic [NM*LenW-1:0]  m_awlen;
  logic [NM*DataW-1:0] m_wdata;
  logic [NM*StrbW-1:0] m_wstrb;
  logic [NM-1:0]       m_bvalid, m_bready;
  logic [NM*2-1:0]     m_bresp;

  logic [NS-1:0]       s_arvalid, s_arready, s_rvalid, s_rready, s_rlast;
  logic [NS*AddrW-1:0] s_araddr;
  logic [NS*LenW-1:0]  s_arlen;
  logic [NS*IdW-1:0]   s_arid, s_rid;
  logic [NS*DataW-1:0] s_rdata;
  logic [NS*2-1:0]     s_rresp;

  logic [NS-1:0]       s_awvalid, s_awready, s_wvalid, s_wready, s_wlast;
  logic [NS*AddrW-1:0] s_awaddr;
  logic [NS*LenW-1:0]  s_awlen;
  logic [NS*IdW-1:0]   s_awid, s_bid;
  logic [NS*DataW-1:0] s_wdata;
  logic [NS*StrbW-1:0] s_wstrb;
  logic [NS-1:0]       s_bvalid, s_bready;
  logic [NS*2-1:0]     s_bresp;

  axi_xbar #(
    .NumMasters (NM), .NumSlaves (NS), .AddrW (AddrW), .DataW (DataW),
    .LenW (LenW), .MaxOutstanding (4),
    .SlaveBase ({32'h8000_0000, 32'h2000_0000, 32'h1000_0000}),
    .SlaveMask ({32'hF000_0000, 32'hF000_0000, 32'hF000_0000})
  ) u_xbar (
    .clk_i (clk), .rst_ni (rst_n),
    .m_arvalid_i (m_arvalid), .m_arready_o (m_arready),
    .m_araddr_i (m_araddr), .m_arlen_i (m_arlen),
    .m_rvalid_o (m_rvalid), .m_rready_i (m_rready), .m_rdata_o (m_rdata),
    .m_rresp_o (m_rresp), .m_rlast_o (m_rlast),
    .m_awvalid_i (m_awvalid), .m_awready_o (m_awready),
    .m_awaddr_i (m_awaddr), .m_awlen_i (m_awlen),
    .m_wvalid_i (m_wvalid), .m_wready_o (m_wready), .m_wdata_i (m_wdata),
    .m_wstrb_i (m_wstrb), .m_wlast_i (m_wlast),
    .m_bvalid_o (m_bvalid), .m_bready_i (m_bready), .m_bresp_o (m_bresp),

    .s_arvalid_o (s_arvalid), .s_arready_i (s_arready),
    .s_araddr_o (s_araddr), .s_arlen_o (s_arlen), .s_arid_o (s_arid),
    .s_rvalid_i (s_rvalid), .s_rready_o (s_rready), .s_rdata_i (s_rdata),
    .s_rresp_i (s_rresp), .s_rlast_i (s_rlast), .s_rid_i (s_rid),
    .s_awvalid_o (s_awvalid), .s_awready_i (s_awready),
    .s_awaddr_o (s_awaddr), .s_awlen_o (s_awlen), .s_awid_o (s_awid),
    .s_wvalid_o (s_wvalid), .s_wready_i (s_wready), .s_wdata_o (s_wdata),
    .s_wstrb_o (s_wstrb), .s_wlast_o (s_wlast),
    .s_bvalid_i (s_bvalid), .s_bready_o (s_bready), .s_bresp_i (s_bresp),
    .s_bid_i (s_bid)
  );

  // ===========================================================================
  //  Slaves
  // ===========================================================================
  axi_sram #(
    .AddrW (AddrW), .DataW (DataW), .IdW (IdW), .LenW (LenW),
    .SizeBytes (4096), .AccessLat (2)
  ) u_sdmem (
    .clk_i (clk), .rst_ni (rst_n),
    .arvalid_i (s_arvalid[0]), .arready_o (s_arready[0]),
    .araddr_i (s_araddr[0*AddrW +: AddrW]), .arlen_i (s_arlen[0*LenW +: LenW]),
    .arid_i (s_arid[0*IdW +: IdW]),
    .rvalid_o (s_rvalid[0]), .rready_i (s_rready[0]),
    .rdata_o (s_rdata[0*DataW +: DataW]), .rresp_o (s_rresp[0*2 +: 2]),
    .rlast_o (s_rlast[0]), .rid_o (s_rid[0*IdW +: IdW]),
    .awvalid_i (s_awvalid[0]), .awready_o (s_awready[0]),
    .awaddr_i (s_awaddr[0*AddrW +: AddrW]), .awlen_i (s_awlen[0*LenW +: LenW]),
    .awid_i (s_awid[0*IdW +: IdW]),
    .wvalid_i (s_wvalid[0]), .wready_o (s_wready[0]),
    .wdata_i (s_wdata[0*DataW +: DataW]), .wstrb_i (s_wstrb[0*StrbW +: StrbW]),
    .wlast_i (s_wlast[0]),
    .bvalid_o (s_bvalid[0]), .bready_i (s_bready[0]),
    .bresp_o (s_bresp[0*2 +: 2]), .bid_o (s_bid[0*IdW +: IdW])
  );

  axi_sram #(
    .AddrW (AddrW), .DataW (DataW), .IdW (IdW), .LenW (LenW),
    .SizeBytes (4096), .AccessLat (2)
  ) u_simem (
    .clk_i (clk), .rst_ni (rst_n),
    .arvalid_i (s_arvalid[1]), .arready_o (s_arready[1]),
    .araddr_i (s_araddr[1*AddrW +: AddrW]), .arlen_i (s_arlen[1*LenW +: LenW]),
    .arid_i (s_arid[1*IdW +: IdW]),
    .rvalid_o (s_rvalid[1]), .rready_i (s_rready[1]),
    .rdata_o (s_rdata[1*DataW +: DataW]), .rresp_o (s_rresp[1*2 +: 2]),
    .rlast_o (s_rlast[1]), .rid_o (s_rid[1*IdW +: IdW]),
    .awvalid_i (s_awvalid[1]), .awready_o (s_awready[1]),
    .awaddr_i (s_awaddr[1*AddrW +: AddrW]), .awlen_i (s_awlen[1*LenW +: LenW]),
    .awid_i (s_awid[1*IdW +: IdW]),
    .wvalid_i (s_wvalid[1]), .wready_o (s_wready[1]),
    .wdata_i (s_wdata[1*DataW +: DataW]), .wstrb_i (s_wstrb[1*StrbW +: StrbW]),
    .wlast_i (s_wlast[1]),
    .bvalid_o (s_bvalid[1]), .bready_i (s_bready[1]),
    .bresp_o (s_bresp[1*2 +: 2]), .bid_o (s_bid[1*IdW +: IdW])
  );

  logic [0:0]  ct_done;
  logic [31:0] ct_exit;
  logic        ct_pcv;
  logic [7:0]  ct_pcd;
  logic [31:0] ct_cycle;

  axi_ctrl #(
    .NumPes (1), .AddrW (AddrW), .DataW (DataW),
    .IdW (IdW), .LenW (LenW), .IdBase (2)
  ) u_ctrl (
    .clk_i (clk), .rst_ni (rst_n),
    .arvalid_i (s_arvalid[2]), .arready_o (s_arready[2]),
    .araddr_i (s_araddr[2*AddrW +: AddrW]), .arlen_i (s_arlen[2*LenW +: LenW]),
    .arid_i (s_arid[2*IdW +: IdW]),
    .rvalid_o (s_rvalid[2]), .rready_i (s_rready[2]),
    .rdata_o (s_rdata[2*DataW +: DataW]), .rresp_o (s_rresp[2*2 +: 2]),
    .rlast_o (s_rlast[2]), .rid_o (s_rid[2*IdW +: IdW]),
    .awvalid_i (s_awvalid[2]), .awready_o (s_awready[2]),
    .awaddr_i (s_awaddr[2*AddrW +: AddrW]), .awlen_i (s_awlen[2*LenW +: LenW]),
    .awid_i (s_awid[2*IdW +: IdW]),
    .wvalid_i (s_wvalid[2]), .wready_o (s_wready[2]),
    .wdata_i (s_wdata[2*DataW +: DataW]), .wstrb_i (s_wstrb[2*StrbW +: StrbW]),
    .wlast_i (s_wlast[2]),
    .bvalid_o (s_bvalid[2]), .bready_i (s_bready[2]),
    .bresp_o (s_bresp[2*2 +: 2]), .bid_o (s_bid[2*IdW +: IdW]),
    .done_o (ct_done), .exit_code_o (ct_exit),
    .putchar_valid_o (ct_pcv), .putchar_data_o (ct_pcd), .cycle_o (ct_cycle)
  );

  // ===========================================================================
  //  Master 0 -- single-beat reads and writes
  // ===========================================================================
  logic             m0_req, m0_gnt, m0_we, m0_rvalid;
  logic [AddrW-1:0] m0_addr;
  logic [StrbW-1:0] m0_be;
  logic [DataW-1:0] m0_wdata, m0_rdata;

  axi_master_simple #(.AddrW (AddrW), .DataW (DataW), .LenW (LenW)) u_m0 (
    .clk_i (clk), .rst_ni (rst_n),
    .req_i (m0_req), .gnt_o (m0_gnt), .addr_i (m0_addr), .we_i (m0_we),
    .be_i (m0_be), .wdata_i (m0_wdata), .rvalid_o (m0_rvalid), .rdata_o (m0_rdata),
    .arvalid_o (m_arvalid[0]), .arready_i (m_arready[0]),
    .araddr_o (m_araddr[0*AddrW +: AddrW]), .arlen_o (m_arlen[0*LenW +: LenW]),
    .rvalid_i (m_rvalid[0]), .rready_o (m_rready[0]),
    .rdata_i (m_rdata[0*DataW +: DataW]), .rresp_i (m_rresp[0*2 +: 2]),
    .rlast_i (m_rlast[0]),
    .awvalid_o (m_awvalid[0]), .awready_i (m_awready[0]),
    .awaddr_o (m_awaddr[0*AddrW +: AddrW]), .awlen_o (m_awlen[0*LenW +: LenW]),
    .wvalid_o (m_wvalid[0]), .wready_i (m_wready[0]),
    .wdata_o (m_wdata[0*DataW +: DataW]), .wstrb_o (m_wstrb[0*StrbW +: StrbW]),
    .wlast_o (m_wlast[0]),
    .bvalid_i (m_bvalid[0]), .bready_o (m_bready[0]), .bresp_i (m_bresp[0*2 +: 2])
  );

  // ===========================================================================
  //  Master 1 -- the cache's memory port
  // ===========================================================================
  logic                m1_rd_req, m1_rd_line, m1_rd_gnt, m1_rd_rvalid;
  logic [AddrW-1:0]    m1_rd_addr;
  logic [LineBits-1:0] m1_rd_rdata;
  logic                m1_wr_req, m1_wr_gnt;
  logic [AddrW-1:0]    m1_wr_addr;
  logic [StrbW-1:0]    m1_wr_be;
  logic [DataW-1:0]    m1_wr_data;

  axi_master_dcu #(
    .AddrW (AddrW), .DataW (DataW), .LineBytes (LB), .LenW (LenW)
  ) u_m1 (
    .clk_i (clk), .rst_ni (rst_n),
    .rd_req_i (m1_rd_req), .rd_addr_i (m1_rd_addr), .rd_line_i (m1_rd_line),
    .rd_gnt_o (m1_rd_gnt), .rd_rvalid_o (m1_rd_rvalid), .rd_rdata_o (m1_rd_rdata),
    .wr_req_i (m1_wr_req), .wr_addr_i (m1_wr_addr), .wr_be_i (m1_wr_be),
    .wr_wdata_i (m1_wr_data), .wr_gnt_o (m1_wr_gnt),
    .arvalid_o (m_arvalid[1]), .arready_i (m_arready[1]),
    .araddr_o (m_araddr[1*AddrW +: AddrW]), .arlen_o (m_arlen[1*LenW +: LenW]),
    .rvalid_i (m_rvalid[1]), .rready_o (m_rready[1]),
    .rdata_i (m_rdata[1*DataW +: DataW]), .rresp_i (m_rresp[1*2 +: 2]),
    .rlast_i (m_rlast[1]),
    .awvalid_o (m_awvalid[1]), .awready_i (m_awready[1]),
    .awaddr_o (m_awaddr[1*AddrW +: AddrW]), .awlen_o (m_awlen[1*LenW +: LenW]),
    .wvalid_o (m_wvalid[1]), .wready_i (m_wready[1]),
    .wdata_o (m_wdata[1*DataW +: DataW]), .wstrb_o (m_wstrb[1*StrbW +: StrbW]),
    .wlast_o (m_wlast[1]),
    .bvalid_i (m_bvalid[1]), .bready_o (m_bready[1]), .bresp_i (m_bresp[1*2 +: 2])
  );

  // ===========================================================================
  //  Master 2 -- the control region client
  // ===========================================================================
  logic             m2_req, m2_gnt, m2_we, m2_rvalid;
  logic [AddrW-1:0] m2_addr;
  logic [DataW-1:0] m2_wdata, m2_rdata;

  axi_master_simple #(.AddrW (AddrW), .DataW (DataW), .LenW (LenW)) u_m2 (
    .clk_i (clk), .rst_ni (rst_n),
    .req_i (m2_req), .gnt_o (m2_gnt), .addr_i (m2_addr), .we_i (m2_we),
    .be_i (4'hF), .wdata_i (m2_wdata), .rvalid_o (m2_rvalid), .rdata_o (m2_rdata),
    .arvalid_o (m_arvalid[2]), .arready_i (m_arready[2]),
    .araddr_o (m_araddr[2*AddrW +: AddrW]), .arlen_o (m_arlen[2*LenW +: LenW]),
    .rvalid_i (m_rvalid[2]), .rready_o (m_rready[2]),
    .rdata_i (m_rdata[2*DataW +: DataW]), .rresp_i (m_rresp[2*2 +: 2]),
    .rlast_i (m_rlast[2]),
    .awvalid_o (m_awvalid[2]), .awready_i (m_awready[2]),
    .awaddr_o (m_awaddr[2*AddrW +: AddrW]), .awlen_o (m_awlen[2*LenW +: LenW]),
    .wvalid_o (m_wvalid[2]), .wready_i (m_wready[2]),
    .wdata_o (m_wdata[2*DataW +: DataW]), .wstrb_o (m_wstrb[2*StrbW +: StrbW]),
    .wlast_o (m_wlast[2]),
    .bvalid_i (m_bvalid[2]), .bready_o (m_bready[2]), .bresp_i (m_bresp[2*2 +: 2])
  );

  // ===========================================================================
  //  Master 3 -- raw, for the decode-error path
  // ===========================================================================
  //  Driven through continuous assignments, because bits 0..2 of each vector
  //  are driven by the adapters' ports and a vector cannot mix continuous and
  //  procedural drivers.
  logic             m3_arvalid, m3_awvalid, m3_wvalid;
  logic [AddrW-1:0] m3_araddr, m3_awaddr;

  assign m_arlen[3*LenW +: LenW]   = '0;
  assign m_awlen[3*LenW +: LenW]   = '0;
  assign m_wstrb[3*StrbW +: StrbW] = 4'hF;
  assign m_wdata[3*DataW +: DataW] = 32'hDEAD_BEEF;
  assign m_wlast[3]                = 1'b1;
  assign m_rready[3]               = 1'b1;
  assign m_bready[3]               = 1'b1;
  assign m_arvalid[3]              = m3_arvalid;
  assign m_awvalid[3]              = m3_awvalid;
  assign m_wvalid[3]               = m3_wvalid;
  assign m_araddr[3*AddrW +: AddrW] = m3_araddr;
  assign m_awaddr[3*AddrW +: AddrW] = m3_awaddr;

  //  The crossbar takes a request ON the clock edge and drops READY at that
  //  same edge, so a poll that samples after the edge can never catch VALID
  //  and READY high together. Capture master 3's handshakes in registers and
  //  let the stimulus watch those -- the same trick masters 0..2 use for their
  //  grants.
  logic       m3_clr;
  logic       m3_ar_hs_q, m3_r_hs_q, m3_rlast_q;
  logic [1:0] m3_rresp_q;
  logic       m3_aw_hs_q, m3_w_hs_q, m3_b_hs_q;
  logic [1:0] m3_bresp_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m3_ar_hs_q <= 1'b0; m3_r_hs_q <= 1'b0;
      m3_rlast_q <= 1'b0; m3_rresp_q <= 2'b00;
      m3_aw_hs_q <= 1'b0; m3_w_hs_q <= 1'b0;
      m3_b_hs_q  <= 1'b0; m3_bresp_q <= 2'b00;
    end else if (m3_clr) begin
      m3_ar_hs_q <= 1'b0; m3_r_hs_q <= 1'b0;
      m3_aw_hs_q <= 1'b0; m3_w_hs_q <= 1'b0; m3_b_hs_q <= 1'b0;
    end else begin
      if (m_arvalid[3] && m_arready[3]) m3_ar_hs_q <= 1'b1;
      if (m_rvalid[3] && m_rready[3]) begin
        m3_r_hs_q  <= 1'b1;
        m3_rresp_q <= m_rresp[3*2 +: 2];
        m3_rlast_q <= m_rlast[3];
      end
      if (m_awvalid[3] && m_awready[3]) m3_aw_hs_q <= 1'b1;
      if (m_wvalid[3] && m_wready[3])   m3_w_hs_q  <= 1'b1;
      if (m_bvalid[3] && m_bready[3]) begin
        m3_b_hs_q  <= 1'b1;
        m3_bresp_q <= m_bresp[3*2 +: 2];
      end
    end
  end

  // ===========================================================================
  //  Stimulus
  //
  //  The grants are combinational on req, and the adapter consumes the request
  //  on the clock edge -- so the stimulus watches a registered copy, which is
  //  what the grant actually was at the edge that took it.
  // ===========================================================================
  logic m0_gnt_q, m1_rd_gnt_q, m1_wr_gnt_q, m2_gnt_q;
  always_ff @(posedge clk) begin
    m0_gnt_q    <= m0_gnt;
    m1_rd_gnt_q <= m1_rd_gnt;
    m1_wr_gnt_q <= m1_wr_gnt;
    m2_gnt_q    <= m2_gnt;
  end

  integer waiting;

  task do_m0(input logic we, input logic [AddrW-1:0] a, input logic [DataW-1:0] d);
    begin
      m0_addr = a; m0_we = we; m0_wdata = d; m0_be = 4'hF; m0_req = 1'b1;
      waiting = 1; guard = 0;
      while (waiting != 0 && guard < 200) begin
        @(posedge clk); #1;
        if (m0_gnt_q) begin m0_req = 1'b0; waiting = 0; end
        guard = guard + 1;
      end
      guard = 0;
      while (!m0_rvalid && guard < 400) begin @(posedge clk); #1; guard = guard + 1; end
    end
  endtask

  task do_m2(input logic we, input logic [AddrW-1:0] a, input logic [DataW-1:0] d);
    begin
      m2_addr = a; m2_we = we; m2_wdata = d; m2_req = 1'b1;
      waiting = 1; guard = 0;
      while (waiting != 0 && guard < 200) begin
        @(posedge clk); #1;
        if (m2_gnt_q) begin m2_req = 1'b0; waiting = 0; end
        guard = guard + 1;
      end
      guard = 0;
      while (!m2_rvalid && guard < 400) begin @(posedge clk); #1; guard = guard + 1; end
    end
  endtask

  task do_m1_read(input logic line, input logic [AddrW-1:0] a);
    begin
      m1_rd_addr = a; m1_rd_line = line; m1_rd_req = 1'b1;
      waiting = 1; guard = 0;
      while (waiting != 0 && guard < 200) begin
        @(posedge clk); #1;
        if (m1_rd_gnt_q) begin m1_rd_req = 1'b0; waiting = 0; end
        guard = guard + 1;
      end
      guard = 0;
      while (!m1_rd_rvalid && guard < 400) begin @(posedge clk); #1; guard = guard + 1; end
    end
  endtask

  task do_m1_write(input logic [AddrW-1:0] a, input logic [StrbW-1:0] be,
                   input logic [DataW-1:0] d);
    begin
      m1_wr_addr = a; m1_wr_be = be; m1_wr_data = d; m1_wr_req = 1'b1;
      waiting = 1; guard = 0;
      while (waiting != 0 && guard < 200) begin
        @(posedge clk); #1;
        if (m1_wr_gnt_q) begin m1_wr_req = 1'b0; waiting = 0; end
        guard = guard + 1;
      end
      // let the write drain all the way to the array
      repeat (12) @(posedge clk);
      #1;
    end
  endtask

  initial begin
    m0_req = 0; m0_we = 0; m0_addr = 0; m0_be = 0; m0_wdata = 0;
    m1_rd_req = 0; m1_rd_line = 0; m1_rd_addr = 0;
    m1_wr_req = 0; m1_wr_addr = 0; m1_wr_be = 0; m1_wr_data = 0;
    m2_req = 0; m2_we = 0; m2_addr = 0; m2_wdata = 0;
    m3_arvalid = 0; m3_awvalid = 0; m3_wvalid = 0; m3_clr = 0;
    m3_araddr = 0; m3_awaddr = 0;

    for (i = 0; i < 1024; i = i + 1) begin
      u_sdmem.mem[i] = 32'hD000_0000 + i;
      u_simem.mem[i] = 32'hA000_0000 + i;
    end

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (3) @(posedge clk);

    // =========================================================================
    $display("\n--- A1: single read through the crossbar ------------------------");
    // =========================================================================
    do_m0(1'b0, 32'h2000_0000 + 32'd40, 32'd0);          // simem word 10
    chk(m0_rvalid, "m0 single read completed");
    chk(m0_rdata == (32'hA000_0000 + 10),
        $sformatf("m0 read simem[10] = %08x", m0_rdata));

    do_m0(1'b0, 32'h1000_0000 + 32'd20, 32'd0);          // sdmem word 5
    chk(m0_rdata == (32'hD000_0000 + 5),
        $sformatf("m0 read sdmem[5] = %08x", m0_rdata));

    // =========================================================================
    $display("--- A2: single write, then read it back -------------------------");
    // =========================================================================
    do_m0(1'b1, 32'h1000_0000 + 32'd64, 32'h1234_5678);  // sdmem word 16
    repeat (5) @(posedge clk); #1;
    chk(u_sdmem.peek(16) == 32'h1234_5678,
        $sformatf("m0 write landed: %08x", u_sdmem.peek(16)));
    do_m0(1'b0, 32'h1000_0000 + 32'd64, 32'd0);
    chk(m0_rdata == 32'h1234_5678, "m0 read back its own write");

    // =========================================================================
    $display("--- A3: line fill as one INCR burst -----------------------------");
    // =========================================================================
    do_m1_read(1'b1, 32'h1000_0000 + 32'd128);           // line at word 32
    chk(m1_rd_rvalid, "m1 burst read completed");
    for (w = 0; w < WPL; w = w + 1) begin
      chk(m1_rd_rdata[w*DataW +: DataW] == (32'hD000_0000 + 32 + w),
          $sformatf("burst lane %0d = %08x expected %08x", w,
                    m1_rd_rdata[w*DataW +: DataW], 32'hD000_0000 + 32 + w));
    end

    // a single-word read on the same master must still work
    do_m1_read(1'b0, 32'h1000_0000 + 32'd200);           // word 50
    chk(m1_rd_rdata[DataW-1:0] == (32'hD000_0000 + 50),
        $sformatf("m1 word read = %08x", m1_rd_rdata[DataW-1:0]));

    // =========================================================================
    $display("--- A4: write-through with byte strobes -------------------------");
    // =========================================================================
    do_m1_write(32'h1000_0000 + 32'd240, 4'b1111, 32'hAABB_CCDD);   // word 60
    chk(u_sdmem.peek(60) == 32'hAABB_CCDD,
        $sformatf("full write = %08x", u_sdmem.peek(60)));

    do_m1_write(32'h1000_0000 + 32'd240, 4'b0011, 32'h1111_2222);
    chk(u_sdmem.peek(60) == 32'hAABB_2222,
        $sformatf("strobed write = %08x expected aabb2222", u_sdmem.peek(60)));

    // =========================================================================
    $display("--- A5: the control region over AXI -----------------------------");
    // =========================================================================
    do_m2(1'b0, 32'h8000_0010, 32'd0);                   // NUM_PES
    chk(m2_rdata == 32'd1, $sformatf("NUM_PES = %0d", m2_rdata));

    do_m2(1'b0, 32'h8000_000C, 32'd0);                   // BARRIER generation
    chk(m2_rdata == 32'd0, "barrier generation starts at 0");

    do_m2(1'b1, 32'h8000_000C, 32'd1);                   // the only PE arrives
    do_m2(1'b0, 32'h8000_000C, 32'd0);
    chk(m2_rdata == 32'd1,
        $sformatf("barrier released with one PE: gen = %0d", m2_rdata));

    do_m2(1'b1, 32'h8000_0000, 32'd7);                   // TOHOST
    repeat (3) @(posedge clk); #1;
    chk(ct_done[0], "tohost marked the PE finished");
    chk(ct_exit == 32'd7, $sformatf("exit code latched = %0d", ct_exit));

    // =========================================================================
    $display("--- A6: two masters contending for one slave --------------------");
    // =========================================================================
    //  m0 and m1 both target the shared data memory at the same time. Both
    //  must complete, and each must get its own data back.
    fork
      begin
        do_m0(1'b0, 32'h1000_0000 + 32'd4, 32'd0);       // word 1
      end
      begin
        do_m1_read(1'b1, 32'h1000_0000 + 32'd320);       // line at word 80
      end
    join
    chk(m0_rdata == (32'hD000_0000 + 1),
        $sformatf("contended m0 read = %08x", m0_rdata));
    for (w = 0; w < WPL; w = w + 1) begin
      chk(m1_rd_rdata[w*DataW +: DataW] == (32'hD000_0000 + 80 + w),
          $sformatf("contended burst lane %0d = %08x", w,
                    m1_rd_rdata[w*DataW +: DataW]));
    end

    // =========================================================================
    $display("--- A7: an address no slave claims ------------------------------");
    // =========================================================================
    //  Driven straight at the crossbar: it must answer with DECERR rather than
    //  leave the master hanging. The handshakes are watched through the
    //  registered capture above: the crossbar consumes the request on the
    //  clock edge and drops READY at that same edge, so polling VALID && READY
    //  after the edge never sees the window. VALID is also dropped as soon as
    //  the capture reports the handshake -- holding it longer would be an AXI
    //  violation and would inject a second, spurious decode-error access.
    m3_clr = 1'b1; @(posedge clk); #1; m3_clr = 1'b0;

    m3_araddr  = 32'h5000_0000;
    m3_arvalid = 1'b1;
    guard = 0;
    while (!m3_ar_hs_q && guard < 50) begin @(posedge clk); #1; guard = guard + 1; end
    m3_arvalid = 1'b0;
    chk(guard < 50, "the crossbar accepted a mis-decoded read");
    guard = 0;
    while (!m3_r_hs_q && guard < 50) begin @(posedge clk); #1; guard = guard + 1; end
    chk(m3_r_hs_q, "a mis-decoded read got a response");
    chk(m3_rresp_q == 2'b11, "the response was DECERR");
    chk(m3_rlast_q, "the DECERR response was the last beat");

    m3_clr = 1'b1; @(posedge clk); #1; m3_clr = 1'b0;

    m3_awaddr  = 32'h5000_0000;
    m3_awvalid = 1'b1;
    guard = 0;
    while (!m3_aw_hs_q && guard < 50) begin @(posedge clk); #1; guard = guard + 1; end
    m3_awvalid = 1'b0;
    chk(guard < 50, "the crossbar accepted a mis-decoded write");
    m3_wvalid = 1'b1;
    guard = 0;
    while (!m3_w_hs_q && guard < 50) begin @(posedge clk); #1; guard = guard + 1; end
    m3_wvalid = 1'b0;
    chk(guard < 50, "the mis-decoded write data phase was swallowed");
    guard = 0;
    while (!m3_b_hs_q && guard < 50) begin @(posedge clk); #1; guard = guard + 1; end
    chk(m3_b_hs_q, "a mis-decoded write got a B response");
    chk(m3_bresp_q == 2'b11, "the write response was DECERR");

    // the fabric must still work afterwards
    @(posedge clk); #1;
    do_m0(1'b0, 32'h2000_0000 + 32'd8, 32'd0);
    chk(m0_rdata == (32'hA000_0000 + 2),
        "the fabric still works after a decode error");

    $display("\n------------------------------------------------------------------");
    if (errors == 0) $display(" tb_axi PASSED  (%0d checks)\n", checks);
    else             $display(" tb_axi FAILED  (%0d errors / %0d checks)\n",
                              errors, checks);
    $finish;
  end

  initial begin
    #2ms;
    $display("*** tb_axi TIMEOUT ***");
    $finish;
  end

endmodule
