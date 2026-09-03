// =============================================================================
//  snoopy_bus.sv -- scalable snoopy bus unit (Fig. 4)
//
//  Section III-B-b: "The snoopy bus is connected to all Data-Bridges to provide
//  cache coherency. The snoopy bus consists of four main components: two
//  open-source Arbiters, a Link Register and an Invalidation Table. Both
//  Arbiters adopt the Round Robin arbitration strategy. The first Arbiter is
//  responsible for arbitrating the INV REQs and atomic Store-Conditional (SC)
//  WRITE REQs. The second Arbiter, on the other hand, handles the atomic
//  Load-Reserved (LR) READ REQs."
//
//  Behaviour
//    * A core WRITE REQ reaches the bus as an INV REQ. At most one is granted
//      per cycle; on grant the address is broadcast to every other DCU.
//    * A granted INV REQ is only released once every other DCU can accept the
//      broadcast, so an invalidation is never lost.
//    * Plain READ REQs are not arbitrated against each other -- multiple
//      readers may proceed in the same cycle, which is the "Multiple-Readers"
//      half of the MRSW invariant. A READ REQ is withheld while any other core
//      has an INV REQ outstanding for the same line, which is the
//      "Single-Writer" half.
//    * LR READ REQs additionally pass the second arbiter, since there is a
//      single Link Register.
//
//  Note on combinational structure: grants are a function of registered state
//  only (the DCU request registers, the arbiter pointers, the Invalidation
//  Table and the readiness of the other DCUs). The DCUs in turn compute their
//  invalidation readiness without looking at the grant, so no combinational
//  loop is closed across the cluster.
// =============================================================================
module snoopy_bus
  import cache_pkg::*;
#(
  parameter  int unsigned NumCores  = 4,
  parameter  int unsigned AddrW     = 32,
  parameter  int unsigned LineBytes = 16,

  // Snoop filter. 0 broadcasts every invalidation, as published. 1 consults an
  // exact mirror of the DCUs' tag arrays first and sends nothing when no other
  // cache holds the line. See rtl/snoop/snoop_filter.sv for why a mirror rather
  // than a hash, and results/invalidation_use.csv for why it is worth having.
  parameter  bit          SnoopFilter = 1'b0,
  // Geometry of the caches being mirrored; ignored when SnoopFilter is 0.
  parameter  int unsigned NumWays   = 2,
  parameter  int unsigned NumSets   = 64,

  localparam int unsigned OffsW = $clog2(LineBytes),
  localparam int unsigned IdxW  = $clog2(NumSets),
  localparam int unsigned TagW  = AddrW - IdxW - OffsW,
  localparam int unsigned WayW  = (NumWays <= 1) ? 1 : $clog2(NumWays),
  localparam int unsigned CoreW = (NumCores <= 1) ? 1 : $clog2(NumCores)
) (
  input  logic                      clk_i,
  input  logic                      rst_ni,

  // --- request channel, one per DCU (driven by its stage 1) ------------------
  input  logic [NumCores-1:0]       req_i,
  input  logic [NumCores-1:0]       is_inv_i,     // 1 = INV REQ, 0 = READ REQ
  input  logic [NumCores*AddrW-1:0] addr_i,
  input  logic [NumCores*2-1:0]     amo_i,        // packed amo_e
  output logic [NumCores-1:0]       gnt_o,
  output logic [NumCores-1:0]       excl_ok_o,

  // --- write-through still in flight, one per DCU ---------------------------
  input  logic [NumCores-1:0]       wr_busy_i,
  input  logic [NumCores*AddrW-1:0] wr_addr_i,

  // --- invalidation broadcast, one per DCU ----------------------------------
  output logic [NumCores-1:0]       inv_valid_o,
  output logic [NumCores*AddrW-1:0] inv_addr_o,
  input  logic [NumCores-1:0]       inv_ready_i,

  // --- snoop-filter mirror updates, one per DCU -----------------------------
  input  logic [NumCores-1:0]       dir_upd_i,
  input  logic [NumCores*IdxW-1:0]  dir_set_i,
  input  logic [NumCores*WayW-1:0]  dir_way_i,
  input  logic [NumCores*TagW-1:0]  dir_tag_i,
  input  logic [NumCores-1:0]       dir_inst_i
);

  function automatic logic same_line(input logic [AddrW-1:0] a,
                                     input logic [AddrW-1:0] b);
    return a[AddrW-1:OffsW] == b[AddrW-1:OffsW];
  endfunction

  // ---------------------------------------------------------------------------
  //  Request classification
  // ---------------------------------------------------------------------------
  logic [NumCores-1:0] is_write, is_read, is_lr, is_sc;

  // The qualifier is only ever compared, so the raw slice off the packed bus
  // is matched against the enum values directly rather than cast first.
  always @(*) begin
    for (int unsigned c = 0; c < NumCores; c++) begin
      is_write[c] = req_i[c] &&  is_inv_i[c];
      is_read[c]  = req_i[c] && !is_inv_i[c];
      is_lr[c]    = is_read[c]  && (amo_i[c*2 +: 2] == AMO_LR);
      is_sc[c]    = is_write[c] && (amo_i[c*2 +: 2] == AMO_SC);
    end
  end

  // ---------------------------------------------------------------------------
  //  Arbiter 1 -- INV REQs and atomic SC WRITE REQs
  // ---------------------------------------------------------------------------
  logic [NumCores-1:0] inv_arb_gnt;
  logic                inv_arb_valid;
  logic [CoreW-1:0]    inv_arb_idx;
  logic                inv_gnt_valid;

  // A line whose write-through is still in flight is locked against another
  // writer as well: that is the Single-Writer half of the MRSW invariant.
  logic [NumCores-1:0] write_blocked;

  always @(*) begin
    for (int unsigned w = 0; w < NumCores; w++) begin
      write_blocked[w] = 1'b0;
      for (int unsigned c = 0; c < NumCores; c++) begin
        if (c != w && wr_busy_i[c] &&
            same_line(wr_addr_i[c*AddrW +: AddrW], addr_i[w*AddrW +: AddrW])) begin
          write_blocked[w] = 1'b1;
        end
      end
    end
  end

  rr_arbiter #(.NumReq(NumCores)) u_inv_arb (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .req_i       (is_write & ~write_blocked),
    .update_i    (inv_gnt_valid),
    .gnt_o       (inv_arb_gnt),
    .gnt_valid_o (inv_arb_valid),
    .gnt_idx_o   (inv_arb_idx)
  );

  logic [AddrW-1:0] win_addr;
  logic             win_is_sc;
  logic             sc_excl_ok;
  logic             bcast_needed;
  logic             others_ready;

  assign win_addr  = addr_i[inv_arb_idx*AddrW +: AddrW];
  assign win_is_sc = is_sc[inv_arb_idx];

  // ---------------------------------------------------------------------------
  //  Snoop filter -- is there anybody to tell?
  //
  //  The mirror is exact, so filt_any_other is exact: when it is low, no other
  //  cache holds the line and a broadcast would clear nothing anywhere. Not
  //  sending it is therefore unobservable, which is a considerably easier thing
  //  to argue than the two mechanisms this replaced.
  //
  //  Held high when the filter is not built, so bcast_needed keeps its
  //  published meaning and the two designs differ in one parameter.
  // ---------------------------------------------------------------------------
  // Driven from inside a generate branch, so it is declared as a wire with an
  // explicit default rather than a variable: a variable left undriven in the
  // branch that is not taken reads as X, and an X here propagates straight into
  // bcast_needed and quietly changes what the bus does.
  wire filt_any_other;
  logic filt_from_mirror;

  if (SnoopFilter) begin : g_filter
    snoop_filter #(
      .NumCores (NumCores),
      .NumWays  (NumWays),
      .NumSets  (NumSets),
      .AddrW    (AddrW),
      .OffsW    (OffsW)
    ) u_filter (
      .clk_i       (clk_i),
      .rst_ni      (rst_ni),
      .upd_valid_i (dir_upd_i),
      .upd_set_i   (dir_set_i),
      .upd_way_i   (dir_way_i),
      .upd_tag_i   (dir_tag_i),
      .upd_inst_i  (dir_inst_i),
      .qry_addr_i  (win_addr),
      .qry_core_i  (inv_arb_idx),
      .held_o      (),
      .any_other_o (filt_from_mirror)
    );
  end else begin : g_no_filter
    assign filt_from_mirror = 1'b1;
  end

  // One driver, at module scope, so there is no doubt what this is when the
  // filter is not built.
  assign filt_any_other = SnoopFilter ? filt_from_mirror : 1'b1;

  // A store-conditional that lost its reservation performs no write, so it
  // needs no invalidation broadcast -- it is granted purely to release the
  // requesting DCU's stage 1.
  assign bcast_needed = inv_arb_valid && !(win_is_sc && !sc_excl_ok)
                        && filt_any_other
`ifdef ORACLE_NOBCAST
    // -------------------------------------------------------------------------
    //  MEASUREMENT INSTRUMENT. NOT A DESIGN. Never define this for a build.
    //
    //  An oracle snoop filter: assume no other cache holds the line, so send no
    //  broadcast and do not wait for the other DCUs to be ready to accept one.
    //  Arbitration and the write-busy lock are deliberately left alone -- the
    //  lock still has to stop a remote read fetching a pre-write value from
    //  memory, whoever is caching what.
    //
    //  This is only sound where no invalidation would have been useful, which
    //  results/invalidation_use.csv says is the case for every kernel here:
    //  1,048,821 broadcasts, none of which cleared a line. If a benchmark that
    //  passes without this define fails with it, that assumption was wrong for
    //  that benchmark, and the failure is the useful result.
    //
    //  It bounds what a real snoop filter could return before one is built.
    // -------------------------------------------------------------------------
    && 1'b0
`endif
    ;

  always @(*) begin
    others_ready = 1'b1;
    for (int unsigned c = 0; c < NumCores; c++) begin
      if (c != int'(inv_arb_idx) && !inv_ready_i[c]) others_ready = 1'b0;
    end
  end

  assign inv_gnt_valid = inv_arb_valid && (!bcast_needed || others_ready);

  // ---------------------------------------------------------------------------
  //  Invalidation Table -- INV REQs asserted but not granted
  // ---------------------------------------------------------------------------
  logic [NumCores-1:0]       tbl_valid;
  logic [NumCores*AddrW-1:0] tbl_addr;
  logic [NumCores-1:0]       inv_gnt_vec;

  assign inv_gnt_vec = inv_arb_gnt & {NumCores{inv_gnt_valid}};

  invalidation_table #(
    .NumCores (NumCores),
    .AddrW    (AddrW)
  ) u_inv_table (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .inv_req_i     (is_write),
    .inv_addr_i    (addr_i),
    .inv_gnt_i     (inv_gnt_vec),
    .entry_valid_o (tbl_valid),
    .entry_addr_o  (tbl_addr)
  );

  // ---------------------------------------------------------------------------
  //  READ REQ screening -- the Single-Writer half of the MRSW lock
  // ---------------------------------------------------------------------------
  logic [NumCores-1:0] read_blocked;

  always @(*) begin
    for (int unsigned r = 0; r < NumCores; r++) begin
      read_blocked[r] = 1'b0;
      for (int unsigned c = 0; c < NumCores; c++) begin
        if (c != r && tbl_valid[c] &&
            same_line(tbl_addr[c*AddrW +: AddrW], addr_i[r*AddrW +: AddrW])) begin
          read_blocked[r] = 1'b1;
        end
      end
      // an invalidation granted in this very cycle locks the line as well
      if (inv_gnt_valid && bcast_needed && (int'(inv_arb_idx) != r) &&
          same_line(win_addr, addr_i[r*AddrW +: AddrW])) begin
        read_blocked[r] = 1'b1;
      end
      // and the lock is only released once the write-through has actually
      // reached the shared memory, otherwise this read would fetch and cache
      // the pre-write value with no invalidation left to correct it
      for (int unsigned c = 0; c < NumCores; c++) begin
        if (c != r && wr_busy_i[c] &&
            same_line(wr_addr_i[c*AddrW +: AddrW], addr_i[r*AddrW +: AddrW])) begin
          read_blocked[r] = 1'b1;
        end
      end
    end
  end

`ifndef SYNTHESIS
  // ---------------------------------------------------------------------------
  //  Measurement only: how much of the read stall is false sharing?
  //
  //  Every screening condition above compares whole lines, so a reader is
  //  blocked by a writer that touches any word of the same 16-byte line --
  //  including a word it never reads. That is false sharing, and it is
  //  indistinguishable from true sharing in the cycle counters, which only know
  //  that a read waited.
  //
  //  This recomputes the identical three conditions at word granularity and
  //  counts the difference. A cycle counted in dbg_rd_false is a cycle a reader
  //  spent blocked by a writer it did not actually share a word with -- stall
  //  that a finer invalidation granularity would remove, and stall that the
  //  present design cannot.
  //
  //  Simulation only. It exists to size an opportunity, not to be synthesised,
  //  and it must not influence read_blocked.
  // ---------------------------------------------------------------------------
  function automatic logic same_word(input logic [AddrW-1:0] a,
                                     input logic [AddrW-1:0] b);
    return a[AddrW-1:2] == b[AddrW-1:2];
  endfunction

  logic [NumCores-1:0] read_blocked_word;

  always @(*) begin
    for (int unsigned r = 0; r < NumCores; r++) begin
      read_blocked_word[r] = 1'b0;
      for (int unsigned c = 0; c < NumCores; c++) begin
        if (c != r && tbl_valid[c] &&
            same_word(tbl_addr[c*AddrW +: AddrW], addr_i[r*AddrW +: AddrW])) begin
          read_blocked_word[r] = 1'b1;
        end
      end
      if (inv_gnt_valid && bcast_needed && (int'(inv_arb_idx) != r) &&
          same_word(win_addr, addr_i[r*AddrW +: AddrW])) begin
        read_blocked_word[r] = 1'b1;
      end
      for (int unsigned c = 0; c < NumCores; c++) begin
        if (c != r && wr_busy_i[c] &&
            same_word(wr_addr_i[c*AddrW +: AddrW], addr_i[r*AddrW +: AddrW])) begin
          read_blocked_word[r] = 1'b1;
        end
      end
    end
  end

  int unsigned dbg_rd_blocked;   // core-cycles a pending read was blocked
  int unsigned dbg_rd_false;     // of those, blocked only by line granularity

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dbg_rd_blocked <= 0;
      dbg_rd_false   <= 0;
    end else begin
      for (int unsigned r = 0; r < NumCores; r++) begin
        // Only count a core that actually has a read outstanding; a blocked
        // signal for a core that is not asking costs nobody anything.
        if (is_read[r] && read_blocked[r]) begin
          dbg_rd_blocked <= dbg_rd_blocked + 1;
          if (!read_blocked_word[r]) dbg_rd_false <= dbg_rd_false + 1;
        end
      end
    end
  end

  final begin
    if (dbg_rd_blocked != 0) begin
      $display(" FALSESHARE blocked=%0d false=%0d pct=%0.2f",
               dbg_rd_blocked, dbg_rd_false,
               100.0 * real'(dbg_rd_false) / real'(dbg_rd_blocked));
    end else begin
      $display(" FALSESHARE blocked=0 false=0 pct=0.00");
    end
  end
`endif

  // ---------------------------------------------------------------------------
  //  Arbiter 2 -- atomic LR READ REQs
  // ---------------------------------------------------------------------------
  logic [NumCores-1:0] lr_req;
  logic [NumCores-1:0] lr_arb_gnt;
  logic                lr_arb_valid;
  logic [CoreW-1:0]    lr_arb_idx;

  assign lr_req = is_lr & ~read_blocked;

  rr_arbiter #(.NumReq(NumCores)) u_lr_arb (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .req_i       (lr_req),
    .update_i    (lr_arb_valid),
    .gnt_o       (lr_arb_gnt),
    .gnt_valid_o (lr_arb_valid),
    .gnt_idx_o   (lr_arb_idx)
  );

  // ---------------------------------------------------------------------------
  //  Link Register
  // ---------------------------------------------------------------------------
  link_register #(
    .NumCores  (NumCores),
    .AddrW     (AddrW),
    .LineBytes (LineBytes)
  ) u_link_reg (
    .clk_i        (clk_i),
    .rst_ni       (rst_ni),
    .lr_set_i     (lr_arb_valid),
    .lr_core_i    (lr_arb_idx),
    .lr_addr_i    (addr_i[lr_arb_idx*AddrW +: AddrW]),
    .inv_set_i    (inv_gnt_valid && bcast_needed),
    .inv_addr_i   (win_addr),
    .sc_core_i    (inv_arb_idx),
    .sc_addr_i    (win_addr),
    .sc_excl_ok_o (sc_excl_ok),
    .sc_clear_i   (inv_gnt_valid && win_is_sc),
    .excl_bit_o   (/* unused */)
  );

  // ---------------------------------------------------------------------------
  //  Grants and broadcast
  // ---------------------------------------------------------------------------
  always @(*) begin
    for (int unsigned c = 0; c < NumCores; c++) begin
      if (is_write[c]) begin
        gnt_o[c] = inv_gnt_vec[c];
      end else if (is_read[c]) begin
        gnt_o[c] = !read_blocked[c] && (!is_lr[c] || lr_arb_gnt[c]);
      end else begin
        gnt_o[c] = 1'b0;
      end

      // Only the requesting core of an SC needs the exclusive answer, and it
      // samples it in the cycle its request is granted.
      excl_ok_o[c] = (int'(inv_arb_idx) == c) ? sc_excl_ok : 1'b0;
    end
  end

  always @(*) begin
    inv_valid_o = '0;
    inv_addr_o  = '0;
    for (int unsigned c = 0; c < NumCores; c++) begin
      if (inv_gnt_valid && bcast_needed && (int'(inv_arb_idx) != c)) begin
        inv_valid_o[c]                = 1'b1;
        inv_addr_o[c*AddrW +: AddrW]  = win_addr;
      end
    end
  end

endmodule
