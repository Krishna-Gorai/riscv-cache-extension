// =============================================================================
//  axi_xbar.sv -- the AXI crossbar of Fig. 1.
//
//  Section III-A: each PE's Instruction- and Data-Bridges provide "an AXI
//  compatible interface to the shared memory". This is the fabric they meet in,
//  and Table I lists it as its own resource line, which is why it is a real
//  crossbar rather than the round-robin arbiters that stood in for it in M5.
//
//  Supported subset of AXI4, and why:
//
//    * five independent channels, AW / W / B / AR / R, VALID-READY on each
//    * INCR bursts, which is what makes AXI4 rather than AXI4-Lite worth
//      having here: a DCU line fill is one burst of LineBytes/4 beats, so the
//      cache asks for a line in a single transaction instead of four
//    * WSTRB, so the cache's write-through of a single word into a wider line
//      is a byte-accurate partial write
//    * ID-based response routing
//
//  Deliberately left out, because nothing in this SoC uses them: AxCACHE,
//  AxPROT, AxQOS, AxREGION, AxLOCK, AxSIZE (every transfer is bus width) and
//  WRAP/FIXED bursts. They would be dead logic and would inflate the resource
//  figure that Table I is compared against.
//
//  Masters carry no ID of their own. The crossbar tags each transaction with
//  the master index on the way out and routes the response back by it, so the
//  master adapters stay simple.
//
//  Ordering rule: a master may have several transactions in flight, but only to
//  one slave at a time. A second slave is not accepted until the first has
//  drained. Slaves respond in order, so this is what keeps a master's responses
//  in order without any reorder buffer -- the same rule bridge_router uses.
// =============================================================================
// -----------------------------------------------------------------------------
//  Note on `always @(*)` rather than `always_comb`
//
//  These are equivalent for synthesis and infer the same combinational logic.
//  `always_comb` is the better style and is what this was written with, but
//  Icarus Verilog 12 derives its sensitivity list from every signal the block
//  *references*, including the ones it only writes. A block that clears a
//  vector and then conditionally sets part of it therefore schedules itself
//  again on its own writes, and the design stops settling within a timestep --
//  simulation time freezes with no error. `always @(*)` takes sensitivity from
//  reads alone and does not. Keeping the repository runnable on a free
//  simulator is worth the slightly weaker compile-time checking; xsim handles
//  either form.
// -----------------------------------------------------------------------------
module axi_xbar #(
  parameter  int unsigned NumMasters     = 12,
  parameter  int unsigned NumSlaves      = 3,
  parameter  int unsigned AddrW          = 32,
  parameter  int unsigned DataW          = 32,
  parameter  int unsigned LenW           = 8,
  parameter  int unsigned MaxOutstanding = 4,

  // Slave address map. A master's address selects slave s when
  // (addr & SlaveMask[s]) == SlaveBase[s]; flattened so the parameter stays
  // portable across tools.
  parameter  logic [NumSlaves*AddrW-1:0] SlaveBase = '0,
  parameter  logic [NumSlaves*AddrW-1:0] SlaveMask = '0,

  localparam int unsigned StrbW  = DataW/8,
  localparam int unsigned IdW    = (NumMasters <= 1) ? 1 : $clog2(NumMasters),
  localparam int unsigned SlvW   = (NumSlaves  <= 1) ? 1 : $clog2(NumSlaves),
  localparam int unsigned CntW   = $clog2(MaxOutstanding + 1)
) (
  input  logic clk_i,
  input  logic rst_ni,

  // ===========================================================================
  //  Master side -- one set per master, no IDs
  // ===========================================================================
  input  logic [NumMasters-1:0]        m_arvalid_i,
  output logic [NumMasters-1:0]        m_arready_o,
  input  logic [NumMasters*AddrW-1:0]  m_araddr_i,
  input  logic [NumMasters*LenW-1:0]   m_arlen_i,

  output logic [NumMasters-1:0]        m_rvalid_o,
  input  logic [NumMasters-1:0]        m_rready_i,
  output logic [NumMasters*DataW-1:0]  m_rdata_o,
  output logic [NumMasters*2-1:0]      m_rresp_o,
  output logic [NumMasters-1:0]        m_rlast_o,

  input  logic [NumMasters-1:0]        m_awvalid_i,
  output logic [NumMasters-1:0]        m_awready_o,
  input  logic [NumMasters*AddrW-1:0]  m_awaddr_i,
  input  logic [NumMasters*LenW-1:0]   m_awlen_i,

  input  logic [NumMasters-1:0]        m_wvalid_i,
  output logic [NumMasters-1:0]        m_wready_o,
  input  logic [NumMasters*DataW-1:0]  m_wdata_i,
  input  logic [NumMasters*StrbW-1:0]  m_wstrb_i,
  input  logic [NumMasters-1:0]        m_wlast_i,

  output logic [NumMasters-1:0]        m_bvalid_o,
  input  logic [NumMasters-1:0]        m_bready_i,
  output logic [NumMasters*2-1:0]      m_bresp_o,

  // ===========================================================================
  //  Slave side -- one set per slave, transactions carry the master index
  // ===========================================================================
  output logic [NumSlaves-1:0]         s_arvalid_o,
  input  logic [NumSlaves-1:0]         s_arready_i,
  output logic [NumSlaves*AddrW-1:0]   s_araddr_o,
  output logic [NumSlaves*LenW-1:0]    s_arlen_o,
  output logic [NumSlaves*IdW-1:0]     s_arid_o,

  input  logic [NumSlaves-1:0]         s_rvalid_i,
  output logic [NumSlaves-1:0]         s_rready_o,
  input  logic [NumSlaves*DataW-1:0]   s_rdata_i,
  input  logic [NumSlaves*2-1:0]       s_rresp_i,
  input  logic [NumSlaves-1:0]         s_rlast_i,
  input  logic [NumSlaves*IdW-1:0]     s_rid_i,

  output logic [NumSlaves-1:0]         s_awvalid_o,
  input  logic [NumSlaves-1:0]         s_awready_i,
  output logic [NumSlaves*AddrW-1:0]   s_awaddr_o,
  output logic [NumSlaves*LenW-1:0]    s_awlen_o,
  output logic [NumSlaves*IdW-1:0]     s_awid_o,

  output logic [NumSlaves-1:0]         s_wvalid_o,
  input  logic [NumSlaves-1:0]         s_wready_i,
  output logic [NumSlaves*DataW-1:0]   s_wdata_o,
  output logic [NumSlaves*StrbW-1:0]   s_wstrb_o,
  output logic [NumSlaves-1:0]         s_wlast_o,

  input  logic [NumSlaves-1:0]         s_bvalid_i,
  output logic [NumSlaves-1:0]         s_bready_o,
  input  logic [NumSlaves*2-1:0]       s_bresp_i,
  input  logic [NumSlaves*IdW-1:0]     s_bid_i
);

  localparam logic [1:0] RESP_OKAY   = 2'b00;
  localparam logic [1:0] RESP_DECERR = 2'b11;

  // ===========================================================================
  //  Address decode
  // ===========================================================================
  logic [NumSlaves-1:0] ar_hit [NumMasters];
  logic [NumSlaves-1:0] aw_hit [NumMasters];
  logic [SlvW-1:0]      ar_slv [NumMasters];
  logic [SlvW-1:0]      aw_slv [NumMasters];
  logic [NumMasters-1:0] ar_dec_ok, aw_dec_ok;

  //  Slaves are walked from the top down so that the lowest matching index is
  //  the one left standing. Nothing here reads a variable it also writes: an
  //  always @(*) that does can fail to settle, because a simulator is entitled
  //  to re-evaluate it on every assignment rather than only on a change.
  always @(*) begin
    for (int unsigned m = 0; m < NumMasters; m++) begin
      ar_hit[m]    = '0;
      aw_hit[m]    = '0;
      ar_slv[m]    = '0;
      aw_slv[m]    = '0;
      ar_dec_ok[m] = 1'b0;
      aw_dec_ok[m] = 1'b0;
      for (int s = int'(NumSlaves) - 1; s >= 0; s--) begin
        if ((m_araddr_i[m*AddrW +: AddrW] & SlaveMask[s*AddrW +: AddrW])
              == SlaveBase[s*AddrW +: AddrW]) begin
          ar_dec_ok[m] = 1'b1;
          ar_slv[m]    = SlvW'(s);
          ar_hit[m]    = '0;
          ar_hit[m][s] = 1'b1;
        end
        if ((m_awaddr_i[m*AddrW +: AddrW] & SlaveMask[s*AddrW +: AddrW])
              == SlaveBase[s*AddrW +: AddrW]) begin
          aw_dec_ok[m] = 1'b1;
          aw_slv[m]    = SlvW'(s);
          aw_hit[m]    = '0;
          aw_hit[m][s] = 1'b1;
        end
      end
    end
  end

  // ===========================================================================
  //  Per-master ordering trackers
  // ===========================================================================
  logic [SlvW-1:0] rd_tgt_q [NumMasters];
  logic [CntW-1:0] rd_cnt_q [NumMasters];
  logic [SlvW-1:0] wr_tgt_q [NumMasters];
  logic [CntW-1:0] wr_cnt_q [NumMasters];

  logic [NumMasters-1:0] rd_may_issue, wr_may_issue;

  always @(*) begin
    for (int unsigned m = 0; m < NumMasters; m++) begin
      rd_may_issue[m] = (rd_cnt_q[m] != CntW'(MaxOutstanding))
                        && ((rd_cnt_q[m] == '0) || (rd_tgt_q[m] == ar_slv[m]));
      wr_may_issue[m] = (wr_cnt_q[m] != CntW'(MaxOutstanding))
                        && ((wr_cnt_q[m] == '0) || (wr_tgt_q[m] == aw_slv[m]));
    end
  end

  // ===========================================================================
  //  AR: one round-robin arbiter per slave
  // ===========================================================================
  logic [IdW-1:0]        ar_ptr_q [NumSlaves];
  logic [NumSlaves-1:0]  ar_gnt_valid;
  logic [NumSlaves*IdW-1:0] ar_gnt_mst;

  //  One block per slave, each writing only its own scalars. Selecting inside
  //  a single always @(*) that indexed shared vectors by the loop variable did
  //  not settle: a bit-write through a variable index is a read-modify-write of
  //  the whole vector, which puts the block in its own sensitivity list.
  for (genvar s = 0; s < NumSlaves; s++) begin : g_ar_arb
    logic           gv;
    logic [IdW-1:0] gm;

    always @(*) begin
      gv = 1'b0;
      gm = '0;
      // walked backwards, so the master nearest the pointer wins the overwrite
      for (int i = int'(NumMasters) - 1; i >= 0; i--) begin
        if (m_arvalid_i  [(int'(ar_ptr_q[s]) + i) % NumMasters]
            && ar_dec_ok [(int'(ar_ptr_q[s]) + i) % NumMasters]
            && ar_hit    [(int'(ar_ptr_q[s]) + i) % NumMasters][s]
            && rd_may_issue[(int'(ar_ptr_q[s]) + i) % NumMasters]) begin
          gv = 1'b1;
          gm = IdW'((int'(ar_ptr_q[s]) + i) % NumMasters);
        end
      end
    end

    assign ar_gnt_valid[s]          = gv;
    assign ar_gnt_mst[s*IdW +: IdW] = gm;

    assign s_arvalid_o[s]               = gv;
    assign s_araddr_o[s*AddrW +: AddrW] = m_araddr_i[int'(gm)*AddrW +: AddrW];
    assign s_arlen_o [s*LenW  +: LenW]  = m_arlen_i [int'(gm)*LenW  +: LenW];
    assign s_arid_o  [s*IdW   +: IdW]   = gm;
  end

  // ===========================================================================
  //  AW: one round-robin arbiter per slave, and the W-channel lock
  // ===========================================================================
  //  AXI requires the W beats of a burst to reach a slave in AW order. Only one
  //  write is accepted per slave until its data phase finishes, which makes the
  //  ordering trivially correct; the writes here are single beats, so the cost
  //  is one cycle.
  logic [IdW-1:0]       aw_ptr_q  [NumSlaves];
  logic [NumSlaves-1:0] w_busy_q;
  logic [IdW-1:0]       w_owner_q [NumSlaves];

  logic [NumSlaves-1:0]     aw_gnt_valid;
  logic [NumSlaves*IdW-1:0] aw_gnt_mst;

  for (genvar s = 0; s < NumSlaves; s++) begin : g_aw_arb
    logic           gv;
    logic [IdW-1:0] gm;

    always @(*) begin
      gv = 1'b0;
      gm = '0;
      if (!w_busy_q[s]) begin
        for (int i = int'(NumMasters) - 1; i >= 0; i--) begin
          if (m_awvalid_i  [(int'(aw_ptr_q[s]) + i) % NumMasters]
              && aw_dec_ok [(int'(aw_ptr_q[s]) + i) % NumMasters]
              && aw_hit    [(int'(aw_ptr_q[s]) + i) % NumMasters][s]
              && wr_may_issue[(int'(aw_ptr_q[s]) + i) % NumMasters]) begin
            gv = 1'b1;
            gm = IdW'((int'(aw_ptr_q[s]) + i) % NumMasters);
          end
        end
      end
    end

    assign aw_gnt_valid[s]          = gv;
    assign aw_gnt_mst[s*IdW +: IdW] = gm;

    assign s_awvalid_o[s]               = gv;
    assign s_awaddr_o[s*AddrW +: AddrW] = m_awaddr_i[int'(gm)*AddrW +: AddrW];
    assign s_awlen_o [s*LenW  +: LenW]  = m_awlen_i [int'(gm)*LenW  +: LenW];
    assign s_awid_o  [s*IdW   +: IdW]   = gm;
  end

  // --- W: forwarded from whichever master holds the lock ----------------------
  for (genvar s = 0; s < NumSlaves; s++) begin : g_w_fwd
    assign s_wvalid_o[s]               = w_busy_q[s] && m_wvalid_i[w_owner_q[s]];
    assign s_wdata_o[s*DataW +: DataW] = m_wdata_i[int'(w_owner_q[s])*DataW +: DataW];
    assign s_wstrb_o[s*StrbW +: StrbW] = m_wstrb_i[int'(w_owner_q[s])*StrbW +: StrbW];
    assign s_wlast_o[s]                = w_busy_q[s] && m_wlast_i[w_owner_q[s]];
  end

  // ===========================================================================
  //  Decode-error responders
  // ===========================================================================
  //  An address that matches no slave is answered here with DECERR rather than
  //  left to hang. Nothing in this SoC should reach it -- the Data-Bridge
  //  absorbs unmapped accesses upstream -- but a fabric that silently stalls on
  //  a bad address is very hard to debug.
  logic [NumMasters-1:0] err_r_active_q;
  logic [LenW-1:0]       err_r_cnt_q [NumMasters];
  logic [NumMasters-1:0] err_b_pend_q;
  logic [NumMasters-1:0] err_w_active_q;

  // ===========================================================================
  //  Response routing back to the masters
  // ===========================================================================
  //  Again one block per master driving only scalars. At most one slave can be
  //  answering a given master, because a master is never allowed a second slave
  //  until the first has drained, so the inner loop can assign unconditionally.
  for (genvar m = 0; m < NumMasters; m++) begin : g_rrsp
    logic             rv, rl;
    logic [DataW-1:0] rd;
    logic [1:0]       rr;

    always @(*) begin
      rv = 1'b0;
      rl = 1'b0;
      rd = '0;
      rr = RESP_OKAY;
      if (err_r_active_q[m]) begin
        // a decode error is answered locally, one beat at a time
        rv = 1'b1;
        rr = RESP_DECERR;
        rl = (err_r_cnt_q[m] == '0);
      end else begin
        for (int unsigned s = 0; s < NumSlaves; s++) begin
          if (s_rvalid_i[s] && (s_rid_i[s*IdW +: IdW] == IdW'(m))) begin
            rv = 1'b1;
            rd = s_rdata_i[s*DataW +: DataW];
            rr = s_rresp_i[s*2 +: 2];
            rl = s_rlast_i[s];
          end
        end
      end
    end

    assign m_rvalid_o[m]               = rv;
    assign m_rlast_o[m]                = rl;
    assign m_rdata_o[m*DataW +: DataW] = rd;
    assign m_rresp_o[m*2 +: 2]         = rr;
  end

  for (genvar m = 0; m < NumMasters; m++) begin : g_brsp
    logic       bv;
    logic [1:0] br;

    always @(*) begin
      bv = 1'b0;
      br = RESP_OKAY;
      if (err_b_pend_q[m]) begin
        bv = 1'b1;
        br = RESP_DECERR;
      end else begin
        for (int unsigned s = 0; s < NumSlaves; s++) begin
          if (s_bvalid_i[s] && (s_bid_i[s*IdW +: IdW] == IdW'(m))) begin
            bv = 1'b1;
            br = s_bresp_i[s*2 +: 2];
          end
        end
      end
    end

    assign m_bvalid_o[m]       = bv;
    assign m_bresp_o[m*2 +: 2] = br;
  end

  //  The response carries the master index, so the ready can be routed with a
  //  direct index rather than a search.
  for (genvar s = 0; s < NumSlaves; s++) begin : g_srdy
    assign s_rready_o[s] = s_rvalid_i[s] && m_rready_i[s_rid_i[s*IdW +: IdW]]
                           && !err_r_active_q[s_rid_i[s*IdW +: IdW]];
    assign s_bready_o[s] = s_bvalid_i[s] && m_bready_i[s_bid_i[s*IdW +: IdW]]
                           && !err_b_pend_q[s_bid_i[s*IdW +: IdW]];
  end

  // ===========================================================================
  //  Master-side handshakes
  // ===========================================================================
  //  One block per master, each driving only its own scalars. Writing a shared
  //  ready vector twice -- once at the loop index and once at an index carried
  //  in a signal -- is a read-modify-write of the whole vector, which puts the
  //  block into its own sensitivity list and leaves it unable to settle.
  for (genvar m = 0; m < NumMasters; m++) begin : g_mready
    logic arr, awr, wrr;

    always @(*) begin
      arr = 1'b0;
      awr = 1'b0;
      wrr = 1'b0;

      //  A mis-decoded access is only taken once the master's real traffic has
      //  drained, so the local error responder and a slave can never be
      //  answering the same master at the same time.
      if (!ar_dec_ok[m]) begin
        arr = !err_r_active_q[m] && (rd_cnt_q[m] == '0);
      end else begin
        for (int unsigned s = 0; s < NumSlaves; s++) begin
          if (ar_gnt_valid[s] && (ar_gnt_mst[s*IdW +: IdW] == IdW'(m))
              && s_arready_i[s]) arr = 1'b1;
        end
      end

      if (!aw_dec_ok[m]) begin
        awr = !err_w_active_q[m] && !err_b_pend_q[m] && (wr_cnt_q[m] == '0);
      end else begin
        for (int unsigned s = 0; s < NumSlaves; s++) begin
          if (aw_gnt_valid[s] && (aw_gnt_mst[s*IdW +: IdW] == IdW'(m))
              && s_awready_i[s]) awr = 1'b1;
        end
      end

      if (err_w_active_q[m]) begin
        wrr = 1'b1;                       // a mis-decoded write's data is swallowed
      end else begin
        for (int unsigned s = 0; s < NumSlaves; s++) begin
          if (w_busy_q[s] && (w_owner_q[s] == IdW'(m)) && s_wready_i[s]) wrr = 1'b1;
        end
      end
    end

    assign m_arready_o[m] = arr;
    assign m_awready_o[m] = awr;
    assign m_wready_o[m]  = wrr;
  end

  // ===========================================================================
  //  State
  // ===========================================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned s = 0; s < NumSlaves; s++) begin
        ar_ptr_q[s]  <= '0;
        aw_ptr_q[s]  <= '0;
        w_owner_q[s] <= '0;
      end
      w_busy_q <= '0;
      for (int unsigned m = 0; m < NumMasters; m++) begin
        rd_tgt_q[m]    <= '0;
        rd_cnt_q[m]    <= '0;
        wr_tgt_q[m]    <= '0;
        wr_cnt_q[m]    <= '0;
        err_r_cnt_q[m] <= '0;
      end
      err_r_active_q <= '0;
      err_b_pend_q   <= '0;
      err_w_active_q <= '0;
    end else begin
      // --- AR arbitration pointers and the read tracker ---------------------
      for (int unsigned s = 0; s < NumSlaves; s++) begin
        if (ar_gnt_valid[s] && s_arready_i[s]) begin
          ar_ptr_q[s] <= IdW'((int'(ar_gnt_mst[s*IdW +: IdW]) + 1) % NumMasters);
          rd_tgt_q[ar_gnt_mst[s*IdW +: IdW]] <= SlvW'(s);
          rd_cnt_q[ar_gnt_mst[s*IdW +: IdW]] <=
              rd_cnt_q[ar_gnt_mst[s*IdW +: IdW]] + CntW'(1);
        end
        if (aw_gnt_valid[s] && s_awready_i[s]) begin
          aw_ptr_q[s] <= IdW'((int'(aw_gnt_mst[s*IdW +: IdW]) + 1) % NumMasters);
          wr_tgt_q[aw_gnt_mst[s*IdW +: IdW]] <= SlvW'(s);
          wr_cnt_q[aw_gnt_mst[s*IdW +: IdW]] <=
              wr_cnt_q[aw_gnt_mst[s*IdW +: IdW]] + CntW'(1);
          w_busy_q[s]  <= 1'b1;
          w_owner_q[s] <= aw_gnt_mst[s*IdW +: IdW];
        end
        // the data phase ends on WLAST
        if (w_busy_q[s] && s_wvalid_o[s] && s_wready_i[s] && s_wlast_o[s]) begin
          w_busy_q[s] <= 1'b0;
        end
      end

      // --- retire responses --------------------------------------------------
      for (int unsigned m = 0; m < NumMasters; m++) begin
        if (m_rvalid_o[m] && m_rready_i[m] && m_rlast_o[m] && !err_r_active_q[m]) begin
          rd_cnt_q[m] <= rd_cnt_q[m] - CntW'(1);
        end
        if (m_bvalid_o[m] && m_bready_i[m] && !err_b_pend_q[m]) begin
          wr_cnt_q[m] <= wr_cnt_q[m] - CntW'(1);
        end
      end

      // --- decode-error responders ------------------------------------------
      for (int unsigned m = 0; m < NumMasters; m++) begin
        // reads
        if (!err_r_active_q[m]) begin
          if (m_arvalid_i[m] && !ar_dec_ok[m] && m_arready_o[m]) begin
            err_r_active_q[m] <= 1'b1;
            err_r_cnt_q[m]    <= m_arlen_i[m*LenW +: LenW];
          end
        end else if (m_rready_i[m]) begin
          if (err_r_cnt_q[m] == '0) err_r_active_q[m] <= 1'b0;
          else                      err_r_cnt_q[m]    <= err_r_cnt_q[m] - LenW'(1);
        end

        // writes: swallow the data phase, then answer with DECERR
        if (!err_w_active_q[m] && !err_b_pend_q[m]) begin
          if (m_awvalid_i[m] && !aw_dec_ok[m] && m_awready_o[m]) begin
            err_w_active_q[m] <= 1'b1;
          end
        end else if (err_w_active_q[m]) begin
          if (m_wvalid_i[m] && m_wlast_i[m]) begin
            err_w_active_q[m] <= 1'b0;
            err_b_pend_q[m]   <= 1'b1;
          end
        end else if (err_b_pend_q[m] && m_bready_i[m]) begin
          err_b_pend_q[m] <= 1'b0;
        end
      end
    end
  end

`ifndef SYNTHESIS
  // A response that matches no master would be dropped silently, so say so.
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      for (int unsigned s = 0; s < NumSlaves; s++) begin
        // Compared as integers: IdW'(NumMasters) would truncate, and for a
        // power-of-two master count it truncates to zero, which would make the
        // test fire on every legal response.
        if (s_rvalid_i[s] && (32'(s_rid_i[s*IdW +: IdW]) >= 32'(NumMasters)))
          $error("axi_xbar: slave %0d returned R for unknown master id %0d",
                 s, s_rid_i[s*IdW +: IdW]);
        if (s_bvalid_i[s] && (32'(s_bid_i[s*IdW +: IdW]) >= 32'(NumMasters)))
          $error("axi_xbar: slave %0d returned B for unknown master id %0d",
                 s, s_bid_i[s*IdW +: IdW]);
      end
    end
  end
`endif

endmodule
