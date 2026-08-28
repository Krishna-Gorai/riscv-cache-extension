# =============================================================================
#  run_xsim.ps1 -- compile and run one testbench with Vivado xsim.
#
#  Usage:  powershell -File sim/run_xsim.ps1 -Tb tb_dcu
#          powershell -File sim/run_xsim.ps1 -Tb tb_coherent_subsystem
#          powershell -File sim/run_xsim.ps1 -Tb tb_pe -Hex sw/build/smoke.hex
#          powershell -File sim/run_xsim.ps1 -Tb tb_soc    -Hex sw/build/soc_par_smoke.hex
#          powershell -File sim/run_xsim.ps1 -Tb tb_soc_nc -Hex sw/build/soc_par_smoke.hex
#          add -Wave to log every signal for waveform inspection
# =============================================================================
param(
  [string]$Tb        = "tb_dcu",
  [switch]$Wave,
  [string]$Hex       = "",
  [string]$Plusargs  = "",
  [switch]$Reuse,          # reuse an existing snapshot: only the program image changed
  [string]$OutDir    = "sim\out",  # run directory; a second one lets two sims run at once

  [string]$VivadoBin = "C:\Xilinx\xic\2025.1\Vivado\bin"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$out  = Join-Path $root $OutDir
New-Item -ItemType Directory -Force -Path $out | Out-Null
Push-Location $out

$xvlog = Join-Path $VivadoBin "xvlog.bat"
$xelab = Join-Path $VivadoBin "xelab.bat"
$xsim  = Join-Path $VivadoBin "xsim.bat"

# ---- CV32E40P (git submodule) ------------------------------------------------
$cv    = Join-Path $root "vendor\cv32e40p"
$cvRtl = Join-Path $cv "rtl"

$incdirs = @()
$cvSrcs  = @()
if (Test-Path $cvRtl) {
  $incdirs = @(
    "-i", (Join-Path $cvRtl "include"),
    "-i", (Join-Path $cv "bhv"),
    "-i", (Join-Path $cv "bhv\include"),
    "-i", (Join-Path $cv "sva")
  )
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
  $cvSrcs = $cvNames | ForEach-Object { Join-Path $cvRtl $_ }
  $cvSrcs += (Join-Path $cv "bhv\cv32e40p_sim_clock_gate.sv")
}

# ---- project sources ---------------------------------------------------------
$srcs = @(
  "$root\rtl\include\cache_pkg.sv",
  "$root\rtl\cache\cache_ram.sv",
  "$root\rtl\cache\dcu_hcl.sv",
  "$root\rtl\cache\dcu.sv",
  "$root\rtl\cache\dcu_bypass.sv",
  "$root\rtl\axi\axi_xbar.sv",
  "$root\rtl\axi\axi_sram.sv",
  "$root\rtl\axi\axi_ctrl.sv",
  "$root\rtl\axi\axi_master_simple.sv",
  "$root\rtl\axi\axi_master_dcu.sv",
  "$root\rtl\snoop\rr_arbiter.sv",
  "$root\rtl\snoop\invalidation_table.sv",
  "$root\rtl\snoop\link_register.sv",
  "$root\rtl\snoop\snoopy_bus.sv",
  "$root\rtl\soc\coherent_subsystem.sv",
  "$root\rtl\pe\bridge_router.sv",
  "$root\rtl\pe\itcm.sv",
  "$root\rtl\pe\instr_bridge.sv",
  "$root\rtl\pe\data_bridge.sv",
  "$root\rtl\pe\pe_top.sv",
  "$root\rtl\soc\soc_top.sv",
  "$root\tb\models\mem_model.sv",
  "$root\tb\models\shared_mem_model.sv",
  "$root\tb\unit\tb_dcu.sv",
  "$root\tb\unit\tb_axi.sv",
  "$root\tb\system\tb_coherent_subsystem.sv",
  "$root\tb\system\tb_pe.sv",
  "$root\tb\system\tb_soc.sv",
  "$root\tb\system\tb_bench.sv"
) | Where-Object { Test-Path $_ }

# tb/models/core_stub.sv is deliberately absent: it defines a module called
# cv32e40p_top so that Icarus can build the SoC without the real core, and
# compiling it here would collide with the submodule.

# The PE testbenches need the core; the cache-only ones do not.
$needCore = @("tb_pe", "tb_soc", "tb_soc_nc",
              "tb_bench", "tb_bench_nc",
              "tb_bench_l8", "tb_bench_nc_l8",
              "tb_bench_l20", "tb_bench_nc_l20") -contains $Tb
$allSrcs  = if ($needCore) { $cvSrcs + $srcs } else { $srcs }
$allIncs  = if ($needCore) { $incdirs } else { @() }

$snapDir = Join-Path $out "xsim.dir\${Tb}_snap"
if ($Reuse -and (Test-Path $snapDir)) {
  Write-Host "== reusing snapshot ${Tb}_snap ==" -ForegroundColor DarkCyan
} else {
Write-Host "== xvlog ($($allSrcs.Count) files) ==" -ForegroundColor Cyan
& $xvlog -sv --incr --nolog @allIncs @allSrcs
if ($LASTEXITCODE -ne 0) { Pop-Location; throw "xvlog failed" }

Write-Host "== xelab $Tb ==" -ForegroundColor Cyan
$elabArgs = @("-debug", "typical", "--nolog", "-timescale", "1ns/1ps",
              "-s", "${Tb}_snap", $Tb)
if ($needCore) { $elabArgs = @("--relax") + $elabArgs }
& $xelab @elabArgs
if ($LASTEXITCODE -ne 0) { Pop-Location; throw "xelab failed" }
}

# Stage the program image under a fixed name: xsim's argument parser mangles
# relative paths passed through -testplusarg, so the testbench always reads
# "program.hex" from the run directory instead.
if ($Hex -ne "") {
  if (-not (Test-Path $Hex)) { Pop-Location; throw "hex image not found: $Hex" }
  Copy-Item -Force $Hex (Join-Path $out "program.hex")
  Write-Host "== program: $Hex ==" -ForegroundColor Cyan
}

Write-Host "== xsim $Tb ==" -ForegroundColor Cyan
$tcl = "run_$Tb.tcl"
if ($Wave) {
  @("log_wave -recursive *", "run all", "quit") | Set-Content -Encoding ascii $tcl
} else {
  @("run all", "quit") | Set-Content -Encoding ascii $tcl
}
if ($Plusargs -ne "") { & $xsim "${Tb}_snap" -tclbatch $tcl --nolog -testplusarg $Plusargs }
else                  { & $xsim "${Tb}_snap" -tclbatch $tcl --nolog }
$rc = $LASTEXITCODE
Pop-Location
exit $rc
