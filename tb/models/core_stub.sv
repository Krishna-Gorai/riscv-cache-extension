// =============================================================================
//  core_stub.sv -- a stand-in for cv32e40p_top, for core-independent SoC tests.
//
//  This model presents exactly the port list pe_top connects to, so compiling
//  it *instead of* the CV32E40P submodule builds the whole SoC -- bridges,
//  ITCMs, DCUs, snoopy bus, shared memories, control region -- with a
//  synthetic core in place of the real one.
//
//  Why it exists: the CV32E40P uses SystemVerilog that only a full-featured
//  simulator accepts, so tb_soc needs Vivado xsim. This stub lets the SoC
//  integration and its coherence behaviour be tested on any simulator,
//  including Icarus Verilog, which keeps the repository verifiable without a
//  commercial toolchain.
//
//  It is NOT a RISC-V core. It fetches nothing and executes nothing: it drives
//  the data port through the same phase pattern as sw/soc_kernels/par_smoke.c
//
//      phase 0   read the whole array, caching it while it still reads zero
//      barrier
//      phase 1   write only this PE's slice
//      barrier
//      phase 2   read the whole array back, twice
//
//  so that a lost invalidation shows up as a wrong checksum, exactly as it
//  would when running the compiled kernel.
//
//  Written without procedural `automatic` or `break` so it runs on Icarus too.
// =============================================================================
`timescale 1ns/1ps

// Elements in the shared array. The coherence property under test does not
// depend on the array size, so an interpreting simulator can run a smaller
// problem: override with -DSOC_STUB_N=<n> (n must divide the PE count).
`ifndef SOC_STUB_N
  `define SOC_STUB_N 64
`endif

module cv32e40p_top #(
  parameter int COREV_PULP       = 0,
  parameter int COREV_CLUSTER    = 0,
  parameter int FPU              = 0,
  parameter int ZFINX            = 0,
  parameter int NUM_MHPMCOUNTERS = 1
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        pulp_clock_en_i,
  input  logic        scan_cg_en_i,

  input  logic [31:0] boot_addr_i,
  input  logic [31:0] mtvec_addr_i,
  input  logic [31:0] dm_halt_addr_i,
  input  logic [31:0] hart_id_i,
  input  logic [31:0] dm_exception_addr_i,

  output logic        instr_req_o,
  input  logic        instr_gnt_i,
  input  logic        instr_rvalid_i,
  output logic [31:0] instr_addr_o,
  input  logic [31:0] instr_rdata_i,

  output logic        data_req_o,
  input  logic        data_gnt_i,
  input  logic        data_rvalid_i,
  output logic        data_we_o,
  output logic [3:0]  data_be_o,
  output logic [31:0] data_addr_o,
  output logic [31:0] data_wdata_o,
  input  logic [31:0] data_rdata_i,

  input  logic [31:0] irq_i,
  output logic        irq_ack_o,
  output logic [4:0]  irq_id_o,

  input  logic        debug_req_i,
  output logic        debug_havereset_o,
  output logic        debug_running_o,
  output logic        debug_halted_o,

  input  logic        fetch_enable_i,
  output logic        core_sleep_o
);

  // --- the program this stub runs, mirrored from par_smoke.c -----------------
  localparam int unsigned N        = `SOC_STUB_N;
  localparam logic [31:0] SDMEM    = 32'h1000_0000;
  localparam logic [31:0] CTRL     = 32'h8000_0000;
  localparam logic [31:0] ARR_OFF  = 32'h0000;
  localparam logic [31:0] RES_OFF  = 32'h1000;

  assign instr_req_o       = 1'b0;
  assign instr_addr_o      = '0;
  assign irq_ack_o         = 1'b0;
  assign irq_id_o          = '0;
  assign debug_havereset_o = 1'b0;
  assign debug_running_o   = 1'b1;
  assign debug_halted_o    = 1'b0;
  assign core_sleep_o      = 1'b0;

  // Registered views of the handshake, so the sequencer never races the DUT.
  logic        gnt_q, rvalid_q;
  logic [31:0] rdata_q;
  always_ff @(posedge clk_i) begin
    gnt_q    <= data_gnt_i;
    rvalid_q <= data_rvalid_i;
    rdata_q  <= data_rdata_i;
  end

  integer      i;
  integer      npe, id, span, lo, hi;
  integer      waiting;    // used by do_xact
  integer      bwait;      // used by do_barrier -- must NOT alias do_xact's flag
  logic [31:0] rd_result;
  logic [31:0] pre_sum, post_sum, again_sum;
  logic [31:0] gen_before;

  task do_xact(input logic we, input logic [31:0] a, input logic [31:0] wd);
    begin
      data_addr_o  = a;
      data_we_o    = we;
      data_be_o    = 4'hF;
      data_wdata_o = wd;
      data_req_o   = 1'b1;

      waiting = 1;
      while (waiting != 0) begin
        @(posedge clk_i); #1;
        if (gnt_q) begin
          data_req_o = 1'b0;
          waiting    = 0;
        end
      end

      waiting = 1;
      while (waiting != 0) begin
        if (rvalid_q) begin
          rd_result = rdata_q;
          waiting   = 0;
        end else begin
          @(posedge clk_i); #1;
        end
      end
    end
  endtask

  task do_read(input logic [31:0] a);
    begin
      do_xact(1'b0, a, 32'd0);
    end
  endtask

  task do_write(input logic [31:0] a, input logic [31:0] d);
    begin
      do_xact(1'b1, a, d);
    end
  endtask

  // The same sense-reversing barrier the C kernel uses: sample the generation,
  // arrive, then wait for the generation to leave the sampled value behind.
  task do_barrier;
    begin
      do_read(CTRL + 32'h0C);
      gen_before = rd_result;
      do_write(CTRL + 32'h0C, 32'd1);
      // do_read below clobbers `waiting`, so the spin needs its own flag.
      bwait = 1;
      while (bwait != 0) begin
        do_read(CTRL + 32'h0C);
        if (rd_result != gen_before) bwait = 0;
      end
    end
  endtask

  initial begin
    data_req_o   = 1'b0;
    data_we_o    = 1'b0;
    data_be_o    = 4'h0;
    data_addr_o  = '0;
    data_wdata_o = '0;
    pre_sum      = '0;
    post_sum     = '0;
    again_sum    = '0;

    wait (rst_ni === 1'b1);
    wait (fetch_enable_i === 1'b1);
    @(posedge clk_i);

    do_read(CTRL + 32'h10);
    npe  = rd_result;
    id   = hart_id_i;
    span = N / npe;
    lo   = span * id;
    hi   = lo + span;

    // --- phase 0 -------------------------------------------------------------
    for (i = 0; i < N; i = i + 1) begin
      do_read(SDMEM + ARR_OFF + i*4);
      pre_sum = pre_sum + rd_result;
    end
    do_barrier;

    // --- phase 1 -------------------------------------------------------------
    for (i = lo; i < hi; i = i + 1) begin
      do_write(SDMEM + ARR_OFF + i*4, 7*i + 1);
    end
    do_barrier;

    // --- phase 2 -------------------------------------------------------------
    for (i = 0; i < N; i = i + 1) begin
      do_read(SDMEM + ARR_OFF + i*4);
      post_sum = post_sum + rd_result;
    end
    for (i = 0; i < N; i = i + 1) begin
      do_read(SDMEM + ARR_OFF + i*4);
      again_sum = again_sum + rd_result;
    end

    do_write(SDMEM + RES_OFF + (id     )*4, post_sum);
    do_write(SDMEM + RES_OFF + (8  + id)*4, pre_sum);
    do_write(SDMEM + RES_OFF + (16 + id)*4, again_sum);
    do_barrier;

    do_write(CTRL + 32'h00, 32'd1);
  end

  // Silence the unused-input warnings without hiding a real connection error.
  logic unused;
  assign unused = &{1'b0, pulp_clock_en_i, scan_cg_en_i, boot_addr_i,
                    mtvec_addr_i, dm_halt_addr_i, dm_exception_addr_i,
                    instr_gnt_i, instr_rvalid_i, instr_rdata_i, irq_i,
                    debug_req_i, 1'b0};

endmodule
