// =============================================================================
//  filter_sva.sv -- the snoop filter's safety properties, as assertions.
//
//  Written 2026-09-18. The paper claimed the mirror "cannot drift" from the
//  cache state, and backed the fill-in-flight term with a counter that fired on
//  20 of 2,241 granted invalidations over ten interleavings. A counter says a
//  case was exercised; it does not say the design was right in every cycle in
//  which it was not exercised. These properties do, for every cycle of every
//  run they are compiled into.
//
//  They are deliberately written against GROUND TRUTH -- the DCUs' own
//  Status-RAM and Tag-RAM, and their fill state -- and never against the
//  filter's own outputs, which would be circular. The checker therefore sits
//  outside the design and reaches into both sides by hierarchical reference.
//  Every such reference is indexed by a genvar, so the paths are constant.
//
//    P1  mirror equivalence. Every (core, set, way) of the mirror agrees with
//        that core's cache, in the valid bit and, where valid, in the tag.
//        This is what the word "exact" means in the paper.
//
//    P2  suppression safety. When the bus grants an invalidation without
//        broadcasting it, no other DCU holds the line.
//
//    P3  the fill-in-flight term: the same, for a cache that holds nothing yet
//        but is fetching the line. P3 is what a committed-tag mirror gets
//        wrong, and it is the property the 20-of-2,241 counter was sampling.
//
//  Instantiated by tb_coherent_subsystem under `ifdef FILTER_SVA.
// =============================================================================
`ifndef SYNTHESIS
module filter_sva #(
  parameter int unsigned NumCores = 4,
  parameter int unsigned NumWays  = 2,
  parameter int unsigned NumSets  = 64,
  parameter int unsigned AddrW    = 32,
  parameter int unsigned OffsW    = 4,

  localparam int unsigned IdxW = $clog2(NumSets),
  localparam int unsigned TagW = AddrW - IdxW - OffsW
) (
  input logic clk_i,
  input logic rst_ni
);

  localparam string DUT  = "tb_coherent_subsystem.dut";

  // ---------------------------------------------------------------------------
  //  Ground truth, flattened out of the DCUs with constant (genvar) paths
  // ---------------------------------------------------------------------------
  logic            dcu_v [NumCores][NumSets][NumWays];
  logic [TagW-1:0] dcu_t [NumCores][NumSets][NumWays];
  logic            mir_v [NumCores][NumSets][NumWays];
  logic [TagW-1:0] mir_t [NumCores][NumSets][NumWays];
  logic            fbusy [NumCores];
  logic [AddrW-1:0] faddr [NumCores];

  for (genvar c = 0; c < NumCores; c++) begin : g_c
    assign fbusy[c] = tb_coherent_subsystem.dut.g_dcu[c].u_dcu.fill_busy_o;
    assign faddr[c] = tb_coherent_subsystem.dut.g_dcu[c].u_dcu.fill_addr_o;
    for (genvar s = 0; s < NumSets; s++) begin : g_s
      for (genvar w = 0; w < NumWays; w++) begin : g_w
        assign dcu_v[c][s][w] =
          tb_coherent_subsystem.dut.g_dcu[c].u_dcu.valid_q[s][w];
        assign dcu_t[c][s][w] =
          tb_coherent_subsystem.dut.g_dcu[c].u_dcu.u_tag_ram.mem[s][w*TagW +: TagW];
        assign mir_v[c][s][w] =
          tb_coherent_subsystem.dut.u_snoopy_bus.g_filter.u_filter.g_core[c].g_way[w].valid_mem[s];
        assign mir_t[c][s][w] =
          tb_coherent_subsystem.dut.u_snoopy_bus.g_filter.u_filter.g_core[c].g_way[w].tag_mem[s];
      end
    end
  end

  // ---------------------------------------------------------------------------
  //  P1  mirror equivalence
  // ---------------------------------------------------------------------------
  //  One (core, set, way) per cycle, round-robin, so the cost is constant and
  //  the whole mirror is covered every NumCores*NumSets*NumWays cycles -- 512
  //  here, which every run sweeps over many times.
  localparam int unsigned Scan = NumCores*NumSets*NumWays;
  int unsigned scan_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) scan_q <= 0;
    else         scan_q <= (scan_q == Scan-1) ? 0 : scan_q + 1;
  end

  int unsigned sc_c, sc_s, sc_w;
  always_comb begin
    sc_c = scan_q / (NumSets*NumWays);
    sc_s = (scan_q / NumWays) % NumSets;
    sc_w = scan_q % NumWays;
  end

  a_mirror_valid: assert property (@(posedge clk_i) disable iff (!rst_ni)
    mir_v[sc_c][sc_s][sc_w] == dcu_v[sc_c][sc_s][sc_w])
  else $error("SVA P1 valid: core %0d set %0d way %0d  mirror=%0b cache=%0b",
              sc_c, sc_s, sc_w, mir_v[sc_c][sc_s][sc_w], dcu_v[sc_c][sc_s][sc_w]);

  a_mirror_tag: assert property (@(posedge clk_i) disable iff (!rst_ni)
    dcu_v[sc_c][sc_s][sc_w] |-> mir_t[sc_c][sc_s][sc_w] == dcu_t[sc_c][sc_s][sc_w])
  else $error("SVA P1 tag: core %0d set %0d way %0d  mirror=%h cache=%h",
              sc_c, sc_s, sc_w, mir_t[sc_c][sc_s][sc_w], dcu_t[sc_c][sc_s][sc_w]);

  // ---------------------------------------------------------------------------
  //  P2 / P3  suppression safety, against ground truth
  // ---------------------------------------------------------------------------
  wire              gnt      = tb_coherent_subsystem.dut.u_snoopy_bus.inv_gnt_valid;
  wire              bcast    = tb_coherent_subsystem.dut.u_snoopy_bus.bcast_needed;
  wire [AddrW-1:0]  sup_addr = tb_coherent_subsystem.dut.u_snoopy_bus.win_addr;
  wire              is_sc    = tb_coherent_subsystem.dut.u_snoopy_bus.win_is_sc;
  wire              sc_ok    = tb_coherent_subsystem.dut.u_snoopy_bus.sc_excl_ok;
  wire [31:0]       sup_core = tb_coherent_subsystem.dut.u_snoopy_bus.inv_arb_idx;

  // A store-conditional whose reservation was lost is dropped rather than
  // written, and the bus grants it without a broadcast for that reason and not
  // because the filter said so. It is not a suppression.
  wire suppression = gnt && !bcast && !(is_sc && !sc_ok);

  wire [IdxW-1:0] sup_set = sup_addr[OffsW +: IdxW];
  wire [TagW-1:0] sup_tag = sup_addr[AddrW-1 -: TagW];

  // Does some core other than the writer really hold, or really fetch, the line?
  logic other_holds, other_fills;
  always_comb begin
    other_holds = 1'b0;
    other_fills = 1'b0;
    for (int unsigned c = 0; c < NumCores; c++) begin
      if (c != sup_core) begin
        for (int unsigned w = 0; w < NumWays; w++)
          if (dcu_v[c][sup_set][w] && dcu_t[c][sup_set][w] == sup_tag)
            other_holds = 1'b1;
        if (fbusy[c] && faddr[c][AddrW-1:OffsW] == sup_addr[AddrW-1:OffsW])
          other_fills = 1'b1;
      end
    end
  end

  a_suppress_no_holder: assert property (@(posedge clk_i) disable iff (!rst_ni)
    suppression |-> !other_holds)
  else $error("SVA P2: suppressed INV for %h from core %0d, but another DCU holds it",
              sup_addr, sup_core);

  a_suppress_no_filler: assert property (@(posedge clk_i) disable iff (!rst_ni)
    suppression |-> !other_fills)
  else $error("SVA P3: suppressed INV for %h from core %0d, but another DCU is fetching it",
              sup_addr, sup_core);

  // ---------------------------------------------------------------------------
  //  Report, so that a passing run says so rather than saying nothing
  // ---------------------------------------------------------------------------
  int unsigned n_cyc, n_sup, n_cov;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      n_cyc <= 0; n_sup <= 0; n_cov <= 0;
    end else begin
      n_cyc <= n_cyc + 1;
      if (suppression) n_sup <= n_sup + 1;
      if (scan_q == Scan-1) n_cov <= n_cov + 1;
    end
  end

  final begin
    $display(" SVA %0d cycles, %0d suppressions checked, mirror swept %0d times",
             n_cyc, n_sup, n_cov);
  end

endmodule
`endif
