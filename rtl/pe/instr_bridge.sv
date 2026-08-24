// =============================================================================
//  instr_bridge.sv -- Instruction-Bridge of a Processing Element.
//
//  Section III-A: "the Instruction-Bridge is used to transfer instructions to
//  RISC-V core (read-mode) either from the ITCM (read-port) or the shared
//  instruction memory."
//
//  The shared instruction memory is non-coherent and is reached across the AXI
//  crossbar, so it never involves the data cache sub-system.
// =============================================================================
module instr_bridge #(
  parameter int unsigned AddrW    = 32,
  parameter int unsigned DataW    = 32,
  parameter logic [3:0]  ItcmNib  = 4'h0,   // 0x0xxx_xxxx -> local ITCM
  parameter logic [3:0]  SimemNib = 4'h2    // 0x2xxx_xxxx -> shared instr. memory
) (
  input  logic             clk_i,
  input  logic             rst_ni,

  // core instruction port
  input  logic             core_req_i,
  output logic             core_gnt_o,
  input  logic [AddrW-1:0] core_addr_i,
  output logic             core_rvalid_o,
  output logic [DataW-1:0] core_rdata_o,

  // ITCM read port
  output logic             itcm_req_o,
  input  logic             itcm_gnt_i,
  output logic [AddrW-1:0] itcm_addr_o,
  input  logic             itcm_rvalid_i,
  input  logic [DataW-1:0] itcm_rdata_i,

  // shared instruction memory port
  output logic             simem_req_o,
  input  logic             simem_gnt_i,
  output logic [AddrW-1:0] simem_addr_o,
  input  logic             simem_rvalid_i,
  input  logic [DataW-1:0] simem_rdata_i
);

  localparam int unsigned NumTgt = 2;   // 0 = ITCM, 1 = shared instruction memory

  logic [NumTgt-1:0]       sel;
  logic [NumTgt-1:0]       dn_req, dn_gnt, dn_rvalid;
  logic [NumTgt*DataW-1:0] dn_rdata;

  always_comb begin
    sel = '0;
    unique case (core_addr_i[AddrW-1 -: 4])
      ItcmNib:  sel[0] = 1'b1;
      SimemNib: sel[1] = 1'b1;
      default:  sel    = '0;            // absorbed by the router's void responder
    endcase
  end

  assign itcm_req_o   = dn_req[0];
  assign simem_req_o  = dn_req[1];
  assign itcm_addr_o  = core_addr_i;
  assign simem_addr_o = core_addr_i;

  assign dn_gnt       = {simem_gnt_i,    itcm_gnt_i};
  assign dn_rvalid    = {simem_rvalid_i, itcm_rvalid_i};
  assign dn_rdata     = {simem_rdata_i,  itcm_rdata_i};

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
