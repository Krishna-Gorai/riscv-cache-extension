// =============================================================================
//  data_bridge.sv -- Data-Bridge of a Processing Element.
//
//  Section III-B: "The Data-Bridges are located in the PE where each PE has its
//  own Data-Bridge. [...] We extended the Data-Bridge to coordinate the
//  communication between the RISC-V core, the DCU (D-Cache with additional
//  control logic), and the snoopy bus. The Data-Bridge is also used during
//  instructions transfer from the shared instruction memory to the ITCM
//  (write-mode)."
//
//  It is the address decoder of the core data port and routes an access to
//    * the coherent shared data memory, through the private DCU
//    * the local ITCM write port, when loading code
//    * the shared instruction memory, read-only, which is where that code is
//      read from during the boot-time transfer into the ITCM
//    * an uncached control region, used by the testbenches for the exit
//      handshake and character output
//
//  The snoopy bus itself is not touched here: the DCU owns that port, which is
//  what makes the extension seamless -- the core sees an ordinary data port and
//  is unaware that coherence is happening at all.
// =============================================================================
module data_bridge
  import cache_pkg::*;
#(
  parameter  int unsigned AddrW     = 32,
  parameter  int unsigned DataW     = 32,
  parameter  logic [3:0]  ItcmNib   = 4'h0,   // 0x0xxx_xxxx -> local ITCM
  parameter  logic [3:0]  SdmemNib  = 4'h1,   // 0x1xxx_xxxx -> coherent shared data
  parameter  logic [3:0]  SimemNib  = 4'h2,   // 0x2xxx_xxxx -> shared instruction mem
  parameter  logic [3:0]  CtrlNib   = 4'h8,   // 0x8xxx_xxxx -> uncached control

  localparam int unsigned WordBytes = DataW / 8
) (
  input  logic                 clk_i,
  input  logic                 rst_ni,

  // core data port
  input  logic                 core_req_i,
  output logic                 core_gnt_o,
  input  logic [AddrW-1:0]     core_addr_i,
  input  logic                 core_we_i,
  input  logic [WordBytes-1:0] core_be_i,
  input  logic [DataW-1:0]     core_wdata_i,
  output logic                 core_rvalid_o,
  output logic [DataW-1:0]     core_rdata_o,

  // atomic qualifier, forwarded to the DCU and on to the snoopy bus
  input  amo_e                 core_amo_i,

  // DCU port -- coherent shared data memory
  output logic                 dcu_req_o,
  input  logic                 dcu_gnt_i,
  output logic [AddrW-1:0]     dcu_addr_o,
  output logic                 dcu_we_o,
  output logic [WordBytes-1:0] dcu_be_o,
  output logic [DataW-1:0]     dcu_wdata_o,
  output amo_e                 dcu_amo_o,
  input  logic                 dcu_rvalid_i,
  input  logic [DataW-1:0]     dcu_rdata_i,

  // ITCM data port -- write-mode instruction transfer
  output logic                 itcm_req_o,
  input  logic                 itcm_gnt_i,
  output logic [AddrW-1:0]     itcm_addr_o,
  output logic                 itcm_we_o,
  output logic [WordBytes-1:0] itcm_be_o,
  output logic [DataW-1:0]     itcm_wdata_o,
  input  logic                 itcm_rvalid_i,
  input  logic [DataW-1:0]     itcm_rdata_i,

  // shared instruction memory, read side -- boot-time code transfer
  output logic                 simem_req_o,
  input  logic                 simem_gnt_i,
  output logic [AddrW-1:0]     simem_addr_o,
  input  logic                 simem_rvalid_i,
  input  logic [DataW-1:0]     simem_rdata_i,

  // uncached control region
  output logic                 ctrl_req_o,
  input  logic                 ctrl_gnt_i,
  output logic [AddrW-1:0]     ctrl_addr_o,
  output logic                 ctrl_we_o,
  output logic [WordBytes-1:0] ctrl_be_o,
  output logic [DataW-1:0]     ctrl_wdata_o,
  input  logic                 ctrl_rvalid_i,
  input  logic [DataW-1:0]     ctrl_rdata_i
);

  // 0 = DCU, 1 = ITCM, 2 = control, 3 = shared instruction memory
  localparam int unsigned NumTgt = 4;

  logic [NumTgt-1:0]       sel;
  logic [NumTgt-1:0]       dn_req, dn_gnt, dn_rvalid;
  logic [NumTgt*DataW-1:0] dn_rdata;

  always_comb begin
    sel = '0;
    unique case (core_addr_i[AddrW-1 -: 4])
      SdmemNib: sel[0] = 1'b1;
      ItcmNib:  sel[1] = 1'b1;
      CtrlNib:  sel[2] = 1'b1;
      SimemNib: sel[3] = 1'b1;
      default:  sel    = '0;
    endcase
  end

  assign dcu_req_o    = dn_req[0];
  assign itcm_req_o   = dn_req[1];
  assign ctrl_req_o   = dn_req[2];
  assign simem_req_o  = dn_req[3];

  // The payload is simply broadcast; only the selected target ever samples it.
  assign dcu_addr_o   = core_addr_i;
  assign dcu_we_o     = core_we_i;
  assign dcu_be_o     = core_be_i;
  assign dcu_wdata_o  = core_wdata_i;
  assign dcu_amo_o    = core_amo_i;

  assign itcm_addr_o  = core_addr_i;
  assign itcm_we_o    = core_we_i;
  assign itcm_be_o    = core_be_i;
  assign itcm_wdata_o = core_wdata_i;

  assign ctrl_addr_o  = core_addr_i;
  assign ctrl_we_o    = core_we_i;
  assign ctrl_be_o    = core_be_i;
  assign ctrl_wdata_o = core_wdata_i;

  // The shared instruction memory is read-only; a store that lands there is
  // handshaked and discarded rather than deadlocking the core.
  assign simem_addr_o = core_addr_i;

  assign dn_gnt    = {simem_gnt_i,    ctrl_gnt_i,    itcm_gnt_i,    dcu_gnt_i};
  assign dn_rvalid = {simem_rvalid_i, ctrl_rvalid_i, itcm_rvalid_i, dcu_rvalid_i};
  assign dn_rdata  = {simem_rdata_i,  ctrl_rdata_i,  itcm_rdata_i,  dcu_rdata_i};

  bridge_router #(
    .NumTgt (NumTgt),
    .DataW  (DataW)
  ) u_router (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .up_req_i    (core_req_i),
    .up_sel_i    (sel),
    .up_gnt_o    (core_gnt_o),
    .up_rvalid_o (core_rvalid_o),
    .up_rdata_o  (core_rdata_o),
    .dn_req_o    (dn_req),
    .dn_gnt_i    (dn_gnt),
    .dn_rvalid_i (dn_rvalid),
    .dn_rdata_i  (dn_rdata)
  );

endmodule
