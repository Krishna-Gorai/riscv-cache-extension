// =============================================================================
//  link_register.sv -- Link Register of the snoopy bus (Fig. 4).
//
//  Section III-B-b: "The address of the arbitrated LR READ REQ is stored in the
//  Link Register and the exclusive bit of the Link Register will be set to 1.
//  If a granted INV REQ has the same address as the address stored in the Link
//  Register, the exclusive bit will be set to 0 to indicate that the exclusive
//  access has failed. If no INV REQ with the same address was granted and the
//  SC MEM WRITE REQ arrives, the snoopy bus will signal the associate DCU that
//  the exclusive access was successful."
//
//  The reservation is kept at cache-line granularity, because that is the
//  granularity at which invalidations are broadcast.
// =============================================================================
module link_register #(
  parameter  int unsigned NumCores  = 4,
  parameter  int unsigned AddrW     = 32,
  parameter  int unsigned LineBytes = 16,

  localparam int unsigned OffsW = $clog2(LineBytes),
  localparam int unsigned CoreW = (NumCores <= 1) ? 1 : $clog2(NumCores)
) (
  input  logic             clk_i,
  input  logic             rst_ni,

  // allocation, driven by the LR READ REQ arbiter
  input  logic             lr_set_i,
  input  logic [CoreW-1:0] lr_core_i,
  input  logic [AddrW-1:0] lr_addr_i,

  // a granted INV REQ may break the reservation
  input  logic             inv_set_i,
  input  logic [AddrW-1:0] inv_addr_i,

  // store-conditional query and release
  input  logic [CoreW-1:0] sc_core_i,
  input  logic [AddrW-1:0] sc_addr_i,
  output logic             sc_excl_ok_o,
  input  logic             sc_clear_i,

  output logic             excl_bit_o
);

  logic             valid_q;
  logic             excl_q;
  logic [CoreW-1:0] core_q;
  logic [AddrW-1:0] addr_q;

  function automatic logic same_line(input logic [AddrW-1:0] a,
                                     input logic [AddrW-1:0] b);
    return a[AddrW-1:OffsW] == b[AddrW-1:OffsW];
  endfunction

  assign excl_bit_o   = excl_q;
  assign sc_excl_ok_o = valid_q && excl_q && (core_q == sc_core_i)
                        && same_line(addr_q, sc_addr_i);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_q <= 1'b0;
      excl_q  <= 1'b0;
      core_q  <= '0;
      addr_q  <= '0;
    end else begin
      // A granted INV REQ to the reserved line clears the exclusive bit. This
      // is evaluated before a new allocation so that an LR granted in the same
      // cycle as an unrelated invalidation still starts out exclusive.
      if (inv_set_i && valid_q && same_line(addr_q, inv_addr_i)) begin
        excl_q <= 1'b0;
      end

      // A store-conditional consumes the reservation, successful or not -- but
      // only its owner's. There is a single Link Register for the whole
      // cluster, so a failed SC from a core that no longer holds the
      // reservation must leave the current owner's reservation intact.
      if (sc_clear_i && valid_q && (core_q == sc_core_i)) begin
        valid_q <= 1'b0;
        excl_q  <= 1'b0;
      end

      // A new LR READ REQ takes ownership of the single Link Register.
      if (lr_set_i) begin
        valid_q <= 1'b1;
        excl_q  <= 1'b1;
        core_q  <= lr_core_i;
        addr_q  <= lr_addr_i;
      end
    end
  end

endmodule
