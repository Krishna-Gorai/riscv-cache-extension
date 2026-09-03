// =============================================================================
//  fpga_top.sv -- board wrapper that puts the SoC of Fig. 1 onto a ZCU104.
//
//  soc_top is a subsystem: it has no pins of its own, and it exports 1329 bits
//  of observation (per-PE cycle accounting, exit codes, the character stream)
//  that no package could carry. This wrapper is the thin layer that makes it a
//  chip-level design:
//
//    * the 300 MHz differential board clock is divided down to the SoC clock by
//      a single BUFGCE_DIV, so there is no MMCM and no IP to regenerate;
//    * CPU_RESET is synchronised and stretched into a 128-cycle power-on reset;
//    * every observation output is muxed onto one 32-bit readout register whose
//      word is chosen by the DIP switches and push buttons, and whose nibbles
//      walk across the four LEDs.
//
//  The readout mux exists so the numbers mean something. Without a sink, the
//  performance counters inside the SoC are dangling logic and synthesis deletes
//  them -- the utilisation report would then describe a design that cannot be
//  measured. Every counter bit feeds the mux, so every counter survives. The
//  mux is registered at both ends, so it contributes no path into the SoC.
//
//  The wrapper's own cost is reported separately from soc_top's, so that the
//  resource figures compared against Table I are the SoC's alone.
// =============================================================================
module fpga_top #(
  parameter bit          Coherent = 1'b1,   // 1 = DCU + snoopy bus, 0 = baseline
  parameter int unsigned NumPes   = 4,
  parameter int unsigned NumWays  = 2,
  parameter int unsigned NumSets  = 64,
  parameter int unsigned ClkDiv   = 3,      // 300 MHz / ClkDiv = SoC clock
  // Snoop filter; see rtl/snoop/snoop_filter.sv. Its cost is the point of the
  // filtered build, so it is a generic rather than a hardcoded choice.
  parameter bit          SnoopFilter = 1'b0,
  // Program baked into the shared instruction memory. The build passes an
  // absolute path; without one the implemented design has nothing to fetch.
  parameter string       ProgramHex = ""
) (
  input  logic       clk300_p_i,
  input  logic       clk300_n_i,
  input  logic       cpu_reset_i,          // CPU_RESET push button, active high
  input  logic [3:0] dip_i,                // GPIO_DIP_SW3..0
  input  logic [3:0] pb_i,                 // GPIO_PB_SW3..0
  output logic [3:0] led_o                 // GPIO_LED_3..0_LS
);

  // ---------------------------------------------------------------------------
  //  Clock: 300 MHz differential in, one global buffer with an integer divide.
  // ---------------------------------------------------------------------------
  logic clk_ref, clk;

  IBUFDS u_ibufds (.I(clk300_p_i), .IB(clk300_n_i), .O(clk_ref));

  BUFGCE_DIV #(
    .BUFGCE_DIVIDE (ClkDiv)
  ) u_bufgce_div (
    .I   (clk_ref),
    .CE  (1'b1),
    .CLR (1'b0),
    .O   (clk)
  );

  // ---------------------------------------------------------------------------
  //  Reset: two-flop synchroniser, then a 128-cycle stretch. Configuration
  //  leaves every flop at 0, so the SoC comes out of reset on its own after
  //  128 clocks whether or not the button is ever pressed.
  // ---------------------------------------------------------------------------
  (* ASYNC_REG = "TRUE" *) logic [1:0] rst_sync_q;
  logic [6:0] rst_cnt_q;

  //  This one register drives every asynchronous reset in the SoC, which is
  //  around fifteen thousand CLR pins spread over the die. Left as a single
  //  driver the removal check on reset release fails on distance alone: the
  //  worst path measured 2.419 ns from here to a flop in the far PE, of which
  //  2.336 ns (97%) was routing, and it failed by 30 ps. It is placement luck
  //  either way -- the same RTL met the check in one build and missed it in
  //  two others -- so the fix is to stop asking one wire to cross the chip.
  //
  //  MAX_FANOUT makes the tool replicate this register and place each copy
  //  near the flops it clears. Replication is the right mechanism rather than
  //  writing copies by hand, because soc_top takes a single rst_ni and adding
  //  a per-PE reset port would change the design the simulator verifies.
  (* MAX_FANOUT = 200 *) logic rst_n_q;

  always_ff @(posedge clk) begin
    rst_sync_q <= {rst_sync_q[0], cpu_reset_i};

    if (rst_sync_q[1]) begin
      rst_cnt_q <= '0;
      rst_n_q   <= 1'b0;
    end else if (rst_cnt_q != '1) begin
      rst_cnt_q <= rst_cnt_q + 7'd1;
      rst_n_q   <= 1'b0;
    end else begin
      rst_n_q   <= 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  //  Static inputs. DIP0 is the run switch; the rest select the readout word.
  // ---------------------------------------------------------------------------
  (* ASYNC_REG = "TRUE" *) logic [3:0] dip_sync_q, dip_q;
  (* ASYNC_REG = "TRUE" *) logic [3:0] pb_sync_q,  pb_q;

  always_ff @(posedge clk) begin
    dip_sync_q <= dip_i;  dip_q <= dip_sync_q;
    pb_sync_q  <= pb_i;   pb_q  <= pb_sync_q;
  end

  logic fetch_enable;
  assign fetch_enable = dip_q[0];

  // ---------------------------------------------------------------------------
  //  The SoC
  // ---------------------------------------------------------------------------
  logic [NumPes-1:0]    done, core_sleep;
  logic [NumPes*32-1:0] exit_code;
  logic                 putchar_valid;
  logic [7:0]           putchar_data;
  logic [31:0]          cycle_cnt;

  logic [NumPes*32-1:0] p_rd_hit, p_rd_miss, p_wr_hit, p_wr_miss, p_busy;
  logic [NumPes*32-1:0] p_stall_snoop, p_stall_s2, p_rd_wait, p_wr_wait;

  soc_top #(
    .NumPes    (NumPes),
    .Coherent  (Coherent),
    .NumWays   (NumWays),
    .NumSets   (NumSets),
    .SimemInit   (ProgramHex),
    .SnoopFilter (SnoopFilter)
  ) u_soc (
    .clk_i               (clk),
    .rst_ni              (rst_n_q),
    .fetch_enable_i      (fetch_enable),

    .done_o              (done),
    .exit_code_o         (exit_code),
    .putchar_valid_o     (putchar_valid),
    .putchar_data_o      (putchar_data),
    .cycle_o             (cycle_cnt),
    .core_sleep_o        (core_sleep),

    .perf_rd_hit_o       (p_rd_hit),
    .perf_rd_miss_o      (p_rd_miss),
    .perf_wr_hit_o       (p_wr_hit),
    .perf_wr_miss_o      (p_wr_miss),
    .perf_busy_o         (p_busy),
    .perf_stall_snoop_o  (p_stall_snoop),
    .perf_stall_s2_o     (p_stall_s2),
    .perf_rd_wait_o      (p_rd_wait),
    .perf_wr_wait_o      (p_wr_wait)
  );

  // ---------------------------------------------------------------------------
  //  Character stream: keep the last byte and count how many were emitted, so
  //  the putchar port has a sink and a run can be identified from the LEDs.
  // ---------------------------------------------------------------------------
  logic [7:0]  last_char_q;
  logic [15:0] char_cnt_q;

  always_ff @(posedge clk) begin
    if (!rst_n_q) begin
      last_char_q <= 8'd0;
      char_cnt_q  <= 16'd0;
    end else if (putchar_valid) begin
      last_char_q <= putchar_data;
      char_cnt_q  <= char_cnt_q + 16'd1;
    end
  end

  // ---------------------------------------------------------------------------
  //  Readout. 42 words: the cycle counter, a status word, one exit code per PE
  //  and the nine cache counters of each PE.
  // ---------------------------------------------------------------------------
  localparam int unsigned NumCnt  = 9;
  localparam int unsigned NumWord = 2 + NumPes + NumCnt * NumPes;   // 42

  logic [NumPes*32-1:0] cnt_bus [NumCnt];
  assign cnt_bus[0] = p_rd_hit;
  assign cnt_bus[1] = p_rd_miss;
  assign cnt_bus[2] = p_wr_hit;
  assign cnt_bus[3] = p_wr_miss;
  assign cnt_bus[4] = p_busy;
  assign cnt_bus[5] = p_stall_snoop;
  assign cnt_bus[6] = p_stall_s2;
  assign cnt_bus[7] = p_rd_wait;
  assign cnt_bus[8] = p_wr_wait;

  logic [31:0] words [NumWord];

  always_comb begin
    words[0] = cycle_cnt;
    words[1] = {char_cnt_q, last_char_q, 4'(core_sleep), 4'(done)};
    for (int unsigned p = 0; p < NumPes; p++) begin
      words[2 + p] = exit_code[p*32 +: 32];
    end
    for (int unsigned c = 0; c < NumCnt; c++) begin
      for (int unsigned p = 0; p < NumPes; p++) begin
        words[2 + NumPes + c*NumPes + p] = cnt_bus[c][p*32 +: 32];
      end
    end
  end

  logic [5:0]  sel_q;
  logic [31:0] obs_q;

  always_ff @(posedge clk) begin
    sel_q <= {pb_q[1:0], dip_q[3:0]};
    obs_q <= (sel_q < 6'(NumWord)) ? words[sel_q] : 32'd0;
  end

  // Walk the eight nibbles of the selected word across the LEDs, roughly three
  // per second at 100 MHz, so a word can be read off the board by eye.
  logic [27:0] tick_q;
  always_ff @(posedge clk) tick_q <= tick_q + 28'd1;

  always_ff @(posedge clk) begin
    led_o <= obs_q[{tick_q[27:25], 2'b00} +: 4];
  end

endmodule
