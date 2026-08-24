# =============================================================================
#  run_xsim.ps1 -- compile and run one testbench with Vivado xsim.
#
#  Usage:  powershell -File sim/run_xsim.ps1 -Tb tb_dcu
#          powershell -File sim/run_xsim.ps1 -Tb tb_dcu -Wave
# =============================================================================
param(
  [string]$Tb        = "tb_dcu",
  [switch]$Wave,
  [string]$Plusargs = "",
  [string]$VivadoBin = "D:\2025.1\Vivado\bin"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$out  = Join-Path $root "sim\out"
New-Item -ItemType Directory -Force -Path $out | Out-Null
Push-Location $out

$xvlog = Join-Path $VivadoBin "xvlog.bat"
$xelab = Join-Path $VivadoBin "xelab.bat"
$xsim  = Join-Path $VivadoBin "xsim.bat"

# ---- source list -------------------------------------------------------------
$srcs = @(
  "$root\rtl\include\cache_pkg.sv",
  "$root\rtl\cache\cache_ram.sv",
  "$root\rtl\cache\dcu_hcl.sv",
  "$root\rtl\cache\dcu.sv",
  "$root\rtl\snoop\rr_arbiter.sv",
  "$root\rtl\snoop\invalidation_table.sv",
  "$root\rtl\snoop\link_register.sv",
  "$root\rtl\snoop\snoopy_bus.sv",
  "$root\rtl\soc\coherent_subsystem.sv",
  "$root\tb\models\mem_model.sv",
  "$root\tb\models\shared_mem_model.sv",
  "$root\tb\unit\tb_dcu.sv",
  "$root\tb\unit\tb_snoopy_bus.sv",
  "$root\tb\system\tb_coherent_subsystem.sv"
) | Where-Object { Test-Path $_ }

Write-Host "== xvlog ==" -ForegroundColor Cyan
& $xvlog -sv --incr --nolog @srcs
if ($LASTEXITCODE -ne 0) { Pop-Location; throw "xvlog failed" }

Write-Host "== xelab $Tb ==" -ForegroundColor Cyan
$elabArgs = @("-debug", "typical", "--nolog", "-timescale", "1ns/1ps", "-s", "${Tb}_snap", $Tb)
& $xelab @elabArgs
if ($LASTEXITCODE -ne 0) { Pop-Location; throw "xelab failed" }

Write-Host "== xsim $Tb ==" -ForegroundColor Cyan
$tcl = "run_$Tb.tcl"
if ($Wave) {
  @("log_wave -recursive *", "run all", "quit") | Set-Content -Encoding ascii $tcl
} else {
  @("run all", "quit") | Set-Content -Encoding ascii $tcl
}
if ($Plusargs -ne "") { & $xsim "${Tb}_snap" -tclbatch $tcl --nolog -testplusarg $Plusargs }
else { & $xsim "${Tb}_snap" -tclbatch $tcl --nolog }
$rc = $LASTEXITCODE
Pop-Location
exit $rc
