// =============================================================================
//  soc_top.sv -- the multi-core RISC-V SoC of Fig. 1.
//
//  NumPes Processing Elements, a shared scratchpad instruction memory that
//  doubles as the boot memory, a shared data memory, and -- selected by the
//  Coherent parameter -- either the data-cache sub-system of the paper or no
//  data cache at all.
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
  localparam int unsigned NumSiPorts = 2 * NumPes
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
  output logic [NumPes*32-1:0]    perf_wr_miss_o
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
  //  Data-cache sub-system <-> shared data memory
  // ---------------------------------------------------------------------------
  logic [NumPes-1:0]           mrd_req, mrd_gnt, mrd_rvalid, mrd_line;
  logic [NumPes*AddrW-1:0]     mrd_addr;
  logic [NumPes*LineBits-1:0]  mrd_rdata;

  logic [NumPes-1:0]           mwr_req, mwr_gnt;
  logic [NumPes*AddrW-1:0]     mwr_addr;
  logic [NumPes*WordBytes-1:0] mwr_be;
  logic [NumPes*DataW-1:0]     mwr_wdata;

  // ---------------------------------------------------------------------------
  //  PE <-> shared instruction memory. Ports [0..NumPes-1] are the fetch side,
  //  ports [NumPes..2*NumPes-1] the Data-Bridge side used during boot.
  // ---------------------------------------------------------------------------
  logic [NumSiPorts-1:0]       si_req, si_gnt, si_rvalid;
  logic [NumSiPorts*AddrW-1:0] si_addr;
  logic [NumSiPorts*DataW-1:0] si_rdata;

  // ---------------------------------------------------------------------------
  //  PE <-> control region
  // ---------------------------------------------------------------------------
  logic [NumPes-1:0]           ct_req, ct_gnt, ct_we, ct_rvalid;
  logic [NumPes*AddrW-1:0]     ct_addr;
  logic [NumPes*WordBytes-1:0] ct_be;
  logic [NumPes*DataW-1:0]     ct_wdata, ct_rdata;

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

      .simem_i_req_o    (si_req[p]),
      .simem_i_gnt_i    (si_gnt[p]),
      .simem_i_addr_o   (si_addr[p*AddrW +: AddrW]),
      .simem_i_rvalid_i (si_rvalid[p]),
      .simem_i_rdata_i  (si_rdata[p*DataW +: DataW]),

      .simem_d_req_o    (si_req[NumPes+p]),
      .simem_d_gnt_i    (si_gnt[NumPes+p]),
      .simem_d_addr_o   (si_addr[(NumPes+p)*AddrW +: AddrW]),
      .simem_d_rvalid_i (si_rvalid[NumPes+p]),
      .simem_d_rdata_i  (si_rdata[(NumPes+p)*DataW +: DataW]),

      .ctrl_req_o       (ct_req[p]),
      .ctrl_gnt_i       (ct_gnt[p]),
      .ctrl_addr_o      (ct_addr [p*AddrW     +: AddrW]),
      .ctrl_we_o        (ct_we[p]),
      .ctrl_be_o        (ct_be   [p*WordBytes +: WordBytes]),
      .ctrl_wdata_o     (ct_wdata[p*DataW     +: DataW]),
      .ctrl_rvalid_i    (ct_rvalid[p]),
      .ctrl_rdata_i     (ct_rdata[p*DataW     +: DataW]),

      .core_sleep_o     (core_sleep_o[p])
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
      .perf_wr_miss_o  (perf_wr_miss_o)
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
        .perf_wr_miss_o  (perf_wr_miss_o[p*32 +: 32])
      );
    end

  end

  // ===========================================================================
  //  Shared memories and the control region
  // ===========================================================================
  shared_data_mem #(
    .NumPorts  (NumPes),
    .AddrW     (AddrW),
    .DataW     (DataW),
    .LineBytes (LineBytes),
    .SizeBytes (SdmemBytes),
    .AccessLat (MemLat)
  ) u_sdmem (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .rd_req_i    (mrd_req),
    .rd_addr_i   (mrd_addr),
    .rd_line_i   (mrd_line),
    .rd_gnt_o    (mrd_gnt),
    .rd_rvalid_o (mrd_rvalid),
    .rd_rdata_o  (mrd_rdata),
    .wr_req_i    (mwr_req),
    .wr_addr_i   (mwr_addr),
    .wr_be_i     (mwr_be),
    .wr_wdata_i  (mwr_wdata),
    .wr_gnt_o    (mwr_gnt)
  );

  shared_instr_mem #(
    .NumPorts  (NumSiPorts),
    .AddrW     (AddrW),
    .DataW     (DataW),
    .SizeBytes (SimemBytes),
    .AccessLat (MemLat)
  ) u_simem (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .req_i    (si_req),
    .addr_i   (si_addr),
    .gnt_o    (si_gnt),
    .rvalid_o (si_rvalid),
    .rdata_o  (si_rdata)
  );

  soc_ctrl #(
    .NumPes (NumPes),
    .AddrW  (AddrW),
    .DataW  (DataW)
  ) u_ctrl (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .req_i           (ct_req),
    .gnt_o           (ct_gnt),
    .addr_i          (ct_addr),
    .we_i            (ct_we),
    .be_i            (ct_be),
    .wdata_i         (ct_wdata),
    .rvalid_o        (ct_rvalid),
    .rdata_o         (ct_rdata),
    .done_o          (done_o),
    .exit_code_o     (exit_code_o),
    .putchar_valid_o (putchar_valid_o),
    .putchar_data_o  (putchar_data_o),
    .cycle_o         (cycle_o)
  );

endmodule
