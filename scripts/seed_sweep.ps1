# =============================================================================
#  seed_sweep.ps1 -- run tb_coherent_subsystem over many stress interleavings.
#
#  Why this exists
#    The fill-in-flight race that snoopy_bus.sv now covers appeared ONCE in 211
#    granted invalidations on the default seed. A single run is exactly the
#    sample size that misses a bug like that, so any claim about it has to be
#    made across many interleavings rather than one.
#
#  Why it rewrites the source instead of passing a define
#    xvlog's argument parser splits `-d NAME=VALUE` at the "=" and then treats
#    the value as a file ("ERROR: [XSIM 43-4316] Can not find file: 3"). The
#    same parser mangles relative paths passed through -testplusarg, which is
#    why run_xsim.ps1 already stages the program image under a fixed name rather
#    than passing it. Rather than fight it a third time, this rewrites the
#    `define STRESS_SEED line in the testbench for each run and restores it
#    afterwards -- including on Ctrl-C, via the finally block.
#
#  Usage:  powershell -ExecutionPolicy Bypass -File scripts\seed_sweep.ps1
#          powershell -ExecutionPolicy Bypass -File scripts\seed_sweep.ps1 -Seeds 20
# =============================================================================
param(
  [int]$Seeds = 10,
  [string[]]$Modes = @("SNOOP_FILTER", "SNOOP_FILTER DIRECTED_INV")
)

$ErrorActionPreference = "Stop"

# Seeds as a literal table rather than computed. Generating them with a
# multiplicative hash cost three failed runs to PowerShell's cast/operator
# precedence -- [uint32](x) -band y casts before it masks and overflows -- and
# the values only need to be well spread and reproducible, not derived.
$SeedTable = @(
  "9E3779B1", "3C6EF372", "DAA66D2B", "78DDE6E4", "1715609D",
  "B54CDA56", "5384540F", "F1BBCDC8", "8FF34781", "2E2AC13A",
  "CC623AF3", "6A99B4AC", "08D12E65", "A708A81E", "454021D7",
  "E3779B90", "81AF1549", "1FE68F02", "BE1E08BB", "5C558274"
)
if ($Seeds -gt $SeedTable.Count) {
  throw "SeedTable holds $($SeedTable.Count) seeds; asked for $Seeds"
}
$root = Split-Path -Parent $PSScriptRoot
$tb   = Join-Path $root "tb\system\tb_coherent_subsystem.sv"

# .NET file IO rather than Get-/Set-Content: Set-Content -Encoding failed
# outright in this environment, and WriteAllText with an explicit no-BOM UTF8
# encoder also guarantees we never prepend a BOM to a file xvlog has to read.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$original = [System.IO.File]::ReadAllText($tb)
if ($original -notmatch "(?m)^``define STRESS_SEED .*$") {
  throw "no ``define STRESS_SEED line in $tb"
}

$results = @()

try {
  foreach ($mode in $Modes) {
    $tag = if ($mode -match "DIRECTED") { "directed" } else { "suppress" }

    for ($s = 1; $s -le $Seeds; $s++) {
      # 32-bit seeds spread across the space rather than 1..N, so consecutive
      # runs do not produce near-identical streams.
      $seed = "32'h" + $SeedTable[$s - 1]
      $patched = $original -replace "(?m)^``define STRESS_SEED .*$", "``define STRESS_SEED $seed"
      [System.IO.File]::WriteAllText($tb, $patched, $utf8NoBom)

      $out = powershell -ExecutionPolicy Bypass -File (Join-Path $root "sim\run_xsim.ps1") `
               -Tb tb_coherent_subsystem -Defines $mode -OutDir "sim\sweep_${tag}_$s" 2>&1

      $verdict = ($out | Select-String -Pattern "PASSED|FAILED"  | Select-Object -First 1)
      $race    = ($out | Select-String -Pattern "FILLRACE"       | Select-Object -First 1)

      $granted = 0; $saved = 0
      if ($race -match "granted=(\d+) saved_by_fill_term=(\d+)") {
        $granted = [int]$Matches[1]; $saved = [int]$Matches[2]
      }
      $ok = ($verdict -match "PASSED")

      $results += [pscustomobject]@{
        Mode = $tag; Seed = $s; Passed = $ok; Granted = $granted; Saved = $saved
      }
      Write-Host ("{0,-9} seed {1,2}  {2,-7} granted={3,-5} would_be_wrong={4}" -f `
                  $tag, $s, $(if ($ok) {"PASSED"} else {"FAILED"}), $granted, $saved)
    }
  }
}
finally {
  [System.IO.File]::WriteAllText($tb, $original, $utf8NoBom)
  Write-Host "restored $tb" -ForegroundColor DarkGray
}

# -----------------------------------------------------------------------------
#  Summary. "would_be_wrong" is the number of granted invalidations where no
#  other cache HELD the line but one was FETCHING it: the cases a mirror of
#  committed tags alone would have got wrong. Every one of them is a coherence
#  violation the fill-in-flight term prevents.
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "=============================================================="
foreach ($m in ($results | Select-Object -ExpandProperty Mode -Unique)) {
  $r  = $results | Where-Object { $_.Mode -eq $m }
  $g  = ($r | Measure-Object Granted -Sum).Sum
  $sv = ($r | Measure-Object Saved   -Sum).Sum
  $hit = ($r | Where-Object { $_.Saved -gt 0 }).Count
  $bad = ($r | Where-Object { -not $_.Passed }).Count
  $pct = if ($g -gt 0) { 100.0 * $sv / $g } else { 0 }
  Write-Host ("{0,-9} {1} runs, {2} failed | granted {3}, would_be_wrong {4} ({5:N2}%), in {6}/{1} runs" -f `
              $m, $r.Count, $bad, $g, $sv, $pct, $hit)
}
Write-Host "=============================================================="

$csv = Join-Path $root "results\seed_sweep.csv"
New-Item -ItemType Directory -Force -Path (Split-Path $csv) | Out-Null
$results | Export-Csv -NoTypeInformation -Encoding ASCII $csv
Write-Host "wrote $csv"
