// =============================================================================
//  bridge_router.sv -- handshake routing core shared by the Instruction-Bridge
//  and the Data-Bridge of a Processing Element (Fig. 1, Fig. 2c).
//
//  A CV32E40P memory port is an OBI-style channel: req/gnt opens the address
//  phase and rvalid closes the data phase, responses are returned strictly in
//  order, and several transactions may be outstanding at once.
//
//  Targets have different latencies, so letting requests to different targets
//  overlap would reorder the responses. The router therefore drains the
//  outstanding transactions before switching target. Traffic that stays inside
//  one region -- which is the normal case, since code runs from the ITCM and
//  data lives in the shared memory -- never pays for this.
//
//  A request that decodes to no target at all is absorbed by an internal void
//  responder that returns zero, so a stray access can never lock the core up.
// =============================================================================
module bridge_router #(
  parameter  int unsigned NumTgt         = 2,
  parameter  int unsigned DataW          = 32,
  parameter  int unsigned MaxOutstanding = 4,

  localparam int unsigned CntW = $clog2(MaxOutstanding + 1)
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,

  // upstream, towards the core
  input  logic                    up_req_i,
  input  logic [NumTgt-1:0]       up_sel_i,      // one-hot, all-zero = void
  output logic                    up_gnt_o,
  output logic                    up_rvalid_o,
  output logic [DataW-1:0]        up_rdata_o,

  // downstream, towards the targets
  output logic [NumTgt-1:0]       dn_req_o,
  input  logic [NumTgt-1:0]       dn_gnt_i,
  input  logic [NumTgt-1:0]       dn_rvalid_i,
  input  logic [NumTgt*DataW-1:0] dn_rdata_i
);

  logic [NumTgt-1:0] tgt_q;
  logic              void_q;
  logic [CntW-1:0]   outstanding_q;

  logic              sel_void;
  logic              same_tgt;
  logic              can_issue;

  assign sel_void = (up_sel_i == '0);
  assign same_tgt = sel_void ? void_q : (!void_q && (tgt_q == up_sel_i));

  assign can_issue = ((outstanding_q == '0) || same_tgt)
                     && (outstanding_q != CntW'(MaxOutstanding));

  // --- void responder ---------------------------------------------------------
  logic void_gnt, void_rvalid_q;
  assign void_gnt = up_req_i && can_issue && sel_void;

  // --- downstream requests ----------------------------------------------------
  assign dn_req_o = up_sel_i & {NumTgt{up_req_i && can_issue}};

  always_comb begin
    up_gnt_o = void_gnt;
    for (int unsigned t = 0; t < NumTgt; t++) begin
      if (up_sel_i[t] && dn_gnt_i[t] && up_req_i && can_issue) up_gnt_o = 1'b1;
    end
  end

  // --- responses --------------------------------------------------------------
  always_comb begin
    up_rvalid_o = void_rvalid_q;
    up_rdata_o  = '0;
    for (int unsigned t = 0; t < NumTgt; t++) begin
      if (tgt_q[t] && !void_q && dn_rvalid_i[t]) begin
        up_rvalid_o = 1'b1;
        up_rdata_o  = dn_rdata_i[t*DataW +: DataW];
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tgt_q         <= '0;
      void_q        <= 1'b0;
      outstanding_q <= '0;
      void_rvalid_q <= 1'b0;
    end else begin
      void_rvalid_q <= void_gnt;

      if (up_gnt_o) begin
        tgt_q  <= up_sel_i;
        void_q <= sel_void;
      end

      case ({up_gnt_o, up_rvalid_o})
        2'b10:   outstanding_q <= outstanding_q + 1'b1;
        2'b01:   outstanding_q <= outstanding_q - 1'b1;
        default: ;
      endcase
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (rst_ni && up_rvalid_o && (outstanding_q == '0) && !up_gnt_o) begin
      $error("bridge_router: response with no transaction outstanding");
    end
    if (rst_ni && $countones(up_sel_i) > 1) begin
      $error("bridge_router: target select is not one-hot (%b)", up_sel_i);
    end
  end
`endif

endmodule
