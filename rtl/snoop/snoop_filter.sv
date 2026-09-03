// =============================================================================
//  snoop_filter.sv -- does any other cache actually hold this line?
//
//  Measured motivation (results/invalidation_use.csv): across matmul, conv2d,
//  FFT and memcpy, 1,048,821 invalidation broadcasts were sent and not one of
//  them cleared a line in another cache. Every kernel partitions its data per
//  PE, so every written line is private, and every broadcast pays a
//  cluster-wide arbitration and a handshake that waits for all other DCUs --
//  to inform nobody of anything. An oracle that suppresses those broadcasts is
//  worth a geometric mean 1.122x (results/oracle_ceiling.csv).
//
//  This is the structure that lets the bus decide, exactly, whether a broadcast
//  is needed.
//
//  Why a mirror rather than a Bloom filter
//    A hashed filter may only ever over-approximate: claiming a line is held
//    when it is not costs an unnecessary broadcast, which is safe, whereas the
//    opposite loses an invalidation and breaks coherence. Insert-only hashed
//    filters are safe but saturate -- matmul touches far more lines than any
//    affordable bitmap has bits -- and removing from one requires knowing when
//    a line leaves a cache, which is precisely the information a mirror already
//    has.
//
//  So this mirrors the DCUs' Status-RAM and Tag-RAM exactly: one entry per
//  core, set and way, holding the tag and a valid bit, written by the same two
//  events that change the cache itself -- a refill installs a tag into a way,
//  an invalidation clears one. Exactness is structural rather than argued: the
//  mirror is updated by the same events, at the same time, from the same
//  signals.
//
//  Cost is real and belongs in the paper: NumCores * NumSets * NumWays entries
//  of (TagW + 1) bits. For the paper's 4 x 64 x 2 x 23 that is 11,776 bits.
// =============================================================================
module snoop_filter #(
  parameter  int unsigned NumCores = 4,
  parameter  int unsigned NumWays  = 2,
  parameter  int unsigned NumSets  = 64,
  parameter  int unsigned AddrW    = 32,
  parameter  int unsigned OffsW    = 4,

  localparam int unsigned IdxW     = $clog2(NumSets),
  localparam int unsigned TagW     = AddrW - IdxW - OffsW,
  localparam int unsigned WayW     = (NumWays <= 1) ? 1 : $clog2(NumWays)
) (
  input  logic clk_i,
  input  logic rst_ni,

  // ---------------------------------------------------------------------------
  //  Mirror updates, one port per core, driven by that core's DCU.
  //    upd_valid_i : this core changed a way this cycle
  //    upd_set_i   : which set
  //    upd_way_i   : which way
  //    upd_tag_i   : the tag now in that way (ignored when installing = 0)
  //    upd_inst_i  : 1 = a refill installed a line, 0 = the way was cleared
  // ---------------------------------------------------------------------------
  input  logic [NumCores-1:0]            upd_valid_i,
  input  logic [NumCores*IdxW-1:0]       upd_set_i,
  input  logic [NumCores*WayW-1:0]       upd_way_i,
  input  logic [NumCores*TagW-1:0]       upd_tag_i,
  input  logic [NumCores-1:0]            upd_inst_i,

  // ---------------------------------------------------------------------------
  //  Query. For the address a core is about to write, which other cores hold
  //  the line? held_o[c] is set for every core other than the querying one that
  //  has the line resident.
  // ---------------------------------------------------------------------------
  input  logic [AddrW-1:0]               qry_addr_i,
  input  logic [$clog2(NumCores > 1 ? NumCores : 2)-1:0] qry_core_i,
  output logic [NumCores-1:0]            held_o,
  output logic                           any_other_o
);

  logic [TagW-1:0] tag_q   [NumCores][NumSets][NumWays];
  logic            valid_q [NumCores][NumSets][NumWays];

  // ---------------------------------------------------------------------------
  //  Mirror maintenance. A refill overwrites the way's tag and validates it; an
  //  invalidation clears the valid bit. Both are exactly what the DCU does to
  //  its own arrays on the same edge, which is what makes this exact.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned c = 0; c < NumCores; c++) begin
        for (int unsigned s = 0; s < NumSets; s++) begin
          for (int unsigned w = 0; w < NumWays; w++) valid_q[c][s][w] <= 1'b0;
        end
      end
    end else begin
      for (int unsigned c = 0; c < NumCores; c++) begin
        if (upd_valid_i[c]) begin
          automatic logic [IdxW-1:0] s = upd_set_i[c*IdxW +: IdxW];
          automatic logic [WayW-1:0] w = upd_way_i[c*WayW +: WayW];
          valid_q[c][s][w] <= upd_inst_i[c];
          if (upd_inst_i[c]) tag_q[c][s][w] <= upd_tag_i[c*TagW +: TagW];
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  //  Query
  // ---------------------------------------------------------------------------
  logic [IdxW-1:0] qry_set;
  logic [TagW-1:0] qry_tag;
  assign qry_set = qry_addr_i[OffsW +: IdxW];
  assign qry_tag = qry_addr_i[AddrW-1 -: TagW];

  always @(*) begin
    for (int unsigned c = 0; c < NumCores; c++) begin
      held_o[c] = 1'b0;
      for (int unsigned w = 0; w < NumWays; w++) begin
        if (valid_q[c][qry_set][w] && (tag_q[c][qry_set][w] == qry_tag)) begin
          held_o[c] = 1'b1;
        end
      end
    end
    // The writer's own copy is irrelevant: it updates or drops that itself, and
    // a broadcast is never sent to the requester.
    held_o[qry_core_i] = 1'b0;
  end

  assign any_other_o = |held_o;

endmodule
