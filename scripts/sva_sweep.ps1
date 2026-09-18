# =============================================================================
#  sva_sweep.ps1 -- run the filter's assertions (tb/sva/filter_sva.sv) over many
#  stress interleavings and total up what they checked.
#
#  Why this exists
#    The paper used to support the fill-in-flight term with a counter that fired
#    on 20 of 2,241 granted invalidations. A counter says a case was reached; it
#    does not say the design was right in the cycles where it was not reached.
#    The assertions check every cycle, and this totals their coverage so the
#    paper can quote it.
#
#  It rewrites `define STRESS_SEED in the testbench for each run, exactly as
#  seed_sweep.ps1 does and for the same reason (xvlog's -d NAME=VALUE parser
#  splits at the "="), and restores the file in a finally block.
#
#  Usage:  powershell -ExecutionPolicy Bypass -File scripts\sva_sweep.ps1
#          powershell -ExecutionPolicy Bypass -File scripts\sva_sweep.ps1 -Seeds 10 -Mutant
# =============================================================================
param(
  [int]$Seeds = 10,
  [switch]$Mutant      # remove the fill-in-flight term, to check the properties bite
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$tb   = Join-Path $root "tb\system\tb_coherent_subsystem.sv"

$SeedTable = @(
  "9E3779B1", "3C6EF372", "DAA66D2B", "78DDE6E4", "1715609D",
  "B54CDA56", "5384540F", "F1BBCDC8", "8FF34781", "2E2AC13A"
)
if ($Seeds -gt $SeedTable.Count) { throw "SeedTable holds $($SeedTable.Count) seeds" }

$defines = "SNOOP_FILTER FILTER_SVA"
if ($Mutant) { $defines += " NO_FILL_TERM" }

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$original  = [System.IO.File]::ReadAllText($tb)
if ($original -notmatch "(?m)^``define STRESS_SEED .*$") { throw "no STRESS_SEED in $tb" }

$rows = @()
try {
  for ($s = 1; $s -le $Seeds; $s++) {
    $seed    = "32'h" + $SeedTable[$s - 1]
    $patched = $original -replace "(?m)^``define STRESS_SEED .*$", "``define STRESS_SEED $seed"
    [System.IO.File]::WriteAllText($tb, $patched, $utf8NoBom)

    $log = Join-Path $root "sim\sva_seed_$s.log"
    powershell -ExecutionPolicy Bypass -File (Join-Path $root "sim\run_xsim.ps1") `
      -Tb tb_coherent_subsystem -Defines $defines -OutDir "sim\sva_$s" > $log 2>&1

    $txt  = Get-Content $log -Raw
    $cyc = 0; $sup = 0; $swp = 0
    if ($txt -match "SVA (\d+) cycles, (\d+) suppressions checked, mirror swept (\d+) times") {
      $cyc = [int]$Matches[1]; $sup = [int]$Matches[2]; $swp = [int]$Matches[3]
    }
    # SVA failures print through $error and do NOT fail the testbench's own
    # check count, so they have to be looked for explicitly.
    $fails = ([regex]::Matches($txt, "SVA P\d")).Count
    $pass  = $txt -match "tb_coherent_subsystem PASSED"

    $rows += [pscustomobject]@{
      Seed = $s; Cycles = $cyc; Suppressions = $sup; Sweeps = $swp
      SvaFailures = $fails; TbPassed = $pass
    }
    Write-Host ("seed {0,2}  {1,6} cycles  {2,4} suppressions  {3,3} sweeps  {4}" -f `
      $s, $cyc, $sup, $swp, $(if ($fails -eq 0 -and $pass) { "all properties held" }
                              else { "$fails ASSERTION FAILURES" }))
  }
}
finally {
  [System.IO.File]::WriteAllText($tb, $original, $utf8NoBom)
}

$tc = ($rows | Measure-Object Cycles       -Sum).Sum
$ts = ($rows | Measure-Object Suppressions -Sum).Sum
$tw = ($rows | Measure-Object Sweeps       -Sum).Sum
$tf = ($rows | Measure-Object SvaFailures  -Sum).Sum

Write-Host ""
Write-Host "=============================================================="
Write-Host ("{0} runs: {1} cycles, {2} suppressions checked, {3} full mirror sweeps" -f `
            $rows.Count, $tc, $ts, $tw)
Write-Host ("mirror entries compared: {0}" -f ($tw * 512))
if ($tf -eq 0) { Write-Host "all properties held in every cycle of every run" }
else           { Write-Host "$tf ASSERTION FAILURES" -ForegroundColor Red }
Write-Host "=============================================================="

$out = Join-Path $root "results\sva_sweep.csv"
$rows | Export-Csv -NoTypeInformation -Path $out
Write-Host "wrote $out"
