# =============================================================================
#  run_fpga_sim.ps1 -- simulate fpga_top the way the board runs it.
#
#  Usage:
#     powershell -File sim/run_fpga_sim.ps1                  # RTL, self-boot
#     powershell -File sim/run_fpga_sim.ps1 -Netlist <file>  # post-impl netlist
#
#  Two things make this different from run_xsim.ps1, which drives soc_top:
#
#    * SYNTHESIS is defined, so the memories initialise from ProgramHex the way
#      they do in a build, and the cores take the BUFGCE clock gate rather than
#      the behavioural one. Nothing is loaded through the hierarchy, so the run
#      proves the design can obtain a program on its own.
#    * fpga_top instantiates IBUFDS, BUFGCE_DIV and BUFGCE, so the Xilinx
#      simulation libraries come in and glbl must be elaborated alongside the
#      top for the primitives' global reset.
# =============================================================================
param(
  [string]$Netlist   = "",
  [switch]$Wave,
  [string]$OutDir    = "sim\out_fpga",
  [string]$VivadoBin = "C:\Xilinx\xic\2025.1\Vivado\bin",
  [string]$VivadoRoot = "C:\Xilinx\xic\2025.1\Vivado"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$out  = Join-Path $root $OutDir
New-Item -ItemType Directory -Force -Path $out | Out-Null
Push-Location $out

$xvlog = Join-Path $VivadoBin "xvlog.bat"
$xelab = Join-Path $VivadoBin "xelab.bat"
$xsim  = Join-Path $VivadoBin "xsim.bat"
$glbl  = Join-Path $VivadoRoot "data\verilog\src\glbl.v"

$cv     = Join-Path $root "vendor\cv32e40p"
$cvRtl  = Join-Path $cv "rtl"

if ($Netlist -ne "") {
  # The netlist is self-contained: every module is a Xilinx primitive or a
  # flattened piece of the design, and the parameters are already baked in.
  if (-not (Test-Path $Netlist)) { Pop-Location; throw "netlist not found: $Netlist" }
  Write-Host "== xvlog (netlist) ==" -ForegroundColor Cyan
  & $xvlog -sv --incr --nolog $Netlist (Join-Path $root "tb\system\tb_fpga_top.sv") -d NETLIST
  if ($LASTEXITCODE -ne 0) { Pop-Location; throw "xvlog failed" }
  & $xvlog --incr --nolog $glbl
  if ($LASTEXITCODE -ne 0) { Pop-Location; throw "xvlog glbl failed" }
} else {
  $cvNames = @(
    "include\cv32e40p_apu_core_pkg.sv", "include\cv32e40p_fpu_pkg.sv",
    "include\cv32e40p_pkg.sv",
    "cv32e40p_if_stage.sv", "cv32e40p_cs_registers.sv",
    "cv32e40p_register_file_ff.sv", "cv32e40p_load_store_unit.sv",
    "cv32e40p_id_stage.sv", "cv32e40p_aligner.sv", "cv32e40p_decoder.sv",
    "cv32e40p_compressed_decoder.sv", "cv32e40p_fifo.sv",
    "cv32e40p_prefetch_buffer.sv", "cv32e40p_hwloop_regs.sv",
    "cv32e40p_mult.sv", "cv32e40p_int_controller.sv", "cv32e40p_ex_stage.sv",
    "cv32e40p_alu_div.sv", "cv32e40p_alu.sv", "cv32e40p_ff_one.sv",
    "cv32e40p_popcnt.sv", "cv32e40p_apu_disp.sv", "cv32e40p_controller.sv",
    "cv32e40p_obi_interface.sv", "cv32e40p_prefetch_controller.sv",
    "cv32e40p_sleep_unit.sv", "cv32e40p_core.sv", "cv32e40p_top.sv"
  )
  # The behavioural clock gate is left out on purpose: its own header forbids it
  # under SYNTHESIS, and the BUFGCE wrapper takes its place, exactly as in a build.
  $srcs = @($cvNames | ForEach-Object { Join-Path $cvRtl $_ })
  $srcs += @(
    "$root\rtl\include\cache_pkg.sv",
    "$root\rtl\cache\cache_ram.sv", "$root\rtl\cache\dcu_hcl.sv",
    "$root\rtl\cache\dcu.sv", "$root\rtl\cache\dcu_bypass.sv",
    "$root\rtl\axi\axi_xbar.sv", "$root\rtl\axi\axi_sram.sv",
    "$root\rtl\axi\axi_ctrl.sv", "$root\rtl\axi\axi_master_simple.sv",
    "$root\rtl\axi\axi_master_dcu.sv",
    "$root\rtl\snoop\rr_arbiter.sv", "$root\rtl\snoop\invalidation_table.sv",
    "$root\rtl\snoop\link_register.sv", "$root\rtl\snoop\snoopy_bus.sv",
    "$root\rtl\soc\coherent_subsystem.sv",
    "$root\rtl\pe\bridge_router.sv", "$root\rtl\pe\itcm.sv",
    "$root\rtl\pe\instr_bridge.sv", "$root\rtl\pe\data_bridge.sv",
    "$root\rtl\pe\pe_top.sv", "$root\rtl\soc\soc_top.sv",
    "$root\fpga\cv32e40p_fpga_clock_gate.sv",
    "$root\fpga\fpga_top.sv",
    "$root\tb\system\tb_fpga_top.sv"
  )
  $srcs = $srcs | Where-Object { Test-Path $_ }

  Write-Host "== xvlog ($($srcs.Count) files, SYNTHESIS defined) ==" -ForegroundColor Cyan
  & $xvlog -sv --incr --nolog -d SYNTHESIS -i (Join-Path $cvRtl "include") -i (Join-Path $cv "bhv") -i (Join-Path $cv "sva") @srcs
  if ($LASTEXITCODE -ne 0) { Pop-Location; throw "xvlog failed" }
  & $xvlog --incr --nolog $glbl
  if ($LASTEXITCODE -ne 0) { Pop-Location; throw "xvlog glbl failed" }
}

Write-Host "== xelab ==" -ForegroundColor Cyan
& $xelab --relax -debug typical --nolog -timescale 1ns/1ps `
         -L unisims_ver -L unimacro_ver -L secureip `
         -s tb_fpga_top_snap tb_fpga_top glbl
if ($LASTEXITCODE -ne 0) { Pop-Location; throw "xelab failed" }

Write-Host "== xsim ==" -ForegroundColor Cyan
$tcl = "run_fpga.tcl"
if ($Wave) { @("log_wave -recursive *", "run all", "quit") | Set-Content -Encoding ascii $tcl }
else       { @("run all", "quit") | Set-Content -Encoding ascii $tcl }
& $xsim tb_fpga_top_snap -tclbatch $tcl --nolog
$rc = $LASTEXITCODE
Pop-Location
exit $rc
