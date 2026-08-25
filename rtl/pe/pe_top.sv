// =============================================================================
//  pe_top.sv -- one RISC-V Processing Element (Fig. 1).
//
//  "each RISC-V PE hosts a single RISC-V core based on RV32 ISA, a private Data
//  Cache Unit (DCU), a scratchpad Instruction Tightly Coupled Memory (ITCM),
//  and Instruction-/Data-Bridges for communication between RISC-V cores and PEs
//  local memory units as well as providing an AXI compatible interface to the
//  shared memory."
//
//  The DCU itself lives in the D-Cache Sub-system (rtl/soc/coherent_subsystem.sv)
//  together with the snoopy bus, mirroring the block boundaries of Fig. 1. What
//  leaves this module towards it is an ordinary data port -- the core is never
//  modified and never learns that coherence exists, which is the whole point of
//  the "seamless" claim.
//
//  Memory map (top nibble of the address):
//    0x0  local ITCM              -- instruction fetch, and data writes to load code
//    0x1  coherent shared data    -- through the private DCU
//    0x2  shared instruction mem  -- non-coherent, across the AXI crossbar
//    0x8  uncached control region -- simulation exit handshake and console
// =============================================================================
module pe_top
  import cache_pkg::*;
#(
  parameter  int unsigned AddrW      = 32,
  parameter  int unsigned DataW      = 32,
  parameter  int unsigned ItcmBytes  = 32768,
  parameter  logic [31:0] BootAddr   = 32'h0000_0000,
  parameter  int unsigned HartId     = 0,

  localparam int unsigned WordBytes  = DataW / 8
) (
  input  logic                 clk_i,
  input  logic                 rst_ni,
  input  logic                 fetch_enable_i,

  // --- data port towards this PE's DCU --------------------------------------
  output logic                 dcu_req_o,
  input  logic                 dcu_gnt_i,
  output logic [AddrW-1:0]     dcu_addr_o,
  output logic                 dcu_we_o,
  output logic [WordBytes-1:0] dcu_be_o,
  output logic [DataW-1:0]     dcu_wdata_o,
  output amo_e                 dcu_amo_o,
  input  logic                 dcu_rvalid_i,
  input  logic [DataW-1:0]     dcu_rdata_i,

  // --- shared instruction memory, fetch side (Instruction-Bridge) -----------
  output logic                 simem_i_req_o,
  input  logic                 simem_i_gnt_i,
  output logic [AddrW-1:0]     simem_i_addr_o,
  input  logic                 simem_i_rvalid_i,
  input  logic [DataW-1:0]     simem_i_rdata_i,

  // --- shared instruction memory, data side (Data-Bridge) -------------------
  //  The boot stub reads the code image through this port and writes it into
  //  the ITCM: the "instructions transfer from the shared instruction memory
  //  to the ITCM (write-mode)" of Section III-B.
  output logic                 simem_d_req_o,
  input  logic                 simem_d_gnt_i,
  output logic [AddrW-1:0]     simem_d_addr_o,
  input  logic                 simem_d_rvalid_i,
  input  logic [DataW-1:0]     simem_d_rdata_i,

  // --- uncached control region ----------------------------------------------
  output logic                 ctrl_req_o,
  input  logic                 ctrl_gnt_i,
  output logic [AddrW-1:0]     ctrl_addr_o,
  output logic                 ctrl_we_o,
  output logic [WordBytes-1:0] ctrl_be_o,
  output logic [DataW-1:0]     ctrl_wdata_o,
  input  logic                 ctrl_rvalid_i,
  input  logic [DataW-1:0]     ctrl_rdata_i,

  output logic                 core_sleep_o
);

  // CV32E40P issues no atomics, so the qualifier is a constant. It goes
  // through a typed net rather than straight from the enum literal to the
  // port, which some simulators size as a single bit.
  amo_e amo_none;
  assign amo_none = AMO_NONE;

  // --- core <-> bridges -------------------------------------------------------
  logic             instr_req, instr_gnt, instr_rvalid;
  logic [31:0]      instr_addr, instr_rdata;

  logic             data_req, data_gnt, data_rvalid, data_we;
  logic [3:0]       data_be;
  logic [31:0]      data_addr, data_wdata, data_rdata;

  // --- bridges <-> ITCM -------------------------------------------------------
  logic             itcm_i_req, itcm_i_gnt, itcm_i_rvalid;
  logic [AddrW-1:0] itcm_i_addr;
  logic [DataW-1:0] itcm_i_rdata;

  logic                 itcm_d_req, itcm_d_gnt, itcm_d_rvalid, itcm_d_we;
  logic [AddrW-1:0]     itcm_d_addr;
  logic [WordBytes-1:0] itcm_d_be;
  logic [DataW-1:0]     itcm_d_wdata, itcm_d_rdata;

  // ---------------------------------------------------------------------------
  //  RISC-V core -- unmodified CV32E40P
  // ---------------------------------------------------------------------------
  cv32e40p_top #(
    .COREV_PULP       (0),
    .COREV_CLUSTER    (0),
    .FPU              (0),
    .ZFINX            (0),
    .NUM_MHPMCOUNTERS (1)
  ) u_core (
    .clk_i                (clk_i),
    .rst_ni               (rst_ni),
    .pulp_clock_en_i      (1'b1),
    .scan_cg_en_i         (1'b0),

    .boot_addr_i          (BootAddr),
    .mtvec_addr_i         (BootAddr),
    .dm_halt_addr_i       (32'h1A11_0800),
    .hart_id_i            (32'(HartId)),
    .dm_exception_addr_i  (32'h1A11_0C00),

    .instr_req_o          (instr_req),
    .instr_gnt_i          (instr_gnt),
    .instr_rvalid_i       (instr_rvalid),
    .instr_addr_o         (instr_addr),
    .instr_rdata_i        (instr_rdata),

    .data_req_o           (data_req),
    .data_gnt_i           (data_gnt),
    .data_rvalid_i        (data_rvalid),
    .data_we_o            (data_we),
    .data_be_o            (data_be),
    .data_addr_o          (data_addr),
    .data_wdata_o         (data_wdata),
    .data_rdata_i         (data_rdata),

    .irq_i                (32'b0),
    .irq_ack_o            (),
    .irq_id_o             (),

    .debug_req_i          (1'b0),
    .debug_havereset_o    (),
    .debug_running_o      (),
    .debug_halted_o       (),

    .fetch_enable_i       (fetch_enable_i),
    .core_sleep_o         (core_sleep_o)
  );

  // ---------------------------------------------------------------------------
  //  ITCM
  // ---------------------------------------------------------------------------
  itcm #(
    .SizeBytes (ItcmBytes),
    .AddrW     (AddrW),
    .DataW     (DataW)
  ) u_itcm (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),

    .i_req_i    (itcm_i_req),
    .i_gnt_o    (itcm_i_gnt),
    .i_addr_i   (itcm_i_addr),
    .i_rvalid_o (itcm_i_rvalid),
    .i_rdata_o  (itcm_i_rdata),

    .d_req_i    (itcm_d_req),
    .d_gnt_o    (itcm_d_gnt),
    .d_addr_i   (itcm_d_addr),
    .d_we_i     (itcm_d_we),
    .d_be_i     (itcm_d_be),
    .d_wdata_i  (itcm_d_wdata),
    .d_rvalid_o (itcm_d_rvalid),
    .d_rdata_o  (itcm_d_rdata)
  );

  // ---------------------------------------------------------------------------
  //  Instruction-Bridge
  // ---------------------------------------------------------------------------
  instr_bridge #(
    .AddrW (AddrW),
    .DataW (DataW)
  ) u_instr_bridge (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),

    .core_req_i     (instr_req),
    .core_gnt_o     (instr_gnt),
    .core_addr_i    (instr_addr),
    .core_rvalid_o  (instr_rvalid),
    .core_rdata_o   (instr_rdata),

    .itcm_req_o     (itcm_i_req),
    .itcm_gnt_i     (itcm_i_gnt),
    .itcm_addr_o    (itcm_i_addr),
    .itcm_rvalid_i  (itcm_i_rvalid),
    .itcm_rdata_i   (itcm_i_rdata),

    .simem_req_o    (simem_i_req_o),
    .simem_gnt_i    (simem_i_gnt_i),
    .simem_addr_o   (simem_i_addr_o),
    .simem_rvalid_i (simem_i_rvalid_i),
    .simem_rdata_i  (simem_i_rdata_i)
  );

  // ---------------------------------------------------------------------------
  //  Data-Bridge
  // ---------------------------------------------------------------------------
  //  CV32E40P implements no A extension, so no LR/SC ever reaches this port.
  //  The qualifier is wired through as AMO_NONE and the Link Register path of
  //  the snoopy bus stays exercised by the RTL testbenches instead. See
  //  docs/architecture.md.
  data_bridge #(
    .AddrW (AddrW),
    .DataW (DataW)
  ) u_data_bridge (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),

    .core_req_i    (data_req),
    .core_gnt_o    (data_gnt),
    .core_addr_i   (data_addr),
    .core_we_i     (data_we),
    .core_be_i     (data_be),
    .core_wdata_i  (data_wdata),
    .core_rvalid_o (data_rvalid),
    .core_rdata_o  (data_rdata),
    .core_amo_i    (amo_none),

    .dcu_req_o     (dcu_req_o),
    .dcu_gnt_i     (dcu_gnt_i),
    .dcu_addr_o    (dcu_addr_o),
    .dcu_we_o      (dcu_we_o),
    .dcu_be_o      (dcu_be_o),
    .dcu_wdata_o   (dcu_wdata_o),
    .dcu_amo_o     (dcu_amo_o),
    .dcu_rvalid_i  (dcu_rvalid_i),
    .dcu_rdata_i   (dcu_rdata_i),

    .itcm_req_o    (itcm_d_req),
    .itcm_gnt_i    (itcm_d_gnt),
    .itcm_addr_o   (itcm_d_addr),
    .itcm_we_o     (itcm_d_we),
    .itcm_be_o     (itcm_d_be),
    .itcm_wdata_o  (itcm_d_wdata),
    .itcm_rvalid_i (itcm_d_rvalid),
    .itcm_rdata_i  (itcm_d_rdata),

    .simem_req_o   (simem_d_req_o),
    .simem_gnt_i   (simem_d_gnt_i),
    .simem_addr_o  (simem_d_addr_o),
    .simem_rvalid_i(simem_d_rvalid_i),
    .simem_rdata_i (simem_d_rdata_i),

    .ctrl_req_o    (ctrl_req_o),
    .ctrl_gnt_i    (ctrl_gnt_i),
    .ctrl_addr_o   (ctrl_addr_o),
    .ctrl_we_o     (ctrl_we_o),
    .ctrl_be_o     (ctrl_be_o),
    .ctrl_wdata_o  (ctrl_wdata_o),
    .ctrl_rvalid_i (ctrl_rvalid_i),
    .ctrl_rdata_i  (ctrl_rdata_i)
  );

endmodule
