// =============================================================================
//  mem_model.sv -- behavioural model of the shared data memory as seen by one
//  DCU through its D-AXI port.
//
//  Serves line-granular reads and word-granular (byte-enabled) writes with
//  configurable latency and pseudo-random grant backpressure, so that both
//  stage-2 stall conditions of the SCL are exercised.
//
//  The storage array is public so that a testbench can peek and poke it as a
//  backdoor, which is how "did this write actually reach memory" and "is this
//  line stale in the cache" are checked.
// =============================================================================
module mem_model #(
  parameter  int unsigned AddrW     = 32,
  parameter  int unsigned DataW     = 32,
  parameter  int unsigned LineBytes = 16,
  parameter  int unsigned MemWords  = 4096,
  parameter  int unsigned RdLat     = 4,
  parameter  int unsigned WrLat     = 1,
  parameter  bit          Backpress = 1'b1,

  localparam int unsigned WordBytes    = DataW / 8,
  localparam int unsigned WordsPerLine = LineBytes / WordBytes,
  localparam int unsigned LineBits     = LineBytes * 8
) (
  input  logic                 clk_i,
  input  logic                 rst_ni,

  input  logic                 rd_req_i,
  input  logic [AddrW-1:0]     rd_addr_i,
  output logic                 rd_gnt_o,
  output logic                 rd_rvalid_o,
  output logic [LineBits-1:0]  rd_rdata_o,

  input  logic                 wr_req_i,
  input  logic [AddrW-1:0]     wr_addr_i,
  input  logic [WordBytes-1:0] wr_be_i,
  input  logic [DataW-1:0]     wr_wdata_i,
  output logic                 wr_gnt_o
);

  localparam int unsigned ByteOffW = $clog2(WordBytes);

  logic [DataW-1:0] mem [MemWords];

  // pseudo-random backpressure source
  logic [15:0] lfsr_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) lfsr_q <= 16'hACE1;
    else         lfsr_q <= {lfsr_q[14:0], lfsr_q[15] ^ lfsr_q[13] ^ lfsr_q[12] ^ lfsr_q[10]};
  end

  logic stall_rd, stall_wr;
  assign stall_rd = Backpress && lfsr_q[0];
  assign stall_wr = Backpress && lfsr_q[3];

  // ---------------------------------------------------------------------------
  //  Read channel -- one outstanding line read
  // ---------------------------------------------------------------------------
  logic                busy_q;
  logic [AddrW-1:0]    raddr_q;
  int unsigned         rcnt_q;

  assign rd_gnt_o = rd_req_i && !busy_q && !stall_rd;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      busy_q      <= 1'b0;
      raddr_q     <= '0;
      rcnt_q      <= 0;
      rd_rvalid_o <= 1'b0;
    end else begin
      rd_rvalid_o <= 1'b0;
      if (!busy_q) begin
        if (rd_gnt_o) begin
          busy_q  <= 1'b1;
          raddr_q <= rd_addr_i;
          rcnt_q  <= RdLat;
        end
      end else if (rcnt_q > 1) begin
        rcnt_q <= rcnt_q - 1;
      end else begin
        busy_q      <= 1'b0;
        rd_rvalid_o <= 1'b1;
        for (int unsigned j = 0; j < WordsPerLine; j++) begin
          rd_rdata_o[j*DataW +: DataW] <= mem[((raddr_q >> ByteOffW) + j) % MemWords];
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  //  Write channel -- byte-enabled word write, granted after WrLat cycles
  // ---------------------------------------------------------------------------
  int unsigned wcnt_q;

  assign wr_gnt_o = wr_req_i && !stall_wr && (wcnt_q >= WrLat - 1);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wcnt_q <= 0;
    end else if (wr_req_i) begin
      if (wr_gnt_o) wcnt_q <= 0;
      else          wcnt_q <= wcnt_q + 1;
    end else begin
      wcnt_q <= 0;
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni && wr_gnt_o) begin
      for (int unsigned b = 0; b < WordBytes; b++) begin
        if (wr_be_i[b]) begin
          mem[(wr_addr_i >> ByteOffW) % MemWords][b*8 +: 8] <= wr_wdata_i[b*8 +: 8];
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  //  Backdoor access for the testbench
  // ---------------------------------------------------------------------------
  function automatic void poke(input int unsigned word_addr, input logic [DataW-1:0] d);
    mem[word_addr % MemWords] = d;
  endfunction

  function automatic logic [DataW-1:0] peek(input int unsigned word_addr);
    return mem[word_addr % MemWords];
  endfunction

endmodule
