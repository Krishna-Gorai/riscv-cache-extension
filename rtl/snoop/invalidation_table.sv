// =============================================================================
//  invalidation_table.sv -- Invalidation Table of the snoopy bus (Fig. 4).
//
//  Section III-B-b: "As only one INV REQ request per clock cycle can be
//  granted, one core may try to read a cache line invalidated by another core,
//  which INV REQ has not yet been granted. To avoid this case, an Invalidation
//  Table keeps track of all failed INV REQs to the cores. The table consists of
//  one line per core where each entry consists of a valid bit and the value's
//  memory address to be invalidated."
//
//  One entry per core is sufficient because a DCU has a single stage-1 slot and
//  therefore at most one INV REQ outstanding at a time. An entry is valid while
//  that core is asserting an INV REQ that the arbiter has not granted yet; the
//  bus screens every READ REQ against the table, which is what realises the
//  Multiple-Readers-Single-Writer lock.
// =============================================================================
module invalidation_table #(
  parameter int unsigned NumCores = 4,
  parameter int unsigned AddrW    = 32
) (
  input  logic                      clk_i,
  input  logic                      rst_ni,

  input  logic [NumCores-1:0]       inv_req_i,    // core is asserting an INV REQ
  input  logic [NumCores*AddrW-1:0] inv_addr_i,
  input  logic [NumCores-1:0]       inv_gnt_i,    // granted in this cycle

  output logic [NumCores-1:0]       entry_valid_o,
  output logic [NumCores*AddrW-1:0] entry_addr_o
);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      entry_valid_o <= '0;
      entry_addr_o  <= '0;
    end else begin
      for (int unsigned c = 0; c < NumCores; c++) begin
        entry_valid_o[c] <= inv_req_i[c] && !inv_gnt_i[c];
        if (inv_req_i[c]) entry_addr_o[c*AddrW +: AddrW] <= inv_addr_i[c*AddrW +: AddrW];
      end
    end
  end

endmodule
