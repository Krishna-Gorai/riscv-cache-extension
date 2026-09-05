// =============================================================================
//  snoop_filter.sv -- does any other cache actually hold this line?
//
//  Measured motivation (results/invalidation_use.csv): across matmul, conv2d,
//  FFT and memcpy, 1,048,821 invalidation broadcasts were sent and not one of
//  them cleared a line in another cache. Every kernel partitions its data per
//  PE, so every written line is private, and every broadcast pays a
//  cluster-wide arbitration and a handshake that waits for all other DCUs --
//  to inform nobody of anything. Suppressing them is worth a geometric mean
//  1.122x in cycles (results/snoop_filter.csv).
//
//  Why a mirror rather than a Bloom filter
//    A hashed filter may only ever over-approximate: claiming a line is held
//    when it is not costs an unnecessary broadcast, which is safe, whereas the
//    opposite loses an invalidation and breaks coherence. Insert-only hashed
//    filters are safe but saturate -- matmul touches far more lines than any
//    affordable bitmap has bits -- and removing from one requires knowing when
//    a line leaves a cache, which is precisely the information a mirror has.
//
//  So this mirrors the DCUs' Tag-RAM and Status-RAM exactly, written by the
//  same two events that change the caches: a refill installs a tag into a way,
//  an invalidation clears one. Exactness is structural rather than argued --
//  same signals, same edge, same conditions.
//
//  Structure, and why it is this shape
//    The first version stored tags and valid bits together in one
//    multi-dimensional array under an asynchronous reset, and read every core
//    and way of it combinationally. Vivado put all 11,776 bits in flip-flops
//    and none in memory: a RAM has no reset, and no single RAM serves eight
//    concurrent reads. That cost 11,800 registers and 10.6 MHz, which was more
//    than the mechanism was worth.
//
//    So the tags are split into one array per (core, way) -- eight arrays of
//    NumSets entries, each with a single write port and a single read port,
//    which is what distributed RAM actually is -- and held outside any reset,
//    because a tag whose valid bit is clear is never compared. The valid bits
//    stay in flip-flops, where they can be reset and read eight at a time; at
//    NumCores*NumSets*NumWays they are 512 bits rather than 11,264.
//
//    This is the same division the DCU makes for the same reason: see the
//    deviations note in dcu.sv about the Status-RAM being flip-flops.
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

  logic [IdxW-1:0] qry_set;
  logic [TagW-1:0] qry_tag;
  assign qry_set = qry_addr_i[OffsW +: IdxW];
  assign qry_tag = qry_addr_i[AddrW-1 -: TagW];

  // Valid bits: flip-flops, because they need a reset and are read eight at a
  // time. 512 bits at the paper's geometry.
  logic valid_q [NumCores][NumSets][NumWays];

  logic [TagW-1:0] tag_rd [NumCores][NumWays];
  logic            way_hit[NumCores][NumWays];

  for (genvar c = 0; c < NumCores; c++) begin : g_core
    for (genvar w = 0; w < NumWays; w++) begin : g_way

      // This core updated this way this cycle.
      logic upd_here;
      assign upd_here = upd_valid_i[c] &&
                        (upd_way_i[c*WayW +: WayW] == WayW'(w));

      // Tags: one array per (core, way), so each has exactly one write port and
      // one read port. No reset -- a tag is only ever compared when its valid
      // bit says it means something, and the valid bits are reset.
      (* ram_style = "distributed" *) logic [TagW-1:0] tag_mem [NumSets];

      always_ff @(posedge clk_i) begin
        if (upd_here && upd_inst_i[c]) begin
          tag_mem[upd_set_i[c*IdxW +: IdxW]] <= upd_tag_i[c*TagW +: TagW];
        end
      end

      assign tag_rd[c][w] = tag_mem[qry_set];

      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          for (int unsigned s = 0; s < NumSets; s++) valid_q[c][s][w] <= 1'b0;
        end else if (upd_here) begin
          valid_q[c][upd_set_i[c*IdxW +: IdxW]][w] <= upd_inst_i[c];
        end
      end

      assign way_hit[c][w] = valid_q[c][qry_set][w] &&
                             (tag_rd[c][w] == qry_tag);
    end
  end

  // ---------------------------------------------------------------------------
  //  Query result
  // ---------------------------------------------------------------------------
  always @(*) begin
    for (int unsigned c = 0; c < NumCores; c++) begin
      held_o[c] = 1'b0;
      for (int unsigned w = 0; w < NumWays; w++) begin
        if (way_hit[c][w]) held_o[c] = 1'b1;
      end
    end
    // The writer's own copy is irrelevant: it updates or drops that itself, and
    // a broadcast is never sent to the requester.
    held_o[qry_core_i] = 1'b0;
  end

  assign any_other_o = |held_o;

endmodule
