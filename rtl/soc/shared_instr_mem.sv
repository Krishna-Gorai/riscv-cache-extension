// =============================================================================
//  shared_instr_mem.sv -- shared scratchpad instruction memory (Fig. 1).
//
//  Section IV-A: "Both multi-core architectures have a shared scratchpad
//  instruction memory used as boot memory for the 4 RISC-V-based PEs."
//
//  Every PE presents two read ports here: one from its Instruction-Bridge, so
//  it can fetch the boot stub directly out of this memory, and one from its
//  Data-Bridge, so the boot stub can read the code image and transfer it into
//  the local ITCM -- the "instructions transfer from the shared instruction
//  memory to the ITCM (write-mode)" the paper gives the Data-Bridge.
//
//  One read is issued per cycle, chosen round robin, and responses stay
//  pipelined so that several PEs fetching at once lose bandwidth rather than
//  serialising on the full array latency.
// =============================================================================
module shared_instr_mem #(
  parameter  int unsigned NumPorts  = 8,
  parameter  int unsigned AddrW     = 32,
  parameter  int unsigned DataW     = 32,
  parameter  int unsigned SizeBytes = 32768,
  parameter  int unsigned AccessLat = 2,       // cycles from grant to rvalid
  parameter  string       InitFile  = "",

  localparam int unsigned WordBytes = DataW / 8,
  localparam int unsigned NumWords  = SizeBytes / WordBytes,
  localparam int unsigned ByteOffW  = $clog2(WordBytes),
  localparam int unsigned IdxW      = $clog2(NumWords),
  localparam int unsigned PortW     = (NumPorts <= 1) ? 1 : $clog2(NumPorts)
) (
  input  logic                      clk_i,
  input  logic                      rst_ni,

  input  logic [NumPorts-1:0]       req_i,
  input  logic [NumPorts*AddrW-1:0] addr_i,
  output logic [NumPorts-1:0]       gnt_o,
  output logic [NumPorts-1:0]       rvalid_o,
  output logic [NumPorts*DataW-1:0] rdata_o
);

  logic [DataW-1:0] mem [NumWords];

  // ---------------------------------------------------------------------------
  //  Round-robin arbitration -- one access issued per cycle
  // ---------------------------------------------------------------------------
  logic [PortW-1:0] ptr_q;
  logic             sel_valid;
  logic [PortW-1:0] sel_idx;

  always_comb begin
    sel_valid = 1'b0;
    sel_idx   = '0;
    for (int unsigned i = 0; i < NumPorts; i++) begin
      if (!sel_valid && req_i[(int'(ptr_q) + i) % NumPorts]) begin
        sel_valid = 1'b1;
        sel_idx   = PortW'((int'(ptr_q) + i) % NumPorts);
      end
    end
  end

  always_comb begin
    gnt_o = '0;
    if (sel_valid) gnt_o[sel_idx] = 1'b1;
  end

  logic [IdxW-1:0] sel_word;
  assign sel_word = addr_i[int'(sel_idx)*AddrW + ByteOffW +: IdxW];

  // ---------------------------------------------------------------------------
  //  Response pipeline -- AccessLat stages, so requests stay in flight
  // ---------------------------------------------------------------------------
  logic             pipe_v    [AccessLat];
  logic [PortW-1:0] pipe_port [AccessLat];
  logic [DataW-1:0] pipe_data [AccessLat];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ptr_q <= '0;
      for (int unsigned s = 0; s < AccessLat; s++) pipe_v[s] <= 1'b0;
    end else begin
      if (sel_valid) ptr_q <= PortW'((int'(sel_idx) + 1) % NumPorts);

      // Stage 0 captures the array output of the access granted this cycle.
      pipe_v[0]    <= sel_valid;
      pipe_port[0] <= sel_idx;
      pipe_data[0] <= mem[sel_word];

      for (int unsigned s = 1; s < AccessLat; s++) begin
        pipe_v[s]    <= pipe_v[s-1];
        pipe_port[s] <= pipe_port[s-1];
        pipe_data[s] <= pipe_data[s-1];
      end
    end
  end

  always_comb begin
    rvalid_o = '0;
    rdata_o  = '0;
    if (pipe_v[AccessLat-1]) begin
      rvalid_o[pipe_port[AccessLat-1]] = 1'b1;
      for (int unsigned p = 0; p < NumPorts; p++) begin
        rdata_o[p*DataW +: DataW] = pipe_data[AccessLat-1];
      end
    end
  end

`ifndef SYNTHESIS
  initial begin
    for (int unsigned i = 0; i < NumWords; i++) mem[i] = '0;
    if (InitFile != "") $readmemh(InitFile, mem);
  end

  function automatic void load_hex(input string path);
    $readmemh(path, mem);
  endfunction

  function automatic logic [DataW-1:0] peek(input int unsigned word_addr);
    return mem[word_addr % NumWords];
  endfunction
`endif

endmodule
