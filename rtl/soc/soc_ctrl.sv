// =============================================================================
//  soc_ctrl.sv -- uncached control region shared by every PE.
//
//  This is not part of the paper's architecture: it is the platform plumbing a
//  bare-metal multi-core program needs in order to be observable. It sits in
//  its own uncached address region so that nothing here ever perturbs the
//  cache hit-rate counters the evaluation is about.
//
//  Word map, relative to the region base:
//    0x00  TOHOST    w: latch this PE's exit code and mark it finished
//                    r: bitmap of the PEs that have finished
//    0x04  PUTCHAR   w: emit one character on the simulation console
//    0x08  CYCLE     r: free-running global cycle counter
//    0x0C  BARRIER   r: current barrier generation
//                    w: arrive at the barrier; the generation advances once
//                       all NumPes PEs have arrived
//    0x10  NUM_PES   r: how many PEs the SoC was built with
//
//  The barrier is hardware because CV32E40P implements no A extension, so the
//  PEs have no atomic read-modify-write to build a software barrier from.
//  Arrivals are counted one per cycle behind the arbiter, which makes the
//  counting atomic by construction. See the LR/SC note in the README: the
//  snoopy bus link register that would otherwise serve this purpose is built
//  and verified, but no core in this SoC can reach it.
// =============================================================================
module soc_ctrl #(
  parameter  int unsigned NumPes = 4,
  parameter  int unsigned AddrW  = 32,
  parameter  int unsigned DataW  = 32,

  localparam int unsigned WordBytes = DataW / 8,
  localparam int unsigned PortW     = (NumPes <= 1) ? 1 : $clog2(NumPes)
) (
  input  logic                        clk_i,
  input  logic                        rst_ni,

  input  logic [NumPes-1:0]           req_i,
  output logic [NumPes-1:0]           gnt_o,
  input  logic [NumPes*AddrW-1:0]     addr_i,
  input  logic [NumPes-1:0]           we_i,
  input  logic [NumPes*WordBytes-1:0] be_i,
  input  logic [NumPes*DataW-1:0]     wdata_i,
  output logic [NumPes-1:0]           rvalid_o,
  output logic [NumPes*DataW-1:0]     rdata_o,

  // --- observation, for the testbench ----------------------------------------
  output logic [NumPes-1:0]           done_o,
  output logic [NumPes*DataW-1:0]     exit_code_o,
  output logic                        putchar_valid_o,
  output logic [7:0]                  putchar_data_o,
  output logic [31:0]                 cycle_o
);

  // ---------------------------------------------------------------------------
  //  Round-robin arbitration -- one access per cycle
  // ---------------------------------------------------------------------------
  logic [PortW-1:0] ptr_q;
  logic             sel_valid;
  logic [PortW-1:0] sel_idx;

  always_comb begin
    sel_valid = 1'b0;
    sel_idx   = '0;
    for (int unsigned i = 0; i < NumPes; i++) begin
      if (!sel_valid && req_i[(int'(ptr_q) + i) % NumPes]) begin
        sel_valid = 1'b1;
        sel_idx   = PortW'((int'(ptr_q) + i) % NumPes);
      end
    end
  end

  always_comb begin
    gnt_o = '0;
    if (sel_valid) gnt_o[sel_idx] = 1'b1;
  end

  logic [AddrW-1:0] sel_addr;
  logic             sel_we;
  logic [DataW-1:0] sel_wdata;
  assign sel_addr  = addr_i [int'(sel_idx)*AddrW +: AddrW];
  assign sel_we    = we_i   [sel_idx];
  assign sel_wdata = wdata_i[int'(sel_idx)*DataW +: DataW];

  logic [7:0] sel_reg;
  assign sel_reg = sel_addr[7:0];

  // ---------------------------------------------------------------------------
  //  State
  // ---------------------------------------------------------------------------
  logic [31:0]    cycle_q;
  logic [31:0]    bar_gen_q;
  logic [PortW:0] bar_cnt_q;

  logic           last_arrival;
  assign last_arrival = (bar_cnt_q == (PortW+1)'(NumPes - 1));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ptr_q           <= '0;
      cycle_q         <= '0;
      bar_gen_q       <= '0;
      bar_cnt_q       <= '0;
      done_o          <= '0;
      exit_code_o     <= '0;
      putchar_valid_o <= 1'b0;
      putchar_data_o  <= '0;
      rvalid_o        <= '0;
      rdata_o         <= '0;
    end else begin
      cycle_q         <= cycle_q + 32'd1;
      putchar_valid_o <= 1'b0;
      rvalid_o        <= '0;

      if (sel_valid) begin
        ptr_q             <= PortW'((int'(sel_idx) + 1) % NumPes);
        rvalid_o[sel_idx] <= 1'b1;
        rdata_o           <= '0;

        if (sel_we) begin
          case (sel_reg)
            8'h00: begin
              exit_code_o[int'(sel_idx)*DataW +: DataW] <= sel_wdata;
              done_o[sel_idx]                           <= 1'b1;
            end
            8'h04: begin
              putchar_valid_o <= 1'b1;
              putchar_data_o  <= sel_wdata[7:0];
            end
            8'h0C: begin
              if (last_arrival) begin
                bar_cnt_q <= '0;
                bar_gen_q <= bar_gen_q + 32'd1;
              end else begin
                bar_cnt_q <= bar_cnt_q + (PortW+1)'(1);
              end
            end
            default: ;
          endcase
        end else begin
          case (sel_reg)
            8'h00:   rdata_o[int'(sel_idx)*DataW +: DataW] <= DataW'(done_o);
            8'h08:   rdata_o[int'(sel_idx)*DataW +: DataW] <= cycle_q;
            8'h0C:   rdata_o[int'(sel_idx)*DataW +: DataW] <= bar_gen_q;
            8'h10:   rdata_o[int'(sel_idx)*DataW +: DataW] <= DataW'(NumPes);
            default: rdata_o[int'(sel_idx)*DataW +: DataW] <= '0;
          endcase
        end
      end
    end
  end

  assign cycle_o = cycle_q;

  // Byte enables are accepted but ignored: every register in this region is a
  // whole word and the kernels only ever reach it with word instructions.
  logic unused_be;
  assign unused_be = |be_i;

endmodule
