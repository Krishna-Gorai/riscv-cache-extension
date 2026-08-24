// =============================================================================
//  dcu_hcl.sv -- Hit Check Logic (HCL) of the Data Cache Unit.
//
//  Second pipeline stage of the DCU (Fig. 2b / Fig. 3): compares the tag of
//  the request under evaluation against the Tag-RAM entries of the addressed
//  set, qualified by the Status-RAM valid bits, and reports hit / hit-way.
// =============================================================================
module dcu_hcl #(
  parameter  int unsigned NumWays = 2,
  parameter  int unsigned TagW    = 22,
  localparam int unsigned WayW    = (NumWays <= 1) ? 1 : $clog2(NumWays)
) (
  input  logic [NumWays*TagW-1:0] tags_i,   // Tag-RAM read data for the set
  input  logic [NumWays-1:0]      valid_i,  // Status-RAM valid bits for the set
  input  logic [TagW-1:0]         tag_i,    // tag of the request

  output logic                    hit_o,
  output logic [WayW-1:0]         hit_way_o,
  output logic [NumWays-1:0]      hit_vec_o
);

  always_comb begin
    for (int unsigned w = 0; w < NumWays; w++) begin
      hit_vec_o[w] = valid_i[w] && (tags_i[w*TagW +: TagW] == tag_i);
    end
  end

  assign hit_o = |hit_vec_o;

  always_comb begin
    hit_way_o = '0;
    for (int unsigned w = 0; w < NumWays; w++) begin
      if (hit_vec_o[w]) hit_way_o = WayW'(w);
    end
  end

`ifndef SYNTHESIS
  // A correctly maintained cache never holds the same tag in two ways.
  always_comb begin
    if ($countones(hit_vec_o) > 1) begin
      $error("dcu_hcl: multi-way hit (tag=%0h valid=%0b)", tag_i, valid_i);
    end
  end
`endif

endmodule
