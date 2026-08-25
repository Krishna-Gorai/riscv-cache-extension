// =============================================================================
//  axi_master_simple.sv -- single-word port to AXI4 master.
//
//  Turns the req/gnt/rvalid port used throughout this design into AXI
//  transactions of one beat. Two things in each PE need exactly this:
//
//    * the Instruction-Bridge, fetching from the shared instruction memory
//    * the Data-Bridge's external port, which reaches the shared instruction
//      memory during the boot transfer and the control region afterwards
//
//  One transaction is in flight at a time. The bridges upstream allow several
//  outstanding requests to one target, but holding to one here keeps responses
//  trivially ordered, and neither path is on the critical loop once the PEs
//  have copied their code into their ITCMs.
//
//  A write is acknowledged to the core when its B response arrives rather than
//  when the address is accepted, so a store cannot be reported complete before
//  the fabric has actually taken it.
// =============================================================================
module axi_master_simple #(
  parameter  int unsigned AddrW = 32,
  parameter  int unsigned DataW = 32,
  parameter  int unsigned LenW  = 8,

  localparam int unsigned StrbW = DataW/8
) (
  input  logic             clk_i,
  input  logic             rst_ni,

  // --- upstream, req / gnt / rvalid -----------------------------------------
  input  logic             req_i,
  output logic             gnt_o,
  input  logic [AddrW-1:0] addr_i,
  input  logic             we_i,
  input  logic [StrbW-1:0] be_i,
  input  logic [DataW-1:0] wdata_i,
  output logic             rvalid_o,
  output logic [DataW-1:0] rdata_o,

  // --- AXI4 master ----------------------------------------------------------
  output logic             arvalid_o,
  input  logic             arready_i,
  output logic [AddrW-1:0] araddr_o,
  output logic [LenW-1:0]  arlen_o,

  input  logic             rvalid_i,
  output logic             rready_o,
  input  logic [DataW-1:0] rdata_i,
  input  logic [1:0]       rresp_i,
  input  logic             rlast_i,

  output logic             awvalid_o,
  input  logic             awready_i,
  output logic [AddrW-1:0] awaddr_o,
  output logic [LenW-1:0]  awlen_o,

  output logic             wvalid_o,
  input  logic             wready_i,
  output logic [DataW-1:0] wdata_o,
  output logic [StrbW-1:0] wstrb_o,
  output logic             wlast_o,

  input  logic             bvalid_i,
  output logic             bready_o,
  input  logic [1:0]       bresp_i
);

  typedef enum logic [2:0] {
    S_IDLE, S_AR, S_R, S_AW, S_W, S_B
  } state_e;

  state_e           state_q;
  logic [AddrW-1:0] addr_q;
  logic [StrbW-1:0] be_q;
  logic [DataW-1:0] wdata_q;

  assign gnt_o = (state_q == S_IDLE) && req_i;

  assign arvalid_o = (state_q == S_AR);
  assign araddr_o  = addr_q;
  assign arlen_o   = '0;                 // one beat
  assign rready_o  = (state_q == S_R);

  assign awvalid_o = (state_q == S_AW);
  assign awaddr_o  = addr_q;
  assign awlen_o   = '0;
  assign wvalid_o  = (state_q == S_W);
  assign wdata_o   = wdata_q;
  assign wstrb_o   = be_q;
  assign wlast_o   = 1'b1;
  assign bready_o  = (state_q == S_B);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q  <= S_IDLE;
      addr_q   <= '0;
      be_q     <= '0;
      wdata_q  <= '0;
      rvalid_o <= 1'b0;
      rdata_o  <= '0;
    end else begin
      rvalid_o <= 1'b0;

      case (state_q)
        S_IDLE: begin
          if (gnt_o) begin
            addr_q  <= addr_i;
            be_q    <= be_i;
            wdata_q <= wdata_i;
            state_q <= we_i ? S_AW : S_AR;
          end
        end

        S_AR: if (arready_i) state_q <= S_R;

        S_R: begin
          if (rvalid_i) begin
            rdata_o  <= rdata_i;
            rvalid_o <= 1'b1;
            state_q  <= S_IDLE;
          end
        end

        S_AW: if (awready_i) state_q <= S_W;

        S_W:  if (wready_i)  state_q <= S_B;

        S_B: begin
          if (bvalid_i) begin
            rvalid_o <= 1'b1;            // the write's acknowledgement
            state_q  <= S_IDLE;
          end
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (rst_ni && (state_q == S_R) && rvalid_i && !rlast_i)
      $error("axi_master_simple: multi-beat response to a single-beat read");
    if (rst_ni && (state_q == S_R) && rvalid_i && (rresp_i != 2'b00))
      $error("axi_master_simple: read returned resp %02b for %08x", rresp_i, addr_q);
    if (rst_ni && (state_q == S_B) && bvalid_i && (bresp_i != 2'b00))
      $error("axi_master_simple: write returned resp %02b for %08x", bresp_i, addr_q);
  end
`endif

endmodule
