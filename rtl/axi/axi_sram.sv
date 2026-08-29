// =============================================================================
//  axi_sram.sv -- AXI4 slave wrapping a single-port memory array.
//
//  Both shared memories of Fig. 1 are built from this: the shared data memory
//  and the shared scratchpad instruction memory that doubles as boot memory.
//  In M5 each of those carried its own multi-port arbiter; with a real crossbar
//  in front, arbitration belongs to the fabric and the memory becomes what the
//  paper says it is -- a plain dual-ported BRAM behind an AXI port.
//
//  Reads: an INCR burst is answered with AccessLat cycles of array latency and
//  then one beat per cycle, which is how a pipelined BRAM behaves and is what
//  makes a cache line fill cheaper per word than four separate reads.
//
//  Writes: WSTRB is honoured byte by byte, so the cache's write-through of one
//  word lands without disturbing the rest of the line.
//
//  Read and write are independent state machines sharing only the array, so a
//  read burst and a write proceed in the same cycles -- the dual-ported
//  behaviour the paper's BRAMs have.
// =============================================================================
module axi_sram #(
  parameter  int unsigned AddrW     = 32,
  parameter  int unsigned DataW     = 32,
  parameter  int unsigned IdW       = 4,
  parameter  int unsigned LenW      = 8,
  parameter  int unsigned SizeBytes = 262144,
  parameter  int unsigned AccessLat = 2,

  localparam int unsigned StrbW    = DataW/8,
  localparam int unsigned NumWords = SizeBytes / (DataW/8),
  localparam int unsigned ByteOffW = $clog2(DataW/8),
  localparam int unsigned IdxW     = $clog2(NumWords),
  localparam int unsigned LatW     = (AccessLat <= 1) ? 1 : $clog2(AccessLat + 1)
) (
  input  logic             clk_i,
  input  logic             rst_ni,

  input  logic             arvalid_i,
  output logic             arready_o,
  input  logic [AddrW-1:0] araddr_i,
  input  logic [LenW-1:0]  arlen_i,
  input  logic [IdW-1:0]   arid_i,

  output logic             rvalid_o,
  input  logic             rready_i,
  output logic [DataW-1:0] rdata_o,
  output logic [1:0]       rresp_o,
  output logic             rlast_o,
  output logic [IdW-1:0]   rid_o,

  input  logic             awvalid_i,
  output logic             awready_o,
  input  logic [AddrW-1:0] awaddr_i,
  input  logic [LenW-1:0]  awlen_i,
  input  logic [IdW-1:0]   awid_i,

  input  logic             wvalid_i,
  output logic             wready_o,
  input  logic [DataW-1:0] wdata_i,
  input  logic [StrbW-1:0] wstrb_i,
  input  logic             wlast_i,

  output logic             bvalid_o,
  input  logic             bready_i,
  output logic [1:0]       bresp_o,
  output logic [IdW-1:0]   bid_o
);

  localparam logic [1:0] RESP_OKAY = 2'b00;

  (* ram_style = "block" *) logic [DataW-1:0] mem [NumWords];

  // ===========================================================================
  //  Read channel
  // ===========================================================================
  typedef enum logic [1:0] { R_IDLE, R_LAT, R_DATA } rstate_e;

  rstate_e         r_state_q;
  logic [IdxW-1:0] r_word_q;
  logic [LenW-1:0] r_left_q;
  logic [IdW-1:0]  r_id_q;
  logic [LatW-1:0] r_lat_q;

  assign arready_o = (r_state_q == R_IDLE);
  assign rvalid_o  = (r_state_q == R_DATA);
  assign rresp_o   = RESP_OKAY;
  assign rlast_o   = (r_left_q == '0);
  assign rid_o     = r_id_q;

  // Next value of the read pointer, broken out so that the array can be read
  // at it. Registering mem[r_word_d] makes the output hold mem[r_word_q]
  // during the very cycle r_word_q names that word -- cycle for cycle what an
  // asynchronous read of the array gave, but built from a synchronous read
  // port, which is the only kind a block RAM has. Reading the array
  // combinationally would have mapped these 256 KiB onto LUTRAM.
  logic [IdxW-1:0] r_word_d;

  always_comb begin
    r_word_d = r_word_q;
    case (r_state_q)
      R_IDLE:  if (arvalid_i)                    r_word_d = araddr_i[ByteOffW +: IdxW];
      R_DATA:  if (rready_i && (r_left_q != '0)) r_word_d = r_word_q + IdxW'(1);
      default: ;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      r_state_q <= R_IDLE;
      r_word_q  <= '0;
      r_left_q  <= '0;
      r_id_q    <= '0;
      r_lat_q   <= '0;
    end else begin
      r_word_q <= r_word_d;
      case (r_state_q)
        R_IDLE: begin
          if (arvalid_i) begin
            r_left_q  <= arlen_i;
            r_id_q    <= arid_i;
            r_lat_q   <= LatW'(AccessLat);
            r_state_q <= (AccessLat == 0) ? R_DATA : R_LAT;
          end
        end

        R_LAT: begin
          if (r_lat_q <= LatW'(1)) r_state_q <= R_DATA;
          else                     r_lat_q   <= r_lat_q - LatW'(1);
        end

        R_DATA: begin
          if (rready_i) begin
            if (r_left_q == '0) begin
              r_state_q <= R_IDLE;
            end else begin
              r_left_q <= r_left_q - LenW'(1);
            end
          end
        end

        default: r_state_q <= R_IDLE;
      endcase
    end
  end

  // ===========================================================================
  //  Write channel
  // ===========================================================================
  typedef enum logic [1:0] { W_IDLE, W_DATA, W_RESP } wstate_e;

  wstate_e         w_state_q;
  logic [IdxW-1:0] w_word_q;
  logic [IdW-1:0]  w_id_q;

  assign awready_o = (w_state_q == W_IDLE);
  assign wready_o  = (w_state_q == W_DATA);
  assign bvalid_o  = (w_state_q == W_RESP);
  assign bresp_o   = RESP_OKAY;
  assign bid_o     = w_id_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      w_state_q <= W_IDLE;
      w_word_q  <= '0;
      w_id_q    <= '0;
    end else begin
      case (w_state_q)
        W_IDLE: begin
          if (awvalid_i) begin
            w_word_q  <= awaddr_i[ByteOffW +: IdxW];
            w_id_q    <= awid_i;
            w_state_q <= W_DATA;
          end
        end

        W_DATA: begin
          if (wvalid_i) begin
            w_word_q <= w_word_q + IdxW'(1);
            if (wlast_i) w_state_q <= W_RESP;
          end
        end

        W_RESP: begin
          if (bready_i) w_state_q <= W_IDLE;
        end

        default: w_state_q <= W_IDLE;
      endcase
    end
  end

  // ===========================================================================
  //  Array read port
  // ===========================================================================
  // Read port of the array, plus the write-first bypass that keeps it exactly
  // equivalent to the old asynchronous read: a byte written in the same cycle
  // the read was issued is forwarded instead of the stale array output.
  logic [DataW-1:0]  rdata_q, wfwd_q;
  logic [StrbW-1:0]  coll_q;

  logic [StrbW-1:0]  w_strb;
  assign w_strb = ((w_state_q == W_DATA) && wvalid_i) ? wstrb_i : '0;

  // The array itself is driven from blocks with no reset at all. A block RAM
  // has no reset on its storage, so an array written under an asynchronous
  // reset cannot be inferred as one -- synthesis says the memory pattern is
  // unsupported and falls back to flip-flops, which for 2 Mbit is not a build
  // that finishes. The write pointer and the FSM keep their reset above; only
  // the storage moves out.
  always_ff @(posedge clk_i) begin
    for (int unsigned b = 0; b < StrbW; b++) begin
      if (w_strb[b]) mem[w_word_q][b*8 +: 8] <= wdata_i[b*8 +: 8];
    end
  end

  always_ff @(posedge clk_i) begin
    rdata_q <= mem[r_word_d];
    wfwd_q  <= wdata_i;
    for (int unsigned b = 0; b < StrbW; b++) begin
      coll_q[b] <= w_strb[b] && (w_word_q == r_word_d);
    end
  end

  always_comb begin
    for (int unsigned b = 0; b < StrbW; b++) begin
      rdata_o[b*8 +: 8] = coll_q[b] ? wfwd_q[b*8 +: 8] : rdata_q[b*8 +: 8];
    end
  end

`ifndef SYNTHESIS
  initial begin
    for (int unsigned i = 0; i < NumWords; i++) mem[i] = '0;
  end

  function automatic void load_hex(input string path);
    $readmemh(path, mem);
  endfunction

  function automatic void poke(input int unsigned word_addr, input logic [DataW-1:0] d);
    mem[word_addr % NumWords] = d;
  endfunction

  function automatic logic [DataW-1:0] peek(input int unsigned word_addr);
    return mem[word_addr % NumWords];
  endfunction
`endif

endmodule
