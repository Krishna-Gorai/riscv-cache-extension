# =============================================================================
#  zcu104.xdc -- pin and timing constraints for fpga_top on a ZCU104
#                (Zynq UltraScale+ XCZU7EV-FFVC1156-2-E).
#
#  Pin locations and I/O standards are taken from the ZCU104 board definition
#  shipped with Vivado (XilinxBoardStore/boards/Xilinx/zcu104/1.1/part0_pins.xml),
#  not from the schematic by hand.
#
#  There is one real clock: the 300 MHz programmable differential oscillator on
#  the DDR4 bank. Everything else on this design is a switch, a button or an
#  LED -- static or human-speed -- so the only timing that matters is the SoC
#  clock derived from it. The board pins are cut with false paths rather than
#  given fictitious input and output delays, because inventing a number for a
#  push button would put made-up paths into the same timing report the SoC's
#  own Fmax is read from.
# =============================================================================

# -----------------------------------------------------------------------------
#  Clock: Programmable Differential Clock, 300 MHz, DDR4 bank (1.2 V)
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN AH18 IOSTANDARD DIFF_SSTL12} [get_ports clk300_p_i]
set_property -dict {PACKAGE_PIN AH17 IOSTANDARD DIFF_SSTL12} [get_ports clk300_n_i]

create_clock -period 3.333 -name clk300 [get_ports clk300_p_i]

# The SoC clock is clk300 divided by BUFGCE_DIV. Vivado derives that generated
# clock automatically; the four BUFGCEs that gate each core's clock on WFI are
# likewise derived. Nothing here needs to name them.

# -----------------------------------------------------------------------------
#  Reset: CPU_RESET push button
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN M11 IOSTANDARD LVCMOS33} [get_ports cpu_reset_i]

# -----------------------------------------------------------------------------
#  DIP switches: [0] is the run switch, [3:1] pick the readout word
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN E4 IOSTANDARD LVCMOS33} [get_ports {dip_i[0]}]
set_property -dict {PACKAGE_PIN D4 IOSTANDARD LVCMOS33} [get_ports {dip_i[1]}]
set_property -dict {PACKAGE_PIN F5 IOSTANDARD LVCMOS33} [get_ports {dip_i[2]}]
set_property -dict {PACKAGE_PIN F4 IOSTANDARD LVCMOS33} [get_ports {dip_i[3]}]

# -----------------------------------------------------------------------------
#  Push buttons: the two high bits of the readout word select
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN B4 IOSTANDARD LVCMOS33} [get_ports {pb_i[0]}]
set_property -dict {PACKAGE_PIN C4 IOSTANDARD LVCMOS33} [get_ports {pb_i[1]}]
set_property -dict {PACKAGE_PIN B3 IOSTANDARD LVCMOS33} [get_ports {pb_i[2]}]
set_property -dict {PACKAGE_PIN C3 IOSTANDARD LVCMOS33} [get_ports {pb_i[3]}]

# -----------------------------------------------------------------------------
#  LEDs: the nibble of the selected readout word currently on show
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN D5 IOSTANDARD LVCMOS33} [get_ports {led_o[0]}]
set_property -dict {PACKAGE_PIN D6 IOSTANDARD LVCMOS33} [get_ports {led_o[1]}]
set_property -dict {PACKAGE_PIN A5 IOSTANDARD LVCMOS33} [get_ports {led_o[2]}]
set_property -dict {PACKAGE_PIN B5 IOSTANDARD LVCMOS33} [get_ports {led_o[3]}]

# -----------------------------------------------------------------------------
#  Asynchronous board I/O
# -----------------------------------------------------------------------------
set_false_path -from [get_ports cpu_reset_i]
set_false_path -from [get_ports {dip_i[*]}]
set_false_path -from [get_ports {pb_i[*]}]
set_false_path -to   [get_ports {led_o[*]}]
