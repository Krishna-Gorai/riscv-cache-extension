// =============================================================================
//  shared_data_mem.sv -- shared data memory behind the interconnect (Fig. 1).
//
//  The same physical scratchpad serves both architectures the paper compares in
//  Section IV-A: in the coherent SoC every port belongs to a private DCU and
//  asks for whole cache lines, in the non-coherent SoC every port belongs to a
//  PE with no data cache and asks for single words.
//
//  It is dual ported, as the paper's shared memories are: one read server and
//  one write server, each issuing one word access per cycle. A line read
//  therefore occupies the read port for LineBytes/WordBytes cycles, which is
//  exactly the bandwidth a cache miss spends to buy the reuse back. Accesses
//  stay pipelined, so several PEs contend for bandwidth rather than serialising
//  on the full round-trip latency.
// =============================================================================
module shared_data_mem #(
  parameter  int unsigned NumPorts  = 4,
  parameter  int unsigned AddrW     = 32,
  parameter  int unsigned DataW     = 32,
  parameter  int unsigned LineBytes = 16,
  parameter  int unsigned SizeBytes = 262144,
  parameter  int unsigned AccessLat = 2,      // array latency of one word access
  parameter  string       InitFile  = "",

  localparam int unsigned WordBytes    = DataW / 8,
  localparam int unsigned WordsPerLine = LineBytes / WordBytes,
  localparam int unsigned LineBits     = LineBytes * 8,
  localparam int unsigned NumWords     = SizeBytes / WordBytes,
  localparam int unsigned ByteOffW     = $clog2(WordBytes),
  localparam int unsigned IdxW         = $clog2(NumWords),
  localparam int unsigned LaneW        = $clog2(WordsPerLine),
  localparam int unsigned CntW         = LaneW + 1,
  localparam int unsigned PortW        = (NumPorts <= 1) ? 1 : $clog2(NumPorts)
) (
  input  logic                          clk_i,
  input  logic                          rst_ni,

  // --- read ports ------------------------------------------------------------
  input  logic [NumPorts-1:0]           rd_req_i,
  input  logic [NumPorts*AddrW-1:0]     rd_addr_i,
  input  logic [NumPorts-1:0]           rd_line_i,   // 1 = whole line, 0 = one word
  output logic [NumPorts-1:0]           rd_gnt_o,
  output logic [NumPorts-1:0]           rd_rvalid_o,
  output logic [NumPorts*LineBits-1:0]  rd_rdata_o,

  // --- write ports -----------------------------------------------------------
  input  logic [NumPorts-1:0]           wr_req_i,
  input  logic [NumPorts*AddrW-1:0]     wr_addr_i,
  input  logic [NumPorts*WordBytes-1:0] wr_be_i,
  input  logic [NumPorts*DataW-1:0]     wr_wdata_i,
  output logic [NumPorts-1:0]           wr_gnt_o
);

  logic [DataW-1:0] mem [NumWords];

  // ===========================================================================
  //  Write server -- one word write per cycle, round robin
  // ===========================================================================
  logic [PortW-1:0] wptr_q;
  logic             wsel_valid;
  logic [PortW-1:0] wsel_idx;

  always_comb begin
    wsel_valid = 1'b0;
    wsel_idx   = '0;
    for (int unsigned i = 0; i < NumPorts; i++) begin
      if (!wsel_valid && wr_req_i[(int'(wptr_q) + i) % NumPorts]) begin
        wsel_valid = 1'b1;
        wsel_idx   = PortW'((int'(wptr_q) + i) % NumPorts);
      end
    end
  end

  always_comb begin
    wr_gnt_o = '0;
    if (wsel_valid) wr_gnt_o[wsel_idx] = 1'b1;
  end

  logic [IdxW-1:0]      wsel_word;
  logic [WordBytes-1:0] wsel_be;
  logic [DataW-1:0]     wsel_data;
  assign wsel_word = wr_addr_i [int'(wsel_idx)*AddrW + ByteOffW +: IdxW];
  assign wsel_be   = wr_be_i   [int'(wsel_idx)*WordBytes +: WordBytes];
  assign wsel_data = wr_wdata_i[int'(wsel_idx)*DataW +: DataW];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wptr_q <= '0;
    end else if (wsel_valid) begin
      wptr_q <= PortW'((int'(wsel_idx) + 1) % NumPorts);
      for (int unsigned b = 0; b < WordBytes; b++) begin
        if (wsel_be[b]) mem[wsel_word][b*8 +: 8] <= wsel_data[b*8 +: 8];
      end
    end
  end

  // ===========================================================================
  //  Read server -- accepts one transaction at a time, but issues its word
  //  accesses back to back and keeps them pipelined through the array.
  // ===========================================================================
  logic [PortW-1:0] rptr_q;
  logic             issuing_q;          // a multi-word burst is still being issued
  logic [PortW-1:0] iport_q;
  logic [IdxW-1:0]  ibase_q;
  logic [CntW-1:0]  icnt_q;             // words issued so far in this burst
  logic [CntW-1:0]  ilen_q;             // words this burst needs

  logic             rsel_valid;
  logic [PortW-1:0] rsel_idx;

  always_comb begin
    rsel_valid = 1'b0;
    rsel_idx   = '0;
    if (!issuing_q) begin
      for (int unsigned i = 0; i < NumPorts; i++) begin
        if (!rsel_valid && rd_req_i[(int'(rptr_q) + i) % NumPorts]) begin
          rsel_valid = 1'b1;
          rsel_idx   = PortW'((int'(rptr_q) + i) % NumPorts);
        end
      end
    end
  end

  always_comb begin
    rd_gnt_o = '0;
    if (rsel_valid) rd_gnt_o[rsel_idx] = 1'b1;
  end

  // The address presented to the array this cycle, and the burst bookkeeping
  // it belongs to.
  logic             acc_valid;
  logic [IdxW-1:0]  acc_word;
  logic [PortW-1:0] acc_port;
  logic [LaneW-1:0] acc_lane;
  logic             acc_last;

  logic [IdxW-1:0]  sel_base;
  logic [CntW-1:0]  sel_len;
  assign sel_base = rd_addr_i[int'(rsel_idx)*AddrW + ByteOffW +: IdxW];
  assign sel_len  = rd_line_i[rsel_idx] ? CntW'(WordsPerLine) : CntW'(1);

  always_comb begin
    acc_valid = 1'b0;
    acc_port  = '0;
    acc_word  = '0;
    acc_lane  = '0;
    acc_last  = 1'b0;
    if (rsel_valid) begin
      acc_valid = 1'b1;
      acc_port  = rsel_idx;
      acc_word  = sel_base;
      acc_lane  = '0;
      acc_last  = (sel_len == CntW'(1));
    end else if (issuing_q) begin
      acc_valid = 1'b1;
      acc_port  = iport_q;
      acc_word  = ibase_q + IdxW'(icnt_q);
      acc_lane  = LaneW'(icnt_q);
      acc_last  = (icnt_q == ilen_q - CntW'(1));
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rptr_q    <= '0;
      issuing_q <= 1'b0;
      icnt_q    <= '0;
      ilen_q    <= '0;
      iport_q   <= '0;
      ibase_q   <= '0;
    end else if (rsel_valid) begin
      rptr_q    <= PortW'((int'(rsel_idx) + 1) % NumPorts);
      iport_q   <= rsel_idx;
      ibase_q   <= sel_base;
      ilen_q    <= sel_len;
      icnt_q    <= CntW'(1);
      issuing_q <= (sel_len != CntW'(1));
    end else if (issuing_q) begin
      icnt_q <= icnt_q + CntW'(1);
      if (icnt_q == ilen_q - CntW'(1)) issuing_q <= 1'b0;
    end
  end

  // --- array pipeline --------------------------------------------------------
  logic             pv    [AccessLat];
  logic [PortW-1:0] pport [AccessLat];
  logic [LaneW-1:0] plane [AccessLat];
  logic             plast [AccessLat];
  logic [DataW-1:0] pdata [AccessLat];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned s = 0; s < AccessLat; s++) pv[s] <= 1'b0;
    end else begin
      pv[0]    <= acc_valid;
      pport[0] <= acc_port;
      plane[0] <= acc_lane;
      plast[0] <= acc_last;
      pdata[0] <= mem[acc_word];
      for (int unsigned s = 1; s < AccessLat; s++) begin
        pv[s]    <= pv[s-1];
        pport[s] <= pport[s-1];
        plane[s] <= plane[s-1];
        plast[s] <= plast[s-1];
        pdata[s] <= pdata[s-1];
      end
    end
  end

  // --- per-port line assembly ------------------------------------------------
  //  A port has at most one read outstanding, so one assembly register each.
  logic [LineBits-1:0] asm_q [NumPorts];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_rvalid_o <= '0;
    end else begin
      rd_rvalid_o <= '0;
      if (pv[AccessLat-1]) begin
        asm_q[pport[AccessLat-1]][int'(plane[AccessLat-1])*DataW +: DataW]
          <= pdata[AccessLat-1];
        if (plast[AccessLat-1]) rd_rvalid_o[pport[AccessLat-1]] <= 1'b1;
      end
    end
  end

  always_comb begin
    for (int unsigned p = 0; p < NumPorts; p++) begin
      rd_rdata_o[p*LineBits +: LineBits] = asm_q[p];
    end
  end

`ifndef SYNTHESIS
  initial begin
    for (int unsigned i = 0; i < NumWords; i++) mem[i] = '0;
    if (InitFile != "") $readmemh(InitFile, mem);
  end

  function automatic void poke(input int unsigned word_addr, input logic [DataW-1:0] d);
    mem[word_addr % NumWords] = d;
  endfunction

  function automatic logic [DataW-1:0] peek(input int unsigned word_addr);
    return mem[word_addr % NumWords];
  endfunction
`endif

endmodule
