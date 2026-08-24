// =============================================================================
//  cache_ram.sv -- simple dual-port RAM primitive used for the Tag-RAM and the
//  Data-RAM of the Data Cache Unit (Fig. 2b).
//
//  One synchronous read port (driven by DCU stage 1) and one synchronous write
//  port (driven by DCU stage 2). Because the two stages can touch the same set
//  in the same cycle, a registered write-to-read collision bypass is built in
//  so that the value observed in stage 2 is always the most recent one.
//
//  The entry is split into GRANULES independently writable slices. The Tag-RAM
//  uses one granule per way; the Data-RAM uses one granule per word per way,
//  which is what lets a write-through hit update a single word while a refill
//  writes a whole line.
// =============================================================================
module cache_ram #(
  parameter  int unsigned Depth    = 64,
  parameter  int unsigned Width    = 32,   // bits per granule
  parameter  int unsigned Granules = 1,
  localparam int unsigned AddrW    = (Depth <= 1) ? 1 : $clog2(Depth),
  localparam int unsigned DataW    = Width * Granules
) (
  input  logic                clk_i,

  // read port -- DCU stage 1
  input  logic [AddrW-1:0]    raddr_i,
  output logic [DataW-1:0]    rdata_o,

  // write port -- DCU stage 2
  input  logic [AddrW-1:0]    waddr_i,
  input  logic [Granules-1:0] we_i,
  input  logic [DataW-1:0]    wdata_i
);

  logic [DataW-1:0] mem [Depth];

  logic [DataW-1:0]    rdata_q;
  logic [DataW-1:0]    wdata_q;
  logic [Granules-1:0] coll_q;

  always_ff @(posedge clk_i) begin
    for (int unsigned g = 0; g < Granules; g++) begin
      if (we_i[g]) mem[waddr_i][g*Width +: Width] <= wdata_i[g*Width +: Width];
    end

    rdata_q <= mem[raddr_i];
    wdata_q <= wdata_i;
    for (int unsigned g = 0; g < Granules; g++) begin
      coll_q[g] <= we_i[g] && (waddr_i == raddr_i);
    end
  end

  // Registered collision bypass: a granule written in the same cycle the read
  // was issued is forwarded instead of the (stale) array output.
  always_comb begin
    for (int unsigned g = 0; g < Granules; g++) begin
      rdata_o[g*Width +: Width] = coll_q[g] ? wdata_q[g*Width +: Width]
                                            : rdata_q[g*Width +: Width];
    end
  end

`ifndef SYNTHESIS
  initial begin
    for (int unsigned i = 0; i < Depth; i++) mem[i] = '0;
  end
`endif

endmodule
