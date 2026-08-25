// =============================================================================
//  rr_arbiter.sv -- round-robin arbiter.
//
//  Both arbiters of the snoopy bus (Fig. 4) adopt the Round Robin arbitration
//  strategy: one for INV REQs and atomic SC WRITE REQs, one for atomic LR
//  READ REQs.
//
//  The pointer only advances when update_i confirms that the grant was
//  actually consumed, so a grant that the bus withholds for another reason
//  does not rotate the priority.
// =============================================================================
module rr_arbiter #(
  parameter  int unsigned NumReq = 4,
  localparam int unsigned IdxW   = (NumReq <= 1) ? 1 : $clog2(NumReq)
) (
  input  logic                clk_i,
  input  logic                rst_ni,

  input  logic [NumReq-1:0]   req_i,
  input  logic                update_i,

  output logic [NumReq-1:0]   gnt_o,
  output logic                gnt_valid_o,
  output logic [IdxW-1:0]     gnt_idx_o
);

  logic [IdxW-1:0] ptr_q;

  always_comb begin
    gnt_o       = '0;
    gnt_valid_o = 1'b0;
    gnt_idx_o   = '0;
    for (int unsigned i = 0; i < NumReq; i++) begin
      if (!gnt_valid_o && req_i[(int'(ptr_q) + i) % NumReq]) begin
        gnt_valid_o = 1'b1;
        gnt_idx_o   = IdxW'((int'(ptr_q) + i) % NumReq);
        gnt_o[(int'(ptr_q) + i) % NumReq] = 1'b1;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ptr_q <= '0;
    end else if (update_i && gnt_valid_o) begin
      ptr_q <= IdxW'((int'(gnt_idx_o) + 1) % NumReq);
    end
  end

endmodule
