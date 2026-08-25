// =============================================================================
//  axi_ctrl.sv -- the uncached control region, as an AXI4 slave.
//
//  Same registers as the M5 soc_ctrl, but reached over the crossbar instead of
//  through its own arbiter: with a real fabric in front, arbitration is the
//  crossbar's job and this becomes an ordinary single-port slave.
//
//  Word map, relative to the region base:
//    0x00  TOHOST    w: latch this PE's exit code and mark it finished
//                    r: bitmap of the PEs that have finished
//    0x04  PUTCHAR   w: emit one character on the simulation console
//    0x08  CYCLE     r: free-running global cycle counter
//    0x0C  BARRIER   r: current barrier generation
//                    w: arrive; the generation advances once all PEs have
//    0x10  NUM_PES   r: how many PEs the SoC was built with
//
//  Which PE is talking comes from the AXI ID. soc_top numbers the Data-Bridge
//  masters contiguously from IdBase, so the PE index is just id - IdBase; that
//  is why the master ordering in soc_top is grouped by function rather than
//  interleaved per PE.
//
//  The barrier is still counted in hardware, one arrival per accepted write,
//  because CV32E40P has no A extension for software to build one from.
// =============================================================================
module axi_ctrl #(
  parameter  int unsigned NumPes = 4,
  parameter  int unsigned AddrW  = 32,
  parameter  int unsigned DataW  = 32,
  parameter  int unsigned IdW    = 4,
  parameter  int unsigned LenW   = 8,
  parameter  int unsigned IdBase = 8,      // AXI id of the PE 0 Data-Bridge

  localparam int unsigned StrbW = DataW/8,
  localparam int unsigned PeW   = (NumPes <= 1) ? 1 : $clog2(NumPes)
) (
  input  logic             clk_i,
  input  logic             rst_ni,

  input  logic             arvalid_i,
  output logic             arready_o,
  input  logic [AddrW-1:0] araddr_i,
  input  logic [LenW-1:0]  arlen_i,
  input  logic [IdW-1:0]   arid_i,

  output logic             rvalid_o,
  input  logic             rready_i,
  output logic [DataW-1:0] rdata_o,
  output logic [1:0]       rresp_o,
  output logic             rlast_o,
  output logic [IdW-1:0]   rid_o,

  input  logic             awvalid_i,
  output logic             awready_o,
  input  logic [AddrW-1:0] awaddr_i,
  input  logic [LenW-1:0]  awlen_i,
  input  logic [IdW-1:0]   awid_i,

  input  logic             wvalid_i,
  output logic             wready_o,
  input  logic [DataW-1:0] wdata_i,
  input  logic [StrbW-1:0] wstrb_i,
  input  logic             wlast_i,

  output logic             bvalid_o,
  input  logic             bready_i,
  output logic [1:0]       bresp_o,
  output logic [IdW-1:0]   bid_o,

  // --- observation, for the testbench ---------------------------------------
  output logic [NumPes-1:0]       done_o,
  output logic [NumPes*DataW-1:0] exit_code_o,
  output logic                    putchar_valid_o,
  output logic [7:0]              putchar_data_o,
  output logic [31:0]             cycle_o
);

  localparam logic [1:0] RESP_OKAY = 2'b00;

  logic [31:0]    cycle_q;
  logic [31:0]    bar_gen_q;
  logic [PeW:0]   bar_cnt_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) cycle_q <= '0;
    else         cycle_q <= cycle_q + 32'd1;
  end
  assign cycle_o = cycle_q;

  // ===========================================================================
  //  Read channel
  // ===========================================================================
  typedef enum logic [0:0] { R_IDLE, R_RESP } rstate_e;

  rstate_e         r_state_q;
  logic [IdW-1:0]  r_id_q;
  logic [DataW-1:0] r_data_q;

  assign arready_o = (r_state_q == R_IDLE);
  assign rvalid_o  = (r_state_q == R_RESP);
  assign rdata_o   = r_data_q;
  assign rresp_o   = RESP_OKAY;
  assign rlast_o   = 1'b1;
  assign rid_o     = r_id_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      r_state_q <= R_IDLE;
      r_id_q    <= '0;
      r_data_q  <= '0;
    end else begin
      case (r_state_q)
        R_IDLE: begin
          if (arvalid_i) begin
            r_id_q <= arid_i;
            case (araddr_i[7:0])
              8'h00:   r_data_q <= DataW'(done_o);
              8'h08:   r_data_q <= cycle_q;
              8'h0C:   r_data_q <= bar_gen_q;
              8'h10:   r_data_q <= DataW'(NumPes);
              default: r_data_q <= '0;
            endcase
            r_state_q <= R_RESP;
          end
        end
        R_RESP: if (rready_i) r_state_q <= R_IDLE;
        default: r_state_q <= R_IDLE;
      endcase
    end
  end

  // ===========================================================================
  //  Write channel
  // ===========================================================================
  typedef enum logic [1:0] { W_IDLE, W_DATA, W_RESP } wstate_e;

  wstate_e          w_state_q;
  logic [IdW-1:0]   w_id_q;
  logic [7:0]       w_reg_q;

  logic [PeW-1:0]   w_pe;
  assign w_pe = PeW'(int'(w_id_q) - IdBase);

  logic last_arrival;
  assign last_arrival = (bar_cnt_q == (PeW+1)'(NumPes - 1));

  assign awready_o = (w_state_q == W_IDLE);
  assign wready_o  = (w_state_q == W_DATA);
  assign bvalid_o  = (w_state_q == W_RESP);
  assign bresp_o   = RESP_OKAY;
  assign bid_o     = w_id_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      w_state_q       <= W_IDLE;
      w_id_q          <= '0;
      w_reg_q         <= '0;
      bar_gen_q       <= '0;
      bar_cnt_q       <= '0;
      done_o          <= '0;
      exit_code_o     <= '0;
      putchar_valid_o <= 1'b0;
      putchar_data_o  <= '0;
    end else begin
      putchar_valid_o <= 1'b0;

      case (w_state_q)
        W_IDLE: begin
          if (awvalid_i) begin
            w_id_q    <= awid_i;
            w_reg_q   <= awaddr_i[7:0];
            w_state_q <= W_DATA;
          end
        end

        W_DATA: begin
          if (wvalid_i) begin
            case (w_reg_q)
              8'h00: begin
                exit_code_o[int'(w_pe)*DataW +: DataW] <= wdata_i;
                done_o[w_pe]                           <= 1'b1;
              end
              8'h04: begin
                putchar_valid_o <= 1'b1;
                putchar_data_o  <= wdata_i[7:0];
              end
              8'h0C: begin
                if (last_arrival) begin
                  bar_cnt_q <= '0;
                  bar_gen_q <= bar_gen_q + 32'd1;
                end else begin
                  bar_cnt_q <= bar_cnt_q + (PeW+1)'(1);
                end
              end
              default: ;
            endcase
            if (wlast_i) w_state_q <= W_RESP;
          end
        end

        W_RESP: if (bready_i) w_state_q <= W_IDLE;

        default: w_state_q <= W_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (rst_ni && arvalid_i && arready_o && (arlen_i != '0))
      $error("axi_ctrl: burst read of the control region (len %0d)", arlen_i);
    if (rst_ni && awvalid_i && awready_o && (awlen_i != '0))
      $error("axi_ctrl: burst write of the control region (len %0d)", awlen_i);
    if (rst_ni && (w_state_q == W_DATA) && wvalid_i
        && ((int'(w_id_q) < IdBase) || (int'(w_id_q) >= IdBase + int'(NumPes))))
      $error("axi_ctrl: write from unexpected master id %0d", w_id_q);
  end

  logic unused_strb;
  assign unused_strb = |wstrb_i;      // every register is a whole word
`endif

endmodule
