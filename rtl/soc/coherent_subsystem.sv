// =============================================================================
//  coherent_subsystem.sv -- the complete data-cache sub-system extension.
//
//  NumCores private Data Cache Units tied together by one scalable snoopy bus
//  unit, exactly the shaded "D-Cache Sub-system" block of Fig. 1. Each core
//  D-Port is exposed unchanged, and each DCU keeps its own path to the coherent
//  shared data memory, which in the full SoC runs through the Data-Bridge and
//  the AXI crossbar.
//
//  Everything here is parameterised in core count, associativity, set count and
//  line width, which is the "seamless and scalable" claim of the paper: adding
//  a core costs one more DCU and one more port on the snoopy bus, with no
//  change to the cores or to the interconnect.
// =============================================================================
module coherent_subsystem
  import cache_pkg::*;
#(
  parameter  int unsigned NumCores     = 4,
  parameter  int unsigned NumWays      = 2,
  parameter  int unsigned NumSets      = 64,
  parameter  int unsigned LineBytes    = 16,
  parameter  int unsigned AddrW        = 32,
  parameter  int unsigned DataW        = 32,

  localparam int unsigned WordBytes    = DataW / 8,
  localparam int unsigned LineBits     = LineBytes * 8
) (
  input  logic                          clk_i,
  input  logic                          rst_ni,

  // --- core D-Ports ----------------------------------------------------------
  input  logic [NumCores-1:0]           core_req_i,
  output logic [NumCores-1:0]           core_gnt_o,
  input  logic [NumCores*AddrW-1:0]     core_addr_i,
  input  logic [NumCores-1:0]           core_we_i,
  input  logic [NumCores*WordBytes-1:0] core_be_i,
  input  logic [NumCores*DataW-1:0]     core_wdata_i,
  input  logic [NumCores*2-1:0]         core_amo_i,
  output logic [NumCores-1:0]           core_rvalid_o,
  output logic [NumCores*DataW-1:0]     core_rdata_o,
  output logic [NumCores-1:0]           core_sc_ok_o,

  // --- shared data memory ports ---------------------------------------------
  output logic [NumCores-1:0]           mem_rd_req_o,
  output logic [NumCores*AddrW-1:0]     mem_rd_addr_o,
  input  logic [NumCores-1:0]           mem_rd_gnt_i,
  input  logic [NumCores-1:0]           mem_rd_rvalid_i,
  input  logic [NumCores*LineBits-1:0]  mem_rd_rdata_i,

  output logic [NumCores-1:0]           mem_wr_req_o,
  output logic [NumCores*AddrW-1:0]     mem_wr_addr_o,
  output logic [NumCores*WordBytes-1:0] mem_wr_be_o,
  output logic [NumCores*DataW-1:0]     mem_wr_wdata_o,
  input  logic [NumCores-1:0]           mem_wr_gnt_i,

  // --- per-DCU performance counters -----------------------------------------
  output logic [NumCores*32-1:0]        perf_rd_hit_o,
  output logic [NumCores*32-1:0]        perf_rd_miss_o,
  output logic [NumCores*32-1:0]        perf_wr_hit_o,
  output logic [NumCores*32-1:0]        perf_wr_miss_o
);

  // snoopy bus wiring
  logic [NumCores-1:0]       snp_req;
  logic [NumCores-1:0]       snp_is_inv;
  logic [NumCores*AddrW-1:0] snp_addr;
  logic [NumCores*2-1:0]     snp_amo;
  logic [NumCores-1:0]       snp_gnt;
  logic [NumCores-1:0]       snp_excl_ok;
  logic [NumCores-1:0]       snp_wr_busy;
  logic [NumCores*AddrW-1:0] snp_wr_addr;

  logic [NumCores-1:0]       inv_valid;
  logic [NumCores*AddrW-1:0] inv_addr;
  logic [NumCores-1:0]       inv_ready;

  for (genvar c = 0; c < NumCores; c++) begin : g_dcu
    amo_e dcu_amo;
    amo_e dcu_snp_amo;
    // Decode the qualifier off the packed multi-core bus. Written as an
    // explicit mapping rather than an enum cast: the two are equivalent, and
    // the mapping elaborates on simulators that do not implement enum casts.
    always @(*) begin
      case (core_amo_i[c*2 +: 2])
        2'd1:    dcu_amo = AMO_LR;
        2'd2:    dcu_amo = AMO_SC;
        default: dcu_amo = AMO_NONE;
      endcase
    end

    assign snp_amo[c*2 +: 2]       = dcu_snp_amo;

    dcu #(
      .NumWays   (NumWays),
      .NumSets   (NumSets),
      .LineBytes (LineBytes),
      .AddrW     (AddrW),
      .DataW     (DataW)
    ) u_dcu (
      .clk_i           (clk_i),
      .rst_ni          (rst_ni),

      .core_req_i      (core_req_i[c]),
      .core_gnt_o      (core_gnt_o[c]),
      .core_addr_i     (core_addr_i [c*AddrW     +: AddrW]),
      .core_we_i       (core_we_i[c]),
      .core_be_i       (core_be_i   [c*WordBytes +: WordBytes]),
      .core_wdata_i    (core_wdata_i[c*DataW     +: DataW]),
      .core_amo_i      (dcu_amo),
      .core_rvalid_o   (core_rvalid_o[c]),
      .core_rdata_o    (core_rdata_o[c*DataW     +: DataW]),
      .core_sc_ok_o    (core_sc_ok_o[c]),

      .snp_req_o       (snp_req[c]),
      .snp_is_inv_o    (snp_is_inv[c]),
      .snp_addr_o      (snp_addr[c*AddrW +: AddrW]),
      .snp_amo_o       (dcu_snp_amo),
      .snp_gnt_i       (snp_gnt[c]),
      .snp_excl_ok_i   (snp_excl_ok[c]),
      .snp_wr_busy_o   (snp_wr_busy[c]),
      .snp_wr_addr_o   (snp_wr_addr[c*AddrW +: AddrW]),

      .snp_inv_valid_i (inv_valid[c]),
      .snp_inv_addr_i  (inv_addr[c*AddrW +: AddrW]),
      .snp_inv_ready_o (inv_ready[c]),

      .mem_rd_req_o    (mem_rd_req_o[c]),
      .mem_rd_addr_o   (mem_rd_addr_o[c*AddrW    +: AddrW]),
      .mem_rd_gnt_i    (mem_rd_gnt_i[c]),
      .mem_rd_rvalid_i (mem_rd_rvalid_i[c]),
      .mem_rd_rdata_i  (mem_rd_rdata_i[c*LineBits +: LineBits]),

      .mem_wr_req_o    (mem_wr_req_o[c]),
      .mem_wr_addr_o   (mem_wr_addr_o[c*AddrW     +: AddrW]),
      .mem_wr_be_o     (mem_wr_be_o[c*WordBytes   +: WordBytes]),
      .mem_wr_wdata_o  (mem_wr_wdata_o[c*DataW    +: DataW]),
      .mem_wr_gnt_i    (mem_wr_gnt_i[c]),

      .perf_rd_hit_o   (perf_rd_hit_o [c*32 +: 32]),
      .perf_rd_miss_o  (perf_rd_miss_o[c*32 +: 32]),
      .perf_wr_hit_o   (perf_wr_hit_o [c*32 +: 32]),
      .perf_wr_miss_o  (perf_wr_miss_o[c*32 +: 32])
    );
  end

  snoopy_bus #(
    .NumCores  (NumCores),
    .AddrW     (AddrW),
    .LineBytes (LineBytes)
  ) u_snoopy_bus (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .req_i       (snp_req),
    .is_inv_i    (snp_is_inv),
    .addr_i      (snp_addr),
    .amo_i       (snp_amo),
    .gnt_o       (snp_gnt),
    .excl_ok_o   (snp_excl_ok),
    .wr_busy_i   (snp_wr_busy),
    .wr_addr_i   (snp_wr_addr),
    .inv_valid_o (inv_valid),
    .inv_addr_o  (inv_addr),
    .inv_ready_i (inv_ready)
  );

endmodule
