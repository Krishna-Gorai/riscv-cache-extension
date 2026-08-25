// =============================================================================
//  shared_mem_model.sv -- behavioural model of the coherent shared data memory
//  reached by every PE through the AXI crossbar (Fig. 1).
//
//  Serves NumPorts DCU memory ports: one line read and one word write are
//  serviced per cycle, chosen round robin, with configurable read latency and
//  pseudo-random grant backpressure. The storage array is public so that a
//  testbench can use it as the single point of truth when checking coherence.
// =============================================================================
module shared_mem_model #(
  parameter  int unsigned NumPorts  = 4,
  parameter  int unsigned AddrW     = 32,
  parameter  int unsigned DataW     = 32,
  parameter  int unsigned LineBytes = 16,
  parameter  int unsigned MemWords  = 8192,
  parameter  int unsigned RdLat     = 6,
  parameter  bit          Backpress = 1'b1,

  localparam int unsigned WordBytes    = DataW / 8,
  localparam int unsigned WordsPerLine = LineBytes / WordBytes,
  localparam int unsigned LineBits     = LineBytes * 8,
  localparam int unsigned ByteOffW     = $clog2(WordBytes),
  localparam int unsigned PortW        = (NumPorts <= 1) ? 1 : $clog2(NumPorts)
) (
  input  logic                          clk_i,
  input  logic                          rst_ni,

  input  logic [NumPorts-1:0]           rd_req_i,
  input  logic [NumPorts*AddrW-1:0]     rd_addr_i,
  output logic [NumPorts-1:0]           rd_gnt_o,
  output logic [NumPorts-1:0]           rd_rvalid_o,
  output logic [NumPorts*LineBits-1:0]  rd_rdata_o,

  input  logic [NumPorts-1:0]           wr_req_i,
  input  logic [NumPorts*AddrW-1:0]     wr_addr_i,
  input  logic [NumPorts*WordBytes-1:0] wr_be_i,
  input  logic [NumPorts*DataW-1:0]     wr_wdata_i,
  output logic [NumPorts-1:0]           wr_gnt_o
);

  logic [DataW-1:0] mem [MemWords];

  logic [15:0] lfsr_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) lfsr_q <= 16'hBEEF;
    else         lfsr_q <= {lfsr_q[14:0], lfsr_q[15]^lfsr_q[13]^lfsr_q[12]^lfsr_q[10]};
  end

  logic stall_rd, stall_wr;
  assign stall_rd = Backpress && (lfsr_q[0] & lfsr_q[7]);
  assign stall_wr = Backpress && (lfsr_q[3] & lfsr_q[9]);

  // ---------------------------------------------------------------------------
  //  Write server -- one word write per cycle, round robin
  // ---------------------------------------------------------------------------
  logic [PortW-1:0]    wptr_q;
  logic [NumPorts-1:0] wsel;
  logic                wsel_valid;
  logic [PortW-1:0]    wsel_idx;

  always @(*) begin
    wsel       = '0;
    wsel_valid = 1'b0;
    wsel_idx   = '0;
    for (int unsigned i = 0; i < NumPorts; i++) begin
      automatic int unsigned k = (int'(wptr_q) + i) % NumPorts;
      if (!wsel_valid && wr_req_i[k]) begin
        wsel_valid = 1'b1;
        wsel_idx   = PortW'(k);
        wsel[k]    = 1'b1;
      end
    end
  end

  assign wr_gnt_o = wsel & {NumPorts{wsel_valid && !stall_wr}};

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wptr_q <= '0;
    end else if (|wr_gnt_o) begin
      wptr_q <= PortW'((int'(wsel_idx) + 1) % NumPorts);
      for (int unsigned b = 0; b < WordBytes; b++) begin
        if (wr_be_i[int'(wsel_idx)*WordBytes + b]) begin
          mem[(wr_addr_i[int'(wsel_idx)*AddrW +: AddrW] >> ByteOffW) % MemWords][b*8 +: 8]
            <= wr_wdata_i[int'(wsel_idx)*DataW + b*8 +: 8];
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  //  Read server -- one outstanding line read, round robin
  // ---------------------------------------------------------------------------
  logic [PortW-1:0]    rptr_q;
  logic [NumPorts-1:0] rsel;
  logic                rsel_valid;
  logic [PortW-1:0]    rsel_idx;

  logic                busy_q;
  logic [PortW-1:0]    rport_q;
  logic [AddrW-1:0]    raddr_q;
  int unsigned         rcnt_q;

  always @(*) begin
    rsel       = '0;
    rsel_valid = 1'b0;
    rsel_idx   = '0;
    for (int unsigned i = 0; i < NumPorts; i++) begin
      automatic int unsigned k = (int'(rptr_q) + i) % NumPorts;
      if (!rsel_valid && rd_req_i[k]) begin
        rsel_valid = 1'b1;
        rsel_idx   = PortW'(k);
        rsel[k]    = 1'b1;
      end
    end
  end

  assign rd_gnt_o = rsel & {NumPorts{rsel_valid && !busy_q && !stall_rd}};

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      busy_q      <= 1'b0;
      rptr_q      <= '0;
      rcnt_q      <= 0;
      rd_rvalid_o <= '0;
    end else begin
      rd_rvalid_o <= '0;
      if (!busy_q) begin
        if (|rd_gnt_o) begin
          busy_q  <= 1'b1;
          rport_q <= rsel_idx;
          raddr_q <= rd_addr_i[int'(rsel_idx)*AddrW +: AddrW];
          rcnt_q  <= RdLat;
          rptr_q  <= PortW'((int'(rsel_idx) + 1) % NumPorts);
        end
      end else if (rcnt_q > 1) begin
        rcnt_q <= rcnt_q - 1;
      end else begin
        busy_q               <= 1'b0;
        rd_rvalid_o[rport_q] <= 1'b1;
        for (int unsigned j = 0; j < WordsPerLine; j++) begin
          rd_rdata_o[int'(rport_q)*LineBits + j*DataW +: DataW]
            <= mem[((raddr_q >> ByteOffW) + j) % MemWords];
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  //  Backdoor access
  // ---------------------------------------------------------------------------
  function automatic void poke(input int unsigned word_addr, input logic [DataW-1:0] d);
    mem[word_addr % MemWords] = d;
  endfunction

  function automatic logic [DataW-1:0] peek(input int unsigned word_addr);
    return mem[word_addr % MemWords];
  endfunction

endmodule
