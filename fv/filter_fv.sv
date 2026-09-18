// =============================================================================
//  filter_fv.sv -- formal harness for the snoop filter.
//
//  What is proved
//    The filter must never answer "nobody holds this line" about a cache that
//    does hold it. That is the direction that matters: a false negative makes
//    the bus suppress an invalidation that was needed, which loses coherence.
//    A false positive only costs a broadcast that was not necessary.
//
//    The proof is by comparison against a reference model of one cache entry.
//    The entry -- which core, which set, which way -- is left free for the
//    solver to choose (anyconst), so a proof covers every entry of every cache
//    rather than one chosen by hand. The reference is updated by exactly the
//    events the DCU drives on the update port, and nothing constrains those
//    events, so the proof holds for every sequence of fills and invalidations
//    the caches could ever produce, not only the ones a testbench generates.
//
//      P_exact    if the reference entry is valid and its tag matches the
//                 queried address, and it does not belong to the querying
//                 core, then held_o must be set for that core.
//
//      P_any      any_other_o must be set whenever any held_o bit is, which is
//                 the signal the bus actually gates the broadcast on.
//
//      P_self     the querying core is never reported as a sharer, so the bus
//                 never broadcasts an invalidation back to the writer.
//
//    The converse of P_exact -- that a reported sharer really does hold the
//    line -- is a performance property rather than a safety one: getting it
//    wrong costs a broadcast that was not needed, which is what the unfiltered
//    design does on every write anyway. Proving it needs a reference model of
//    every entry rather than one, so it is left to the simulation assertions
//    of tb/sva/filter_sva.sv, which compare the whole mirror against the whole
//    cache every 512 cycles.
//
//  Geometry
//    Proved at a reduced geometry: the mirror's state is NumCores*NumSets*
//    NumWays valid bits plus that many tags, and k-induction over the full
//    64-set, 32-bit-address configuration is not tractable. The RTL is
//    parameterized and this instantiates the same source, so what is proved is
//    the design's logic rather than a rewrite of it. See fv/filter.sby.
// =============================================================================
module filter_fv #(
  parameter int unsigned NumCores = 4,
  parameter int unsigned NumWays  = 2,
  parameter int unsigned NumSets  = 32,
  parameter int unsigned AddrW    = 26,
  parameter int unsigned OffsW    = 4,

  localparam int unsigned IdxW  = $clog2(NumSets),
  localparam int unsigned TagW  = AddrW - IdxW - OffsW,
  localparam int unsigned WayW  = (NumWays <= 1) ? 1 : $clog2(NumWays),
  localparam int unsigned CoreW = $clog2(NumCores)
) (
  input logic clk,

  // Everything below is free: the solver drives it however it likes.
  input logic [NumCores-1:0]      upd_valid,
  input logic [NumCores*IdxW-1:0] upd_set,
  input logic [NumCores*WayW-1:0] upd_way,
  input logic [NumCores*TagW-1:0] upd_tag,
  input logic [NumCores-1:0]      upd_inst,
  input logic [AddrW-1:0]         qry_addr,
  input logic [CoreW-1:0]         qry_core,

  // The entry the reference tracks. Free, and captured during reset below, so
  // that a proof covers every entry of every cache rather than one chosen by
  // hand. Written this way rather than with an anyconst attribute because the
  // attribute is not carried through every SystemVerilog frontend, and a
  // silently free-running index would make the property meaningless.
  input logic [CoreW-1:0]         sel_core,
  input logic [IdxW-1:0]          sel_set,
  input logic [WayW-1:0]          sel_way
);

  // Reset is held for the first cycle and released for good, which is how the
  // subsystem drives it. Generated here rather than assumed over an input,
  // because an assumption that reads a net at time zero is not expressible.
  logic rst_done = 1'b0;
  always @(posedge clk) rst_done <= 1'b1;
  wire  rst_n = rst_done;

  logic [NumCores-1:0] held;
  logic                any_other;

  snoop_filter #(
    .NumCores (NumCores),
    .NumWays  (NumWays),
    .NumSets  (NumSets),
    .AddrW    (AddrW),
    .OffsW    (OffsW)
  ) dut (
    .clk_i       (clk),
    .rst_ni      (rst_n),
    .upd_valid_i (upd_valid),
    .upd_set_i   (upd_set),
    .upd_way_i   (upd_way),
    .upd_tag_i   (upd_tag),
    .upd_inst_i  (upd_inst),
    .qry_addr_i  (qry_addr),
    .qry_core_i  (qry_core),
    .held_o      (held),
    .any_other_o (any_other)
  );

  // Captured once, while reset is asserted, and constant from then on.
  logic [CoreW-1:0] rc;
  logic [IdxW-1:0]  rs;
  logic [WayW-1:0]  rw;

  always @(posedge clk) begin
    if (!rst_n) begin
      rc <= sel_core;
      rs <= sel_set;
      rw <= sel_way;
    end
  end

  logic            ref_v;
  logic [TagW-1:0] ref_t;

  // The same two events that write the cache write the reference: a fill
  // installs a tag and sets the valid bit, an invalidation clears it.
  wire hits_ref = upd_valid[rc]
               && (upd_way[rc*WayW +: WayW] == rw)
               && (upd_set[rc*IdxW +: IdxW] == rs);

  always @(posedge clk) begin
    if (!rst_n) begin
      ref_v <= 1'b0;
    end else if (hits_ref) begin
      ref_v <= upd_inst[rc];
      if (upd_inst[rc]) ref_t <= upd_tag[rc*TagW +: TagW];
    end
  end

  wire [IdxW-1:0] q_set = qry_addr[OffsW +: IdxW];
  wire [TagW-1:0] q_tag = qry_addr[AddrW-1 -: TagW];

  // The reference says this core holds the queried line.
  wire ref_says_held = ref_v && (q_set == rs) && (q_tag == ref_t);

  // ---------------------------------------------------------------------------
  //  Properties
  // ---------------------------------------------------------------------------
  always @(posedge clk) begin
    if (rst_n) begin
      // The one that matters: no false negative, for any entry.
      p_exact: assert (!(ref_says_held && (rc != qry_core)) || held[rc]);

      // The bus gates on any_other_o, so it has to follow held_o.
      p_any: assert (any_other == (|held));

      // The requester is never reported, so the bus never broadcasts to itself.
      p_self: assert (held[qry_core] == 1'b0);
    end
  end

endmodule
