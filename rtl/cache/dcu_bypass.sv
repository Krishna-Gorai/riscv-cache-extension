// =============================================================================
//  dcu_bypass.sv -- the non-coherent baseline: a PE with no data cache.
//
//  Section IV-A builds two 4-PE systems and compares them: "The first one is a
//  coherent multi-core architecture with shared coherent data memory and a
//  shared snoopy bus unit. The second one is a non-coherent version with the
//  same number of RISC-V-based PEs with a shared scratchpad data memory."
//
//  So the baseline is a PE with the DCU removed, not a PE with an incoherent
//  cache. An incoherent cache would simply compute wrong answers, and the
//  paper's own overhead figure is stated against "a single PE without a data
//  cache". This module is that removal, made pin compatible with the DCU so
//  that soc_top selects between the two with one parameter and nothing else in
//  the SoC changes.
//
//  Every access goes straight to the shared data memory as a single word, one
//  transaction at a time. It is trivially coherent, because only one copy of
//  the data exists anywhere in the system, and it is slow for exactly the
//  reason the paper measures: no reuse is ever captured locally.
// =============================================================================
module dcu_bypass
  import cache_pkg::*;
#(
  parameter  int unsigned AddrW     = 32,
  parameter  int unsigned DataW     = 32,
  parameter  int unsigned LineBytes = 16,

  localparam int unsigned WordBytes = DataW / 8,
  localparam int unsigned LineBits  = LineBytes * 8
) (
  input  logic                 clk_i,
  input  logic                 rst_ni,

  // --- core D-Port, identical to the DCU's -----------------------------------
  input  logic                 core_req_i,
  output logic                 core_gnt_o,
  input  logic [AddrW-1:0]     core_addr_i,
  input  logic                 core_we_i,
  input  logic [WordBytes-1:0] core_be_i,
  input  logic [DataW-1:0]     core_wdata_i,
  input  logic [1:0]           core_amo_i,   // amo_e encoding, raw off the bus
  output logic                 core_rvalid_o,
  output logic [DataW-1:0]     core_rdata_o,
  output logic                 core_sc_ok_o,

  // --- shared data memory ----------------------------------------------------
  output logic                 mem_rd_req_o,
  output logic [AddrW-1:0]     mem_rd_addr_o,
  input  logic                 mem_rd_gnt_i,
  input  logic                 mem_rd_rvalid_i,
  input  logic [LineBits-1:0]  mem_rd_rdata_i,

  output logic                 mem_wr_req_o,
  output logic [AddrW-1:0]     mem_wr_addr_o,
  output logic [WordBytes-1:0] mem_wr_be_o,
  output logic [DataW-1:0]     mem_wr_wdata_o,
  input  logic                 mem_wr_gnt_i,

  // --- counters, so one reporting path serves both architectures ------------
  output logic [31:0]          perf_rd_hit_o,
  output logic [31:0]          perf_rd_miss_o,
  output logic [31:0]          perf_wr_hit_o,
  output logic [31:0]          perf_wr_miss_o,

  // Same cycle accounting as the DCU, so the two architectures can be compared
  // on where the time went and not just on how many cycles it took. There is
  // no snoopy bus on this path and no second stage, so those two are tied off:
  // that difference is exactly what the comparison is meant to expose.
  output logic [31:0]          perf_busy_o,
  output logic [31:0]          perf_stall_snoop_o,
  output logic [31:0]          perf_stall_s2_o,
  output logic [31:0]          perf_rd_wait_o,
  output logic [31:0]          perf_wr_wait_o
);

  // A request must be withdrawn once it has been granted. Holding it up until
  // the response arrives would let the memory grant the very same request
  // again on the next cycle, and the surplus read's rvalid would then land in
  // whatever transaction happened to be outstanding by the time it came back.
  typedef enum logic [2:0] { S_IDLE, S_RD_REQ, S_RD_WAIT, S_WR } state_e;

  state_e               state_q;
  logic [AddrW-1:0]     addr_q;
  logic [WordBytes-1:0] be_q;
  logic [DataW-1:0]     wdata_q;

  assign core_gnt_o   = (state_q == S_IDLE) && core_req_i;
  assign core_sc_ok_o = 1'b0;          // no atomic ever reaches this path

  assign mem_rd_req_o   = (state_q == S_RD_REQ);
  assign mem_rd_addr_o  = addr_q;
  assign mem_wr_req_o   = (state_q == S_WR);
  assign mem_wr_addr_o  = addr_q;
  assign mem_wr_be_o    = be_q;
  assign mem_wr_wdata_o = wdata_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q       <= S_IDLE;
      addr_q        <= '0;
      be_q          <= '0;
      wdata_q       <= '0;
      core_rvalid_o <= 1'b0;
      core_rdata_o  <= '0;
    end else begin
      core_rvalid_o <= 1'b0;

      unique case (state_q)
        S_IDLE: begin
          if (core_gnt_o) begin
            addr_q  <= core_addr_i;
            be_q    <= core_be_i;
            wdata_q <= core_wdata_i;
            state_q <= core_we_i ? S_WR : S_RD_REQ;
          end
        end

        S_RD_REQ: begin
          if (mem_rd_gnt_i) state_q <= S_RD_WAIT;
        end

        S_RD_WAIT: begin
          // A single-word read: the memory returns it in the low lane.
          if (mem_rd_rvalid_i) begin
            core_rdata_o  <= mem_rd_rdata_i[DataW-1:0];
            core_rvalid_o <= 1'b1;
            state_q       <= S_IDLE;
          end
        end

        S_WR: begin
          if (mem_wr_gnt_i) begin
            core_rvalid_o <= 1'b1;
            state_q       <= S_IDLE;
          end
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  //  Counters -- every access is a miss, by construction
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      perf_rd_miss_o <= '0;
      perf_wr_miss_o <= '0;
      perf_busy_o    <= '0;
      perf_rd_wait_o <= '0;
      perf_wr_wait_o <= '0;
    end else begin
      if ((state_q == S_RD_WAIT) && mem_rd_rvalid_i) perf_rd_miss_o <= perf_rd_miss_o + 32'd1;
      if ((state_q == S_WR) && mem_wr_gnt_i)    perf_wr_miss_o <= perf_wr_miss_o + 32'd1;

      // Count from the cycle the request is ACCEPTED, not from the cycle
      // after. The DCU counts its stage-1 cycle, so leaving the accept
      // cycle out here would flatter this path by one cycle per access
      // and make the comparison say something it should not.
      if ((state_q != S_IDLE) || core_gnt_o)    perf_busy_o    <= perf_busy_o    + 32'd1;
      if ((state_q == S_RD_REQ) || (state_q == S_RD_WAIT))
                                                perf_rd_wait_o <= perf_rd_wait_o + 32'd1;
      if (state_q == S_WR)                      perf_wr_wait_o <= perf_wr_wait_o + 32'd1;
    end
  end

  // No snoopy bus and no second stage on this path.
  assign perf_stall_snoop_o = '0;
  assign perf_stall_s2_o    = '0;

  assign perf_rd_hit_o = '0;
  assign perf_wr_hit_o = '0;

  logic unused_amo;
  assign unused_amo = (core_amo_i != AMO_NONE);

endmodule
