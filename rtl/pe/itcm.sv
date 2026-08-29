// =============================================================================
//  itcm.sv -- Instruction Tightly Coupled Memory of a Processing Element.
//
//  Section III-A: each PE hosts a single RISC-V core, a private Data Cache
//  Unit and a scratchpad ITCM. The ITCM is dual ported: the Instruction-Bridge
//  reads instructions from it, while the Data-Bridge writes into it when
//  instructions are transferred from the shared instruction memory.
//
//  Both ports are OBI-style with a fixed one-cycle response latency, always
//  ready, so the prefetch buffer of the core can keep several fetches in
//  flight without ever being stalled by the ITCM itself.
// =============================================================================
module itcm #(
  parameter  int unsigned SizeBytes = 32768,
  parameter  int unsigned AddrW     = 32,
  parameter  int unsigned DataW     = 32,
  parameter  string       InitFile  = "",

  localparam int unsigned WordBytes = DataW / 8,
  localparam int unsigned NumWords  = SizeBytes / WordBytes,
  localparam int unsigned ByteOffW  = $clog2(WordBytes),
  localparam int unsigned IdxW      = $clog2(NumWords)
) (
  input  logic                 clk_i,
  input  logic                 rst_ni,

  // instruction read port -- Instruction-Bridge
  input  logic                 i_req_i,
  output logic                 i_gnt_o,
  input  logic [AddrW-1:0]     i_addr_i,
  output logic                 i_rvalid_o,
  output logic [DataW-1:0]     i_rdata_o,

  // data port -- Data-Bridge (write-mode during instruction transfer)
  input  logic                 d_req_i,
  output logic                 d_gnt_o,
  input  logic [AddrW-1:0]     d_addr_i,
  input  logic                 d_we_i,
  input  logic [WordBytes-1:0] d_be_i,
  input  logic [DataW-1:0]     d_wdata_i,
  output logic                 d_rvalid_o,
  output logic [DataW-1:0]     d_rdata_o
);

  (* ram_style = "block" *) logic [DataW-1:0] mem [NumWords];

  logic [IdxW-1:0] i_idx, d_idx;
  assign i_idx = i_addr_i[ByteOffW +: IdxW];
  assign d_idx = d_addr_i[ByteOffW +: IdxW];

  assign i_gnt_o = i_req_i;
  assign d_gnt_o = d_req_i;

  // Response valids: these are control, and they reset.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      i_rvalid_o <= 1'b0;
      d_rvalid_o <= 1'b0;
    end else begin
      i_rvalid_o <= i_gnt_o;
      d_rvalid_o <= d_gnt_o;
    end
  end

  // The array's two ports carry no reset, because a block RAM's storage has
  // none: with the accesses inside the reset block above, synthesis rejects
  // the pattern and falls back to flip-flops. Data read during reset is never
  // looked at, since both valids are held low there.

  // instruction port: read only
  always_ff @(posedge clk_i) begin
    if (i_gnt_o) i_rdata_o <= mem[i_idx];
  end

  // data port: the only writer of the array
  always_ff @(posedge clk_i) begin
    if (d_gnt_o) begin
      if (d_we_i) begin
        for (int unsigned b = 0; b < WordBytes; b++) begin
          if (d_be_i[b]) mem[d_idx][b*8 +: 8] <= d_wdata_i[b*8 +: 8];
        end
      end else begin
        d_rdata_o <= mem[d_idx];
      end
    end
  end

`ifndef SYNTHESIS
  initial begin
    for (int unsigned i = 0; i < NumWords; i++) mem[i] = '0;
    if (InitFile != "") $readmemh(InitFile, mem);
  end

  // Backdoor program load, used by the testbenches until the CPU-driven
  // transfer from the shared instruction memory is wired up.
  function automatic void load_hex(input string path);
    $readmemh(path, mem);
  endfunction
`endif

endmodule
