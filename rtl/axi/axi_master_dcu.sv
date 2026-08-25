// =============================================================================
//  axi_master_dcu.sv -- the cache's memory-side port as an AXI4 master.
//
//  This is where AXI4 earns its place over AXI4-Lite. A miss in the DCU wants a
//  whole cache line, and on this fabric that is one INCR burst of
//  LineBytes/WordBytes beats -- a single arbitration, a single address phase,
//  and then a beat per cycle. Four independent word reads would pay the
//  crossbar arbitration and the memory's access latency four times over.
//
//  Write-through goes the other way: it is always one word, issued as a
//  single-beat write whose WSTRB carries the byte enables, so a partial store
//  lands without a read-modify-write of the line.
//
//  Read and write are separate state machines, because AXI's channels are
//  independent and the DCU can retire a write-through while a fill is still in
//  flight.
//
//  The line assembled here is presented exactly as the shared memory used to
//  present it in M5, so the DCU itself did not change when the crossbar
//  arrived -- which is the point of putting the AXI interface in the bridge
//  rather than in the cache.
// =============================================================================
module axi_master_dcu #(
  parameter  int unsigned AddrW     = 32,
  parameter  int unsigned DataW     = 32,
  parameter  int unsigned LineBytes = 16,
  parameter  int unsigned LenW      = 8,

  localparam int unsigned StrbW        = DataW/8,
  localparam int unsigned WordsPerLine = LineBytes / (DataW/8),
  localparam int unsigned LineBits     = LineBytes * 8,
  localparam int unsigned BeatW        = (WordsPerLine <= 1) ? 1 : $clog2(WordsPerLine)
) (
  input  logic                clk_i,
  input  logic                rst_ni,

  // --- cache side, unchanged from the M5 memory port ------------------------
  input  logic                rd_req_i,
  input  logic [AddrW-1:0]    rd_addr_i,
  input  logic                rd_line_i,      // 1 = whole line, 0 = one word
  output logic                rd_gnt_o,
  output logic                rd_rvalid_o,
  output logic [LineBits-1:0] rd_rdata_o,

  input  logic                wr_req_i,
  input  logic [AddrW-1:0]    wr_addr_i,
  input  logic [StrbW-1:0]    wr_be_i,
  input  logic [DataW-1:0]    wr_wdata_i,
  output logic                wr_gnt_o,

  // --- AXI4 master ----------------------------------------------------------
  output logic                arvalid_o,
  input  logic                arready_i,
  output logic [AddrW-1:0]    araddr_o,
  output logic [LenW-1:0]     arlen_o,

  input  logic                rvalid_i,
  output logic                rready_o,
  input  logic [DataW-1:0]    rdata_i,
  input  logic [1:0]          rresp_i,
  input  logic                rlast_i,

  output logic                awvalid_o,
  input  logic                awready_i,
  output logic [AddrW-1:0]    awaddr_o,
  output logic [LenW-1:0]     awlen_o,

  output logic                wvalid_o,
  input  logic                wready_i,
  output logic [DataW-1:0]    wdata_o,
  output logic [StrbW-1:0]    wstrb_o,
  output logic                wlast_o,

  input  logic                bvalid_i,
  output logic                bready_o,
  input  logic [1:0]          bresp_i
);

  // ===========================================================================
  //  Read: address phase, then assemble the burst into a line
  // ===========================================================================
  typedef enum logic [1:0] { R_IDLE, R_ADDR, R_DATA } rstate_e;

  rstate_e            r_state_q;
  logic [AddrW-1:0]   r_addr_q;
  logic [LenW-1:0]    r_len_q;
  logic [BeatW-1:0]   r_beat_q;
  logic [LineBits-1:0] r_line_q;

  assign rd_gnt_o  = (r_state_q == R_IDLE) && rd_req_i;
  assign arvalid_o = (r_state_q == R_ADDR);
  assign araddr_o  = r_addr_q;
  assign arlen_o   = r_len_q;
  assign rready_o  = (r_state_q == R_DATA);
  assign rd_rdata_o = r_line_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      r_state_q   <= R_IDLE;
      r_addr_q    <= '0;
      r_len_q     <= '0;
      r_beat_q    <= '0;
      r_line_q    <= '0;
      rd_rvalid_o <= 1'b0;
    end else begin
      rd_rvalid_o <= 1'b0;

      case (r_state_q)
        R_IDLE: begin
          if (rd_gnt_o) begin
            r_addr_q  <= rd_addr_i;
            r_len_q   <= rd_line_i ? LenW'(WordsPerLine - 1) : LenW'(0);
            r_beat_q  <= '0;
            r_state_q <= R_ADDR;
          end
        end

        R_ADDR: if (arready_i) r_state_q <= R_DATA;

        R_DATA: begin
          if (rvalid_i) begin
            r_line_q[int'(r_beat_q)*DataW +: DataW] <= rdata_i;
            r_beat_q <= r_beat_q + BeatW'(1);
            if (rlast_i) begin
              rd_rvalid_o <= 1'b1;
              r_state_q   <= R_IDLE;
            end
          end
        end

        default: r_state_q <= R_IDLE;
      endcase
    end
  end

  // ===========================================================================
  //  Write: always a single beat
  // ===========================================================================
  typedef enum logic [1:0] { W_IDLE, W_ADDR, W_DATA, W_RESP } wstate_e;

  wstate_e          w_state_q;
  logic [AddrW-1:0] w_addr_q;
  logic [StrbW-1:0] w_be_q;
  logic [DataW-1:0] w_data_q;

  // The cache is released as soon as the write is accepted here, but a second
  // write is not taken until the first has been answered, so no more than one
  // write-through is ever in flight.
  assign wr_gnt_o  = (w_state_q == W_IDLE) && wr_req_i;
  assign awvalid_o = (w_state_q == W_ADDR);
  assign awaddr_o  = w_addr_q;
  assign awlen_o   = '0;
  assign wvalid_o  = (w_state_q == W_DATA);
  assign wdata_o   = w_data_q;
  assign wstrb_o   = w_be_q;
  assign wlast_o   = 1'b1;
  assign bready_o  = (w_state_q == W_RESP);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      w_state_q <= W_IDLE;
      w_addr_q  <= '0;
      w_be_q    <= '0;
      w_data_q  <= '0;
    end else begin
      case (w_state_q)
        W_IDLE: begin
          if (wr_gnt_o) begin
            w_addr_q  <= wr_addr_i;
            w_be_q    <= wr_be_i;
            w_data_q  <= wr_wdata_i;
            w_state_q <= W_ADDR;
          end
        end

        W_ADDR: if (awready_i) w_state_q <= W_DATA;
        W_DATA: if (wready_i)  w_state_q <= W_RESP;
        W_RESP: if (bvalid_i)  w_state_q <= W_IDLE;

        default: w_state_q <= W_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (rst_ni && (r_state_q == R_DATA) && rvalid_i && (rresp_i != 2'b00))
      $error("axi_master_dcu: fill of %08x returned resp %02b", r_addr_q, rresp_i);
    if (rst_ni && (w_state_q == W_RESP) && bvalid_i && (bresp_i != 2'b00))
      $error("axi_master_dcu: write to %08x returned resp %02b", w_addr_q, bresp_i);
    if (rst_ni && (r_state_q == R_DATA) && rvalid_i && rlast_i
        && (r_beat_q != BeatW'(r_len_q)))
      $error("axi_master_dcu: burst ended on beat %0d, expected %0d",
             r_beat_q, r_len_q);
  end
`endif

endmodule
