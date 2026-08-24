// =============================================================================
//  cache_pkg.sv -- shared types for the seamless data-cache extension
//
//  Reproduction of:
//    A. Kamaleldin, M. Nickel, S. Wu, D. Goehringer,
//    "Seamless Cache Extension for FPGA-based Multi-Core RISC-V SoC",
//    IEEE 37th International System-on-Chip Conference (SOCC), 2024.
//
//  Abbreviations follow Fig. 2a of the paper:
//    DCU  - Data Cache Unit          HCL  - Hit Check Logic
//    CCL  - Cache Control Logic      SCL  - Stall Control Logic
//    LR   - Load-Reserved            SC   - Store-Conditional
// =============================================================================
package cache_pkg;

  // ---------------------------------------------------------------------------
  // Request classes handled by the DCU pipeline (Fig. 3).
  // A core may issue READ REQ or WRITE REQ; the snoopy bus may only issue
  // INV REQ.
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    REQ_NONE  = 2'd0,
    REQ_READ  = 2'd1,   // Fig. 3a -- READ  REQ from the local core
    REQ_WRITE = 2'd2,   // Fig. 3b -- WRITE REQ from the local core
    REQ_INV   = 2'd3    // Fig. 3c -- INV   REQ from the snoopy bus
  } req_e;

  // ---------------------------------------------------------------------------
  // Atomic qualifier carried alongside a core request. Section III-B-b:
  // the snoopy bus arbitrates LR READ REQs separately from INV / SC WRITE REQs.
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    AMO_NONE = 2'd0,
    AMO_LR   = 2'd1,    // load-reserved   -> allocates the Link Register
    AMO_SC   = 2'd2     // store-conditional -> checks the exclusive bit
  } amo_e;

  // ---------------------------------------------------------------------------
  // Address decomposition helpers. The DCU is configurable in both line width
  // and set count (Section III-B), so every field width is derived.
  // ---------------------------------------------------------------------------
  function automatic int unsigned clog2_c(input int unsigned v);
    int unsigned r = 0;
    int unsigned n = v - 1;
    while (n > 0) begin
      r++;
      n >>= 1;
    end
    return (r == 0) ? 1 : r;
  endfunction

endpackage : cache_pkg
