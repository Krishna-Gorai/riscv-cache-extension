// =============================================================================
//  dcu.sv -- Data Cache Unit (DCU)
//
//  Private L1 data cache of one RISC-V Processing Element, per Section III-B
//  and Fig. 2b of:
//    A. Kamaleldin, M. Nickel, S. Wu, D. Goehringer, "Seamless Cache Extension
//    for FPGA-based Multi-Core RISC-V SoC", IEEE SOCC 2024.
//
//  Organisation
//    - NumWays-way set associative (paper: 2-way), configurable line width and
//      set count.
//    - Write-through, no-allocate  (Section III-B).
//    - 1-bit LRU entry per set     (Section III-B, "LRU-table").
//    - Two sequential pipeline stages:
//        stage 1 : address the Tag-RAM / Data-RAM and forward the request to
//                  the snoopy bus (READ REQ, or INV REQ for a core write).
//        stage 2 : Hit Check Logic (HCL) result drives the Cache Control Logic
//                  (CCL), which serves the core, the shared data memory and
//                  the cache arrays.
//    - Stall Control Logic (SCL) implements the stall conditions of both
//      stages from Section III-B-a.
//
//  Deviations from the paper, documented in docs/architecture.md
//    - The Status-RAM (valid bits) and the LRU table are flip-flop arrays
//      rather than RAM macros. They are small (NumSets*NumWays bits) and this
//      removes a stale-valid-bit hazard between the two stages, since stage 2
//      always observes the current valid bit.
// =============================================================================
module dcu
  import cache_pkg::*;
#(
  parameter  int unsigned NumWays      = 2,
  parameter  int unsigned NumSets      = 64,
  parameter  int unsigned LineBytes    = 16,
  parameter  int unsigned AddrW        = 32,
  parameter  int unsigned DataW        = 32,

  localparam int unsigned WordBytes    = DataW / 8,
  localparam int unsigned WordsPerLine = LineBytes / WordBytes,
  localparam int unsigned LineBits     = LineBytes * 8,
  localparam int unsigned OffsW        = $clog2(LineBytes),
  localparam int unsigned WordSelW     = (WordsPerLine <= 1) ? 1 : $clog2(WordsPerLine),
  localparam int unsigned ByteOffW     = $clog2(WordBytes),
  localparam int unsigned IdxW         = $clog2(NumSets),
  localparam int unsigned TagW         = AddrW - IdxW - OffsW,
  localparam int unsigned WayW         = (NumWays <= 1) ? 1 : $clog2(NumWays),
  localparam int unsigned DGran        = NumWays * WordsPerLine
) (
  input  logic                  clk_i,
  input  logic                  rst_ni,

  // ---------------------------------------------------------------------------
  // Core D-Port (Fig. 2c) -- request / grant address phase, rvalid data phase.
  // ---------------------------------------------------------------------------
  input  logic                  core_req_i,
  output logic                  core_gnt_o,
  input  logic [AddrW-1:0]      core_addr_i,
  input  logic                  core_we_i,
  input  logic [WordBytes-1:0]  core_be_i,
  input  logic [DataW-1:0]      core_wdata_i,
  input  amo_e                  core_amo_i,
  output logic                  core_rvalid_o,
  output logic [DataW-1:0]      core_rdata_o,
  output logic                  core_sc_ok_o,

  // ---------------------------------------------------------------------------
  // Snoopy Bus Port (Fig. 4)
  //   outgoing : stage 1 forwards a READ REQ, or an INV REQ for a core write
  //   incoming : invalidation broadcast originating from another PE
  // ---------------------------------------------------------------------------
  output logic                  snp_req_o,
  output logic                  snp_is_inv_o,   // 1 = INV REQ, 0 = READ REQ
  output logic [AddrW-1:0]      snp_addr_o,
  output amo_e                  snp_amo_o,
  input  logic                  snp_gnt_i,
  input  logic                  snp_excl_ok_i,  // SC: reservation still held

  // Write-through still in flight towards the shared memory. The snoopy bus
  // holds the MRSW lock on this line until the write has actually landed:
  // granting the INV REQ alone is not enough, because a remote read granted in
  // between would fetch the pre-write value from memory and cache it, and no
  // further invalidation would ever be sent for it.
  output logic                  snp_wr_busy_o,
  output logic [AddrW-1:0]      snp_wr_addr_o,

  input  logic                  snp_inv_valid_i,
  input  logic [AddrW-1:0]      snp_inv_addr_i,
  output logic                  snp_inv_ready_o,

  // ---------------------------------------------------------------------------
  // Shared data memory port (reaches the AXI crossbar through the D-AXI Port)
  // ---------------------------------------------------------------------------
  output logic                  mem_rd_req_o,
  output logic [AddrW-1:0]      mem_rd_addr_o,   // line aligned
  input  logic                  mem_rd_gnt_i,
  input  logic                  mem_rd_rvalid_i,
  input  logic [LineBits-1:0]   mem_rd_rdata_i,

  output logic                  mem_wr_req_o,
  output logic [AddrW-1:0]      mem_wr_addr_o,
  output logic [WordBytes-1:0]  mem_wr_be_o,
  output logic [DataW-1:0]      mem_wr_wdata_o,
  input  logic                  mem_wr_gnt_i,

  // ---------------------------------------------------------------------------
  // Hardware performance counters (Section IV-B: the hit rate is measured by a
  // counter implemented inside the data cache unit).
  // ---------------------------------------------------------------------------
  output logic [31:0]           perf_rd_hit_o,
  output logic [31:0]           perf_rd_miss_o,
  output logic [31:0]           perf_wr_hit_o,
  output logic [31:0]           perf_wr_miss_o
);

  // ---------------------------------------------------------------------------
  // Address decomposition
  // ---------------------------------------------------------------------------
  function automatic logic [IdxW-1:0]     idx_of (input logic [AddrW-1:0] a);
    return a[OffsW +: IdxW];
  endfunction
  function automatic logic [TagW-1:0]     tag_of (input logic [AddrW-1:0] a);
    return a[AddrW-1 -: TagW];
  endfunction
  function automatic logic [WordSelW-1:0] word_of(input logic [AddrW-1:0] a);
    return (WordsPerLine <= 1) ? '0 : a[ByteOffW +: WordSelW];
  endfunction

  // ===========================================================================
  //  Cache arrays
  // ===========================================================================
  logic [NumWays-1:0]           valid_q [NumSets];   // Status-RAM
  logic                         lru_q   [NumSets];   // LRU-table, 1 bit / set

  logic [IdxW-1:0]              ram_raddr;
  logic [IdxW-1:0]              ram_waddr;

  logic [NumWays*TagW-1:0]      tag_rdata;
  logic [NumWays-1:0]           tag_we;
  logic [NumWays*TagW-1:0]      tag_wdata;

  logic [DGran*DataW-1:0]       dat_rdata;
  logic [DGran-1:0]             dat_we;
  logic [DGran*DataW-1:0]       dat_wdata;

  cache_ram #(
    .Depth    (NumSets),
    .Width    (TagW),
    .Granules (NumWays)
  ) u_tag_ram (
    .clk_i   (clk_i),
    .raddr_i (ram_raddr),
    .rdata_o (tag_rdata),
    .waddr_i (ram_waddr),
    .we_i    (tag_we),
    .wdata_i (tag_wdata)
  );

  cache_ram #(
    .Depth    (NumSets),
    .Width    (DataW),
    .Granules (DGran)
  ) u_data_ram (
    .clk_i   (clk_i),
    .raddr_i (ram_raddr),
    .rdata_o (dat_rdata),
    .waddr_i (ram_waddr),
    .we_i    (dat_we),
    .wdata_i (dat_wdata)
  );

  // ===========================================================================
  //  Stage 1 -- Request Management, array lookup, snoopy bus forwarding
  // ===========================================================================
  logic                 s1_valid_q;
  req_e                 s1_req_q;
  logic [AddrW-1:0]     s1_addr_q;
  logic [DataW-1:0]     s1_wdata_q;
  logic [WordBytes-1:0] s1_be_q;
  amo_e                 s1_amo_q;

  logic                 s2_valid_q;
  req_e                 s2_req_q;
  logic [AddrW-1:0]     s2_addr_q;
  logic [DataW-1:0]     s2_wdata_q;
  logic [WordBytes-1:0] s2_be_q;
  amo_e                 s2_amo_q;
  logic                 s2_excl_ok_q;

  logic s1_ready, s1_advance, s1_snoop_ok;
  logic s2_ready, s2_done;

  // --- Request Management ----------------------------------------------------
  //  The snoopy bus outranks the local core, and an incoming INV REQ may also
  //  *preempt* a core request that is still waiting for its own snoopy bus
  //  grant. Without that, a core stalled on a grant could never accept the
  //  broadcast, while the bus withholds the grant until the broadcast is
  //  accepted -- the two would deadlock. This is the hardware reading of the
  //  stage-1 stall condition "the INV REQ is not granted before the READ REQ":
  //  a local request that the bus has not acknowledged yet has had no effect
  //  anywhere, so it can be set aside in a holding slot and re-presented.
  //
  //  snp_inv_ready_o is deliberately a function of registered state only. It
  //  must not depend on snp_gnt_i, because the bus qualifies its grant with the
  //  readiness of every other DCU -- a combinational path from grant to ready
  //  would close a loop across the cluster.
  logic                 hold_valid_q;
  req_e                 hold_req_q;
  logic [AddrW-1:0]     hold_addr_q;
  logic [DataW-1:0]     hold_wdata_q;
  logic [WordBytes-1:0] hold_be_q;
  amo_e                 hold_amo_q;

  logic take_snoop, take_hold, take_core, do_preempt;

  assign snp_inv_ready_o = !s1_valid_q || ((s1_req_q != REQ_INV) && !hold_valid_q);

  assign take_snoop = snp_inv_valid_i && snp_inv_ready_o;
  assign take_hold  = !take_snoop && hold_valid_q && s1_ready;
  assign take_core  = !take_snoop && !hold_valid_q && core_req_i && s1_ready;
  assign do_preempt = take_snoop && s1_valid_q && !s1_advance;

  assign core_gnt_o = take_core;

  // --- Snoopy bus forwarding (stage 1). A core READ REQ is forwarded so the
  //     bus can screen it against the Invalidation Table and allocate the Link
  //     Register for an LR; a core WRITE REQ is forwarded as an INV REQ.
  assign snp_req_o    = s1_valid_q && (s1_req_q != REQ_INV) && (s1_req_q != REQ_NONE);
  assign snp_is_inv_o = (s1_req_q == REQ_WRITE);
  assign snp_addr_o   = s1_addr_q;
  assign snp_amo_o    = s1_amo_q;

  // --- SCL, stage 1 stall conditions (Section III-B-a):
  //       * the INV REQ to the snoopy bus is not granted yet
  //       * the INV REQ is not granted before the READ REQ  (this stage is
  //         in-order, and the bus withholds the grant of a READ that collides
  //         with a pending entry of the Invalidation Table)
  //       * the second stage stalls
  //     "the local core is not ready to receive a response" is covered by the
  //     core not issuing a new request while its response is outstanding.
  assign s1_snoop_ok = (s1_req_q == REQ_INV) ? 1'b1 : snp_gnt_i;
  assign s1_advance  = s1_valid_q && s1_snoop_ok && s2_ready;
  assign s1_ready    = !s1_valid_q || s1_advance;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s1_valid_q   <= 1'b0;
      s1_req_q     <= REQ_NONE;
      s1_addr_q    <= '0;
      s1_wdata_q   <= '0;
      s1_be_q      <= '0;
      s1_amo_q     <= AMO_NONE;
      hold_valid_q <= 1'b0;
      hold_req_q   <= REQ_NONE;
      hold_addr_q  <= '0;
      hold_wdata_q <= '0;
      hold_be_q    <= '0;
      hold_amo_q   <= AMO_NONE;
    end else begin
      if (do_preempt) begin
        hold_valid_q <= 1'b1;
        hold_req_q   <= s1_req_q;
        hold_addr_q  <= s1_addr_q;
        hold_wdata_q <= s1_wdata_q;
        hold_be_q    <= s1_be_q;
        hold_amo_q   <= s1_amo_q;
      end else if (take_hold) begin
        hold_valid_q <= 1'b0;
      end

      if (take_snoop) begin
        s1_valid_q <= 1'b1;
        s1_req_q   <= REQ_INV;
        s1_addr_q  <= snp_inv_addr_i;
        s1_amo_q   <= AMO_NONE;
      end else if (take_hold) begin
        s1_valid_q <= 1'b1;
        s1_req_q   <= hold_req_q;
        s1_addr_q  <= hold_addr_q;
        s1_wdata_q <= hold_wdata_q;
        s1_be_q    <= hold_be_q;
        s1_amo_q   <= hold_amo_q;
      end else if (take_core) begin
        s1_valid_q <= 1'b1;
        s1_req_q   <= core_we_i ? REQ_WRITE : REQ_READ;
        s1_addr_q  <= core_addr_i;
        s1_wdata_q <= core_wdata_i;
        s1_be_q    <= core_be_i;
        s1_amo_q   <= core_amo_i;
      end else if (s1_advance) begin
        s1_valid_q <= 1'b0;
        s1_req_q   <= REQ_NONE;
      end
    end
  end

  // Both stages share the single read port of the Tag-RAM / Data-RAM, so the
  // address has to follow whichever stage still needs its lookup result:
  //   * while stage 2 is stalled it keeps re-issuing its own read, otherwise
  //     stage 1 would steer the shared port at a different set and stage 2
  //     would evaluate the HCL against a foreign set;
  //   * in the cycle stage 2 retires, the port belongs to stage 1 again, whose
  //     request advances on that same edge and needs its data one cycle later.
  assign ram_raddr = (s2_valid_q && !s2_done) ? idx_of(s2_addr_q)
                                              : idx_of(s1_addr_q);

  // ===========================================================================
  //  Stage 2 -- HCL + CCL
  // ===========================================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s2_valid_q   <= 1'b0;
      s2_req_q     <= REQ_NONE;
      s2_addr_q    <= '0;
      s2_wdata_q   <= '0;
      s2_be_q      <= '0;
      s2_amo_q     <= AMO_NONE;
      s2_excl_ok_q <= 1'b0;
    end else if (s2_ready) begin
      s2_valid_q   <= s1_advance;
      s2_req_q     <= s1_req_q;
      s2_addr_q    <= s1_addr_q;
      s2_wdata_q   <= s1_wdata_q;
      s2_be_q      <= s1_be_q;
      s2_amo_q     <= s1_amo_q;
      s2_excl_ok_q <= snp_excl_ok_i;
    end
  end

  logic [IdxW-1:0]     s2_idx;
  logic [TagW-1:0]     s2_tag;
  logic [WordSelW-1:0] s2_wsel;

  assign s2_idx  = idx_of (s2_addr_q);
  assign s2_tag  = tag_of (s2_addr_q);
  assign s2_wsel = word_of(s2_addr_q);

  logic               hit;
  logic [WayW-1:0]    hit_way;
  logic [NumWays-1:0] hit_vec;

  dcu_hcl #(
    .NumWays (NumWays),
    .TagW    (TagW)
  ) u_hcl (
    .tags_i    (tag_rdata),
    .valid_i   (valid_q[s2_idx]),
    .tag_i     (s2_tag),
    .hit_o     (hit),
    .hit_way_o (hit_way),
    .hit_vec_o (hit_vec)
  );

  // --- Victim selection: fill an invalid way first, otherwise the LRU way.
  logic [WayW-1:0] victim_way;
  always_comb begin
    victim_way = WayW'(lru_q[s2_idx]);
    for (int unsigned w = NumWays; w > 0; w--) begin
      if (!valid_q[s2_idx][w-1]) victim_way = WayW'(w-1);
    end
  end

  // ---------------------------------------------------------------------------
  //  CCL -- Cache Control Logic
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    CCL_IDLE,
    CCL_RD_WAIT,   // MEM READ REQ issued, waiting for grant / MEM RESP
    CCL_WR_WAIT    // MEM WRITE REQ issued, waiting for grant
  } ccl_e;

  ccl_e ccl_q, ccl_d;
  logic rd_gnt_q;          // MEM READ REQ already accepted by the memory
  logic inv_pending_q;     // special case 2 of Section III-B

  // Special case 2: an INV REQ that targets the line currently being refilled
  // arrives before the MEM RESP. It is recorded as a flag; the data is then
  // forwarded to the core without updating the cache line.
  logic inflight_inv_match;
  assign inflight_inv_match = snp_inv_valid_i &&
        (snp_inv_addr_i[AddrW-1:OffsW] == s2_addr_q[AddrW-1:OffsW]);

  // A store-conditional whose reservation was lost performs no memory write.
  logic sc_fail;
  assign sc_fail = (s2_req_q == REQ_WRITE) && (s2_amo_q == AMO_SC) && !s2_excl_ok_q;

  logic fill_en;   // refill the victim way this cycle
  logic wr_hit_en; // update a word of the hit way this cycle

  always_comb begin
    ccl_d        = ccl_q;
    s2_done      = 1'b0;
    fill_en      = 1'b0;
    wr_hit_en    = 1'b0;

    mem_rd_req_o = 1'b0;
    mem_wr_req_o = 1'b0;

    unique case (ccl_q)
      CCL_IDLE: begin
        if (s2_valid_q) begin
          unique case (s2_req_q)
            // ----------------------------------------------- Fig. 3c: INV REQ
            REQ_INV: begin
              s2_done = 1'b1;               // never touches the shared memory
            end
            // ---------------------------------------------- Fig. 3a: READ REQ
            REQ_READ: begin
              if (hit) s2_done = 1'b1;
              else     ccl_d   = CCL_RD_WAIT;
            end
            // --------------------------------------------- Fig. 3b: WRITE REQ
            REQ_WRITE: begin
              if (sc_fail) s2_done = 1'b1;  // reservation lost, store dropped
              else         ccl_d   = CCL_WR_WAIT;
            end
            default: s2_done = 1'b1;
          endcase
        end
      end

      CCL_RD_WAIT: begin
        mem_rd_req_o = !rd_gnt_q;
        if (mem_rd_rvalid_i) begin
          // Refill unless the line was invalidated while the read was in flight.
          fill_en = !inv_pending_q && !inflight_inv_match;
          s2_done = 1'b1;
          ccl_d   = CCL_IDLE;
        end
      end

      CCL_WR_WAIT: begin
        mem_wr_req_o = 1'b1;
        if (mem_wr_gnt_i) begin
          wr_hit_en = hit;                  // write-through, no-allocate
          s2_done   = 1'b1;
          ccl_d     = CCL_IDLE;
        end
      end

      default: ccl_d = CCL_IDLE;
    endcase
  end

  // --- SCL, stage 2 stall conditions (Section III-B-a):
  //       * wait for the MEM WRITE REQ to be granted
  //       * wait for the MEM RESP of a MEM READ REQ
  assign s2_ready = !s2_valid_q || s2_done;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ccl_q         <= CCL_IDLE;
      rd_gnt_q      <= 1'b0;
      inv_pending_q <= 1'b0;
    end else begin
      ccl_q <= ccl_d;

      if (ccl_q == CCL_RD_WAIT) begin
        if (mem_rd_req_o && mem_rd_gnt_i) rd_gnt_q      <= 1'b1;
        if (inflight_inv_match)           inv_pending_q <= 1'b1;
        if (s2_done) begin
          rd_gnt_q      <= 1'b0;
          inv_pending_q <= 1'b0;
        end
      end else begin
        rd_gnt_q      <= 1'b0;
        inv_pending_q <= 1'b0;
      end
    end
  end

  // The MRSW lock stays asserted for as long as this write occupies stage 2,
  // which spans the CCL_IDLE cycle that launches it and every CCL_WR_WAIT
  // cycle until the shared memory grants it.
  assign snp_wr_busy_o = s2_valid_q && (s2_req_q == REQ_WRITE) && !sc_fail;
  assign snp_wr_addr_o = s2_addr_q;

  assign mem_rd_addr_o  = {s2_addr_q[AddrW-1:OffsW], {OffsW{1'b0}}};
  assign mem_wr_addr_o  = s2_addr_q;
  assign mem_wr_be_o    = s2_be_q;
  assign mem_wr_wdata_o = s2_wdata_q;

  // ===========================================================================
  //  Array updates
  // ===========================================================================
  logic [DataW-1:0] hit_word;
  logic [DataW-1:0] fill_word;
  logic [DataW-1:0] merged_word;

  assign hit_word  = dat_rdata[(hit_way*WordsPerLine + s2_wsel)*DataW +: DataW];
  assign fill_word = mem_rd_rdata_i[s2_wsel*DataW +: DataW];

  always_comb begin
    for (int unsigned b = 0; b < WordBytes; b++) begin
      merged_word[b*8 +: 8] = s2_be_q[b] ? s2_wdata_q[b*8 +: 8]
                                         : hit_word  [b*8 +: 8];
    end
  end

  assign ram_waddr = s2_idx;

  always_comb begin
    tag_we    = '0;
    tag_wdata = {NumWays{s2_tag}};
    if (fill_en) tag_we[victim_way] = 1'b1;
  end

  always_comb begin
    dat_we    = '0;
    dat_wdata = '0;
    if (fill_en) begin
      for (int unsigned j = 0; j < WordsPerLine; j++) begin
        dat_we[victim_way*WordsPerLine + j] = 1'b1;
        dat_wdata[(victim_way*WordsPerLine + j)*DataW +: DataW] =
            mem_rd_rdata_i[j*DataW +: DataW];
      end
    end else if (wr_hit_en) begin
      dat_we[hit_way*WordsPerLine + s2_wsel] = 1'b1;
      dat_wdata[(hit_way*WordsPerLine + s2_wsel)*DataW +: DataW] = merged_word;
    end
  end

  // --- Status-RAM (valid bits) and LRU-table
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned s = 0; s < NumSets; s++) begin
        valid_q[s] <= '0;
        lru_q[s]   <= 1'b0;
      end
    end else begin
      // invalidation (Fig. 3c) -- clear the matching way
      if (s2_valid_q && (s2_req_q == REQ_INV) && hit) begin
        valid_q[s2_idx][hit_way] <= 1'b0;
      end
      // refill -- validate the victim way and mark it most recently used
      if (fill_en) begin
        valid_q[s2_idx][victim_way] <= 1'b1;
        lru_q[s2_idx]               <= ~victim_way[0];
      end
      // hit on a core access -- mark the hit way most recently used
      if (s2_valid_q && (s2_req_q != REQ_INV) && hit && s2_done) begin
        lru_q[s2_idx] <= ~hit_way[0];
      end
    end
  end

  // ===========================================================================
  //  Core response
  // ===========================================================================
  assign core_rvalid_o = s2_valid_q && s2_done && (s2_req_q != REQ_INV);
  assign core_rdata_o  = (s2_req_q == REQ_READ) ? (hit ? hit_word : fill_word)
                                                : '0;
  assign core_sc_ok_o  = (s2_amo_q == AMO_SC) && !sc_fail;

  // ===========================================================================
  //  Performance counters (Section IV-B)
  // ===========================================================================
  logic retire_read, retire_write;
  assign retire_read  = s2_valid_q && s2_done && (s2_req_q == REQ_READ);
  assign retire_write = s2_valid_q && s2_done && (s2_req_q == REQ_WRITE) && !sc_fail;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      perf_rd_hit_o  <= '0;
      perf_rd_miss_o <= '0;
      perf_wr_hit_o  <= '0;
      perf_wr_miss_o <= '0;
    end else begin
      if (retire_read  &&  hit) perf_rd_hit_o  <= perf_rd_hit_o  + 1;
      if (retire_read  && !hit) perf_rd_miss_o <= perf_rd_miss_o + 1;
      if (retire_write &&  hit) perf_wr_hit_o  <= perf_wr_hit_o  + 1;
      if (retire_write && !hit) perf_wr_miss_o <= perf_wr_miss_o + 1;
    end
  end

endmodule
