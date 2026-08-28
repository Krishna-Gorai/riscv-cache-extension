// =============================================================================
//  soc_top.sv -- the multi-core RISC-V SoC of Fig. 1.
//
//  NumPes Processing Elements around an AXI4 crossbar, a shared scratchpad
//  instruction memory that doubles as the boot memory, a shared data memory,
//  and -- selected by the Coherent parameter -- either the data-cache
//  sub-system of the paper or no data cache at all.
//
//  Section IV-A builds exactly these two systems and compares them:
//
//    Coherent = 1   a private DCU per PE, the snoopy bus, and the coherent
//                   shared data memory. This is the architecture of Fig. 1.
//    Coherent = 0   the non-coherent baseline: the same PEs with the DCU
//                   removed, going word by word to a shared scratchpad data
//                   memory. This is what Figs. 5 and 6 measure against.
//
//  Nothing outside the g_dcache generate block changes between the two, which
//  is the "seamless" claim made structural: the cores, the bridges, the ITCMs,
//  the interconnect and the software are all identical.
//
//  AXI master map. Masters are grouped by function rather than interleaved per
//  PE, so that the control region can recover which PE is talking to it from
//  the AXI ID by simple subtraction (see axi_ctrl's IdBase):
//
//    id  0            .. NumPes-1     Instruction-Bridge, fetch
//    id  NumPes       .. 2*NumPes-1   DCU memory port, line fills + write-through
//    id  2*NumPes     .. 3*NumPes-1   Data-Bridge external port
//
//  Slave map, by the top address nibble:
//
//    0x1  shared data memory        0x2  shared instruction memory
//    0x8  control region            0x0  local ITCM -- never leaves the PE
//
//  Boot flow, following Section III-B: every PE starts fetching from the shared
//  instruction memory, and its boot stub uses the Data-Bridge to read the code
//  image out of that memory and write it into the PE's private ITCM, then jumps
//  into the ITCM copy. After that the shared instruction memory falls idle and
//  the PEs contend only for data, which is what the evaluation is about.
// =============================================================================
module soc_top
  import cache_pkg::*;
#(
  parameter  int unsigned NumPes     = 4,
  parameter  bit          Coherent   = 1'b1,

  parameter  int unsigned NumWays    = 2,
  parameter  int unsigned NumSets    = 64,
  parameter  int unsigned LineBytes  = 16,

  parameter  int unsigned AddrW      = 32,
  parameter  int unsigned DataW      = 32,

  parameter  int unsigned ItcmBytes  = 32768,
  parameter  int unsigned SimemBytes = 32768,
  parameter  int unsigned SdmemBytes = 262144,

  parameter  logic [31:0] BootAddr   = 32'h2000_0000,
  parameter  int unsigned MemLat     = 2,

  localparam int unsigned WordBytes  = DataW / 8,
  localparam int unsigned LineBits   = LineBytes * 8,

  localparam int unsigned NumMst     = 3 * NumPes,
  localparam int unsigned NumSlv     = 3,
  localparam int unsigned LenW       = 8,
  localparam int unsigned IdW        = (NumMst <= 1) ? 1 : $clog2(NumMst),
  localparam int unsigned StrbW      = DataW / 8
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,
  input  logic                    fetch_enable_i,

  // --- observation -----------------------------------------------------------
  output logic [NumPes-1:0]       done_o,
  output logic [NumPes*DataW-1:0] exit_code_o,
  output logic                    putchar_valid_o,
  output logic [7:0]              putchar_data_o,
  output logic [31:0]             cycle_o,
  output logic [NumPes-1:0]       core_sleep_o,

  // --- per-PE cache instrumentation -----------------------------------------
  output logic [NumPes*32-1:0]    perf_rd_hit_o,
  output logic [NumPes*32-1:0]    perf_rd_miss_o,
  output logic [NumPes*32-1:0]    perf_wr_hit_o,
  output logic [NumPes*32-1:0]    perf_wr_miss_o,
  output logic [NumPes*32-1:0]    perf_busy_o,
  output logic [NumPes*32-1:0]    perf_stall_snoop_o,
  output logic [NumPes*32-1:0]    perf_stall_s2_o,
  output logic [NumPes*32-1:0]    perf_rd_wait_o,
  output logic [NumPes*32-1:0]    perf_wr_wait_o
);

  // ---------------------------------------------------------------------------
  //  PE <-> data-cache sub-system
  // ---------------------------------------------------------------------------
  logic [NumPes-1:0]           dcu_req, dcu_gnt, dcu_we, dcu_rvalid;
  logic [NumPes*AddrW-1:0]     dcu_addr;
  logic [NumPes*WordBytes-1:0] dcu_be;
  logic [NumPes*DataW-1:0]     dcu_wdata, dcu_rdata;
  logic [NumPes*2-1:0]         dcu_amo;

  // ---------------------------------------------------------------------------
  //  Data-cache sub-system <-> its AXI master
  // ---------------------------------------------------------------------------
  logic [NumPes-1:0]           mrd_req, mrd_gnt, mrd_rvalid, mrd_line;
  logic [NumPes*AddrW-1:0]     mrd_addr;
  logic [NumPes*LineBits-1:0]  mrd_rdata;

  logic [NumPes-1:0]           mwr_req, mwr_gnt;
  logic [NumPes*AddrW-1:0]     mwr_addr;
  logic [NumPes*WordBytes-1:0] mwr_be;
  logic [NumPes*DataW-1:0]     mwr_wdata;

  // ---------------------------------------------------------------------------
  //  PE ports that leave on AXI
  // ---------------------------------------------------------------------------
  logic [NumPes-1:0]           if_req, if_gnt, if_rvalid;
  logic [NumPes*AddrW-1:0]     if_addr;
  logic [NumPes*DataW-1:0]     if_rdata;

  logic [NumPes-1:0]           ex_req, ex_gnt, ex_we, ex_rvalid;
  logic [NumPes*AddrW-1:0]     ex_addr;
  logic [NumPes*WordBytes-1:0] ex_be;
  logic [NumPes*DataW-1:0]     ex_wdata, ex_rdata;

  // ---------------------------------------------------------------------------
  //  AXI, master side
  // ---------------------------------------------------------------------------
  logic [NumMst-1:0]       m_arvalid, m_arready;
  logic [NumMst*AddrW-1:0] m_araddr;
  logic [NumMst*LenW-1:0]  m_arlen;
  logic [NumMst-1:0]       m_rvalid, m_rready, m_rlast;
  logic [NumMst*DataW-1:0] m_rdata;
  logic [NumMst*2-1:0]     m_rresp;

  logic [NumMst-1:0]       m_awvalid, m_awready;
  logic [NumMst*AddrW-1:0] m_awaddr;
  logic [NumMst*LenW-1:0]  m_awlen;
  logic [NumMst-1:0]       m_wvalid, m_wready, m_wlast;
  logic [NumMst*DataW-1:0] m_wdata;
  logic [NumMst*StrbW-1:0] m_wstrb;
  logic [NumMst-1:0]       m_bvalid, m_bready;
  logic [NumMst*2-1:0]     m_bresp;

  // ---------------------------------------------------------------------------
  //  AXI, slave side
  // ---------------------------------------------------------------------------
  logic [NumSlv-1:0]       s_arvalid, s_arready;
  logic [NumSlv*AddrW-1:0] s_araddr;
  logic [NumSlv*LenW-1:0]  s_arlen;
  logic [NumSlv*IdW-1:0]   s_arid;
  logic [NumSlv-1:0]       s_rvalid, s_rready, s_rlast;
  logic [NumSlv*DataW-1:0] s_rdata;
  logic [NumSlv*2-1:0]     s_rresp;
  logic [NumSlv*IdW-1:0]   s_rid;

  logic [NumSlv-1:0]       s_awvalid, s_awready;
  logic [NumSlv*AddrW-1:0] s_awaddr;
  logic [NumSlv*LenW-1:0]  s_awlen;
  logic [NumSlv*IdW-1:0]   s_awid;
  logic [NumSlv-1:0]       s_wvalid, s_wready, s_wlast;
  logic [NumSlv*DataW-1:0] s_wdata;
  logic [NumSlv*StrbW-1:0] s_wstrb;
  logic [NumSlv-1:0]       s_bvalid, s_bready;
  logic [NumSlv*2-1:0]     s_bresp;
  logic [NumSlv*IdW-1:0]   s_bid;

  // ===========================================================================
  //  Processing Elements
  // ===========================================================================
  for (genvar p = 0; p < NumPes; p++) begin : g_pe
    amo_e pe_amo;
    assign dcu_amo[p*2 +: 2] = pe_amo;

    pe_top #(
      .AddrW     (AddrW),
      .DataW     (DataW),
      .ItcmBytes (ItcmBytes),
      .BootAddr  (BootAddr),
      .HartId    (p)
    ) u_pe (
      .clk_i            (clk_i),
      .rst_ni           (rst_ni),
      .fetch_enable_i   (fetch_enable_i),

      .dcu_req_o        (dcu_req[p]),
      .dcu_gnt_i        (dcu_gnt[p]),
      .dcu_addr_o       (dcu_addr [p*AddrW     +: AddrW]),
      .dcu_we_o         (dcu_we[p]),
      .dcu_be_o         (dcu_be   [p*WordBytes +: WordBytes]),
      .dcu_wdata_o      (dcu_wdata[p*DataW     +: DataW]),
      .dcu_amo_o        (pe_amo),
      .dcu_rvalid_i     (dcu_rvalid[p]),
      .dcu_rdata_i      (dcu_rdata[p*DataW     +: DataW]),

      .simem_i_req_o    (if_req[p]),
      .simem_i_gnt_i    (if_gnt[p]),
      .simem_i_addr_o   (if_addr[p*AddrW +: AddrW]),
      .simem_i_rvalid_i (if_rvalid[p]),
      .simem_i_rdata_i  (if_rdata[p*DataW +: DataW]),

      .ext_req_o        (ex_req[p]),
      .ext_gnt_i        (ex_gnt[p]),
      .ext_addr_o       (ex_addr [p*AddrW     +: AddrW]),
      .ext_we_o         (ex_we[p]),
      .ext_be_o         (ex_be   [p*WordBytes +: WordBytes]),
      .ext_wdata_o      (ex_wdata[p*DataW     +: DataW]),
      .ext_rvalid_i     (ex_rvalid[p]),
      .ext_rdata_i      (ex_rdata[p*DataW     +: DataW]),

      .core_sleep_o     (core_sleep_o[p])
    );

    // --- master id p: instruction fetch -------------------------------------
    axi_master_simple #(
      .AddrW (AddrW), .DataW (DataW), .LenW (LenW)
    ) u_axi_ifetch (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .req_i     (if_req[p]),
      .gnt_o     (if_gnt[p]),
      .addr_i    (if_addr[p*AddrW +: AddrW]),
      .we_i      (1'b0),
      .be_i      ({StrbW{1'b1}}),
      .wdata_i   ({DataW{1'b0}}),
      .rvalid_o  (if_rvalid[p]),
      .rdata_o   (if_rdata[p*DataW +: DataW]),

      .arvalid_o (m_arvalid[p]),
      .arready_i (m_arready[p]),
      .araddr_o  (m_araddr[p*AddrW +: AddrW]),
      .arlen_o   (m_arlen[p*LenW +: LenW]),
      .rvalid_i  (m_rvalid[p]),
      .rready_o  (m_rready[p]),
      .rdata_i   (m_rdata[p*DataW +: DataW]),
      .rresp_i   (m_rresp[p*2 +: 2]),
      .rlast_i   (m_rlast[p]),
      .awvalid_o (m_awvalid[p]),
      .awready_i (m_awready[p]),
      .awaddr_o  (m_awaddr[p*AddrW +: AddrW]),
      .awlen_o   (m_awlen[p*LenW +: LenW]),
      .wvalid_o  (m_wvalid[p]),
      .wready_i  (m_wready[p]),
      .wdata_o   (m_wdata[p*DataW +: DataW]),
      .wstrb_o   (m_wstrb[p*StrbW +: StrbW]),
      .wlast_o   (m_wlast[p]),
      .bvalid_i  (m_bvalid[p]),
      .bready_o  (m_bready[p]),
      .bresp_i   (m_bresp[p*2 +: 2])
    );

    // --- master id NumPes+p: the cache's memory port -------------------------
    localparam int unsigned MD = NumPes + p;

    axi_master_dcu #(
      .AddrW (AddrW), .DataW (DataW), .LineBytes (LineBytes), .LenW (LenW)
    ) u_axi_dcu (
      .clk_i       (clk_i),
      .rst_ni      (rst_ni),
      .rd_req_i    (mrd_req[p]),
      .rd_addr_i   (mrd_addr[p*AddrW +: AddrW]),
      .rd_line_i   (mrd_line[p]),
      .rd_gnt_o    (mrd_gnt[p]),
      .rd_rvalid_o (mrd_rvalid[p]),
      .rd_rdata_o  (mrd_rdata[p*LineBits +: LineBits]),
      .wr_req_i    (mwr_req[p]),
      .wr_addr_i   (mwr_addr[p*AddrW +: AddrW]),
      .wr_be_i     (mwr_be[p*WordBytes +: WordBytes]),
      .wr_wdata_i  (mwr_wdata[p*DataW +: DataW]),
      .wr_gnt_o    (mwr_gnt[p]),

      .arvalid_o (m_arvalid[MD]),
      .arready_i (m_arready[MD]),
      .araddr_o  (m_araddr[MD*AddrW +: AddrW]),
      .arlen_o   (m_arlen[MD*LenW +: LenW]),
      .rvalid_i  (m_rvalid[MD]),
      .rready_o  (m_rready[MD]),
      .rdata_i   (m_rdata[MD*DataW +: DataW]),
      .rresp_i   (m_rresp[MD*2 +: 2]),
      .rlast_i   (m_rlast[MD]),
      .awvalid_o (m_awvalid[MD]),
      .awready_i (m_awready[MD]),
      .awaddr_o  (m_awaddr[MD*AddrW +: AddrW]),
      .awlen_o   (m_awlen[MD*LenW +: LenW]),
      .wvalid_o  (m_wvalid[MD]),
      .wready_i  (m_wready[MD]),
      .wdata_o   (m_wdata[MD*DataW +: DataW]),
      .wstrb_o   (m_wstrb[MD*StrbW +: StrbW]),
      .wlast_o   (m_wlast[MD]),
      .bvalid_i  (m_bvalid[MD]),
      .bready_o  (m_bready[MD]),
      .bresp_i   (m_bresp[MD*2 +: 2])
    );

    // --- master id 2*NumPes+p: the Data-Bridge's external port ---------------
    localparam int unsigned ME = 2*NumPes + p;

    axi_master_simple #(
      .AddrW (AddrW), .DataW (DataW), .LenW (LenW)
    ) u_axi_ext (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .req_i     (ex_req[p]),
      .gnt_o     (ex_gnt[p]),
      .addr_i    (ex_addr[p*AddrW +: AddrW]),
      .we_i      (ex_we[p]),
      .be_i      (ex_be[p*StrbW +: StrbW]),
      .wdata_i   (ex_wdata[p*DataW +: DataW]),
      .rvalid_o  (ex_rvalid[p]),
      .rdata_o   (ex_rdata[p*DataW +: DataW]),

      .arvalid_o (m_arvalid[ME]),
      .arready_i (m_arready[ME]),
      .araddr_o  (m_araddr[ME*AddrW +: AddrW]),
      .arlen_o   (m_arlen[ME*LenW +: LenW]),
      .rvalid_i  (m_rvalid[ME]),
      .rready_o  (m_rready[ME]),
      .rdata_i   (m_rdata[ME*DataW +: DataW]),
      .rresp_i   (m_rresp[ME*2 +: 2]),
      .rlast_i   (m_rlast[ME]),
      .awvalid_o (m_awvalid[ME]),
      .awready_i (m_awready[ME]),
      .awaddr_o  (m_awaddr[ME*AddrW +: AddrW]),
      .awlen_o   (m_awlen[ME*LenW +: LenW]),
      .wvalid_o  (m_wvalid[ME]),
      .wready_i  (m_wready[ME]),
      .wdata_o   (m_wdata[ME*DataW +: DataW]),
      .wstrb_o   (m_wstrb[ME*StrbW +: StrbW]),
      .wlast_o   (m_wlast[ME]),
      .bvalid_i  (m_bvalid[ME]),
      .bready_o  (m_bready[ME]),
      .bresp_i   (m_bresp[ME*2 +: 2])
    );
  end

  // ===========================================================================
  //  Data path: the cache sub-system, or its absence
  // ===========================================================================
  if (Coherent) begin : g_dcache

    assign mrd_line = '1;               // every miss fetches a whole line

    coherent_subsystem #(
      .NumCores  (NumPes),
      .NumWays   (NumWays),
      .NumSets   (NumSets),
      .LineBytes (LineBytes),
      .AddrW     (AddrW),
      .DataW     (DataW)
    ) u_dcache (
      .clk_i           (clk_i),
      .rst_ni          (rst_ni),

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

      .mem_rd_req_o    (mrd_req),
      .mem_rd_addr_o   (mrd_addr),
      .mem_rd_gnt_i    (mrd_gnt),
      .mem_rd_rvalid_i (mrd_rvalid),
      .mem_rd_rdata_i  (mrd_rdata),

      .mem_wr_req_o    (mwr_req),
      .mem_wr_addr_o   (mwr_addr),
      .mem_wr_be_o     (mwr_be),
      .mem_wr_wdata_o  (mwr_wdata),
      .mem_wr_gnt_i    (mwr_gnt),

      .perf_rd_hit_o   (perf_rd_hit_o),
      .perf_rd_miss_o  (perf_rd_miss_o),
      .perf_wr_hit_o   (perf_wr_hit_o),
      .perf_wr_miss_o  (perf_wr_miss_o),
      .perf_busy_o (perf_busy_o),
      .perf_stall_snoop_o (perf_stall_snoop_o),
      .perf_stall_s2_o (perf_stall_s2_o),
      .perf_rd_wait_o (perf_rd_wait_o),
      .perf_wr_wait_o (perf_wr_wait_o)
    );

  end else begin : g_nodcache

    assign mrd_line = '0;               // single-word accesses, no lines at all

    for (genvar p = 0; p < NumPes; p++) begin : g_bypass
      dcu_bypass #(
        .AddrW     (AddrW),
        .DataW     (DataW),
        .LineBytes (LineBytes)
      ) u_bypass (
        .clk_i           (clk_i),
        .rst_ni          (rst_ni),

        .core_req_i      (dcu_req[p]),
        .core_gnt_o      (dcu_gnt[p]),
        .core_addr_i     (dcu_addr [p*AddrW     +: AddrW]),
        .core_we_i       (dcu_we[p]),
        .core_be_i       (dcu_be   [p*WordBytes +: WordBytes]),
        .core_wdata_i    (dcu_wdata[p*DataW     +: DataW]),
        .core_amo_i      (dcu_amo[p*2 +: 2]),
        .core_rvalid_o   (dcu_rvalid[p]),
        .core_rdata_o    (dcu_rdata[p*DataW     +: DataW]),
        .core_sc_ok_o    (),

        .mem_rd_req_o    (mrd_req[p]),
        .mem_rd_addr_o   (mrd_addr[p*AddrW +: AddrW]),
        .mem_rd_gnt_i    (mrd_gnt[p]),
        .mem_rd_rvalid_i (mrd_rvalid[p]),
        .mem_rd_rdata_i  (mrd_rdata[p*LineBits +: LineBits]),

        .mem_wr_req_o    (mwr_req[p]),
        .mem_wr_addr_o   (mwr_addr [p*AddrW     +: AddrW]),
        .mem_wr_be_o     (mwr_be   [p*WordBytes +: WordBytes]),
        .mem_wr_wdata_o  (mwr_wdata[p*DataW     +: DataW]),
        .mem_wr_gnt_i    (mwr_gnt[p]),

        .perf_rd_hit_o   (perf_rd_hit_o [p*32 +: 32]),
        .perf_rd_miss_o  (perf_rd_miss_o[p*32 +: 32]),
        .perf_wr_hit_o   (perf_wr_hit_o [p*32 +: 32]),
        .perf_wr_miss_o  (perf_wr_miss_o[p*32 +: 32]),
        .perf_busy_o (perf_busy_o[p*32 +: 32]),
        .perf_stall_snoop_o (perf_stall_snoop_o[p*32 +: 32]),
        .perf_stall_s2_o (perf_stall_s2_o[p*32 +: 32]),
        .perf_rd_wait_o (perf_rd_wait_o[p*32 +: 32]),
        .perf_wr_wait_o (perf_wr_wait_o[p*32 +: 32])
      );
    end

  end

  // ===========================================================================
  //  The AXI crossbar
  // ===========================================================================
  //  Slave 0 = shared data memory, 1 = shared instruction memory, 2 = control.
  //  Index 0 is the least significant field of the packed map.
  axi_xbar #(
    .NumMasters     (NumMst),
    .NumSlaves      (NumSlv),
    .AddrW          (AddrW),
    .DataW          (DataW),
    .LenW           (LenW),
    .MaxOutstanding (4),
    .SlaveBase      ({32'h8000_0000, 32'h2000_0000, 32'h1000_0000}),
    .SlaveMask      ({32'hF000_0000, 32'hF000_0000, 32'hF000_0000})
  ) u_xbar (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),

    .m_arvalid_i (m_arvalid),
    .m_arready_o (m_arready),
    .m_araddr_i  (m_araddr),
    .m_arlen_i   (m_arlen),
    .m_rvalid_o  (m_rvalid),
    .m_rready_i  (m_rready),
    .m_rdata_o   (m_rdata),
    .m_rresp_o   (m_rresp),
    .m_rlast_o   (m_rlast),
    .m_awvalid_i (m_awvalid),
    .m_awready_o (m_awready),
    .m_awaddr_i  (m_awaddr),
    .m_awlen_i   (m_awlen),
    .m_wvalid_i  (m_wvalid),
    .m_wready_o  (m_wready),
    .m_wdata_i   (m_wdata),
    .m_wstrb_i   (m_wstrb),
    .m_wlast_i   (m_wlast),
    .m_bvalid_o  (m_bvalid),
    .m_bready_i  (m_bready),
    .m_bresp_o   (m_bresp),

    .s_arvalid_o (s_arvalid),
    .s_arready_i (s_arready),
    .s_araddr_o  (s_araddr),
    .s_arlen_o   (s_arlen),
    .s_arid_o    (s_arid),
    .s_rvalid_i  (s_rvalid),
    .s_rready_o  (s_rready),
    .s_rdata_i   (s_rdata),
    .s_rresp_i   (s_rresp),
    .s_rlast_i   (s_rlast),
    .s_rid_i     (s_rid),
    .s_awvalid_o (s_awvalid),
    .s_awready_i (s_awready),
    .s_awaddr_o  (s_awaddr),
    .s_awlen_o   (s_awlen),
    .s_awid_o    (s_awid),
    .s_wvalid_o  (s_wvalid),
    .s_wready_i  (s_wready),
    .s_wdata_o   (s_wdata),
    .s_wstrb_o   (s_wstrb),
    .s_wlast_o   (s_wlast),
    .s_bvalid_i  (s_bvalid),
    .s_bready_o  (s_bready),
    .s_bresp_i   (s_bresp),
    .s_bid_i     (s_bid)
  );

  // ===========================================================================
  //  Slave 0 -- shared data memory
  // ===========================================================================
  axi_sram #(
    .AddrW (AddrW), .DataW (DataW), .IdW (IdW), .LenW (LenW),
    .SizeBytes (SdmemBytes), .AccessLat (MemLat)
  ) u_sdmem (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .arvalid_i (s_arvalid[0]),
    .arready_o (s_arready[0]),
    .araddr_i  (s_araddr[0*AddrW +: AddrW]),
    .arlen_i   (s_arlen[0*LenW +: LenW]),
    .arid_i    (s_arid[0*IdW +: IdW]),
    .rvalid_o  (s_rvalid[0]),
    .rready_i  (s_rready[0]),
    .rdata_o   (s_rdata[0*DataW +: DataW]),
    .rresp_o   (s_rresp[0*2 +: 2]),
    .rlast_o   (s_rlast[0]),
    .rid_o     (s_rid[0*IdW +: IdW]),
    .awvalid_i (s_awvalid[0]),
    .awready_o (s_awready[0]),
    .awaddr_i  (s_awaddr[0*AddrW +: AddrW]),
    .awlen_i   (s_awlen[0*LenW +: LenW]),
    .awid_i    (s_awid[0*IdW +: IdW]),
    .wvalid_i  (s_wvalid[0]),
    .wready_o  (s_wready[0]),
    .wdata_i   (s_wdata[0*DataW +: DataW]),
    .wstrb_i   (s_wstrb[0*StrbW +: StrbW]),
    .wlast_i   (s_wlast[0]),
    .bvalid_o  (s_bvalid[0]),
    .bready_i  (s_bready[0]),
    .bresp_o   (s_bresp[0*2 +: 2]),
    .bid_o     (s_bid[0*IdW +: IdW])
  );

  // ===========================================================================
  //  Slave 1 -- shared instruction memory / boot memory
  // ===========================================================================
  axi_sram #(
    .AddrW (AddrW), .DataW (DataW), .IdW (IdW), .LenW (LenW),
    .SizeBytes (SimemBytes), .AccessLat (MemLat)
  ) u_simem (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .arvalid_i (s_arvalid[1]),
    .arready_o (s_arready[1]),
    .araddr_i  (s_araddr[1*AddrW +: AddrW]),
    .arlen_i   (s_arlen[1*LenW +: LenW]),
    .arid_i    (s_arid[1*IdW +: IdW]),
    .rvalid_o  (s_rvalid[1]),
    .rready_i  (s_rready[1]),
    .rdata_o   (s_rdata[1*DataW +: DataW]),
    .rresp_o   (s_rresp[1*2 +: 2]),
    .rlast_o   (s_rlast[1]),
    .rid_o     (s_rid[1*IdW +: IdW]),
    .awvalid_i (s_awvalid[1]),
    .awready_o (s_awready[1]),
    .awaddr_i  (s_awaddr[1*AddrW +: AddrW]),
    .awlen_i   (s_awlen[1*LenW +: LenW]),
    .awid_i    (s_awid[1*IdW +: IdW]),
    .wvalid_i  (s_wvalid[1]),
    .wready_o  (s_wready[1]),
    .wdata_i   (s_wdata[1*DataW +: DataW]),
    .wstrb_i   (s_wstrb[1*StrbW +: StrbW]),
    .wlast_i   (s_wlast[1]),
    .bvalid_o  (s_bvalid[1]),
    .bready_i  (s_bready[1]),
    .bresp_o   (s_bresp[1*2 +: 2]),
    .bid_o     (s_bid[1*IdW +: IdW])
  );

  // ===========================================================================
  //  Slave 2 -- uncached control region
  // ===========================================================================
  axi_ctrl #(
    .NumPes (NumPes), .AddrW (AddrW), .DataW (DataW),
    .IdW (IdW), .LenW (LenW), .IdBase (2*NumPes)
  ) u_ctrl (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .arvalid_i (s_arvalid[2]),
    .arready_o (s_arready[2]),
    .araddr_i  (s_araddr[2*AddrW +: AddrW]),
    .arlen_i   (s_arlen[2*LenW +: LenW]),
    .arid_i    (s_arid[2*IdW +: IdW]),
    .rvalid_o  (s_rvalid[2]),
    .rready_i  (s_rready[2]),
    .rdata_o   (s_rdata[2*DataW +: DataW]),
    .rresp_o   (s_rresp[2*2 +: 2]),
    .rlast_o   (s_rlast[2]),
    .rid_o     (s_rid[2*IdW +: IdW]),
    .awvalid_i (s_awvalid[2]),
    .awready_o (s_awready[2]),
    .awaddr_i  (s_awaddr[2*AddrW +: AddrW]),
    .awlen_i   (s_awlen[2*LenW +: LenW]),
    .awid_i    (s_awid[2*IdW +: IdW]),
    .wvalid_i  (s_wvalid[2]),
    .wready_o  (s_wready[2]),
    .wdata_i   (s_wdata[2*DataW +: DataW]),
    .wstrb_i   (s_wstrb[2*StrbW +: StrbW]),
    .wlast_i   (s_wlast[2]),
    .bvalid_o  (s_bvalid[2]),
    .bready_i  (s_bready[2]),
    .bresp_o   (s_bresp[2*2 +: 2]),
    .bid_o     (s_bid[2*IdW +: IdW]),

    .done_o          (done_o),
    .exit_code_o     (exit_code_o),
    .putchar_valid_o (putchar_valid_o),
    .putchar_data_o  (putchar_data_o),
    .cycle_o         (cycle_o)
  );

endmodule
