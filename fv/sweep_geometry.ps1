# =============================================================================
#  sweep_geometry.ps1 -- find the largest geometry at which the filter's safety
#  property can be proved, and record how long each takes.
#
#  The property is per-entry with a symbolic index, so the geometry does not
#  change what is being proved; it changes how much state the solver carries.
#  The two dimensions that matter to the argument -- four cores and two ways --
#  are held at the values the paper uses, and the sweep varies the number of
#  sets and the address width.
#
#  Usage:  powershell -ExecutionPolicy Bypass -File fv\sweep_geometry.ps1
# =============================================================================
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
$fv   = Join-Path $root "fv\filter_fv.sv"
$env:PATH = "C:\tools\oss-cad-suite\bin;C:\tools\oss-cad-suite\lib;" + $env:PATH

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$original  = [System.IO.File]::ReadAllText($fv)

# sets, address width  (tag width = addr - log2(sets) - 4)
$geoms = @(
  @(2, 9), @(4, 12), @(8, 16), @(16, 20), @(32, 26), @(64, 32)
)

$rows = @()
try {
  foreach ($g in $geoms) {
    $sets = $g[0]; $aw = $g[1]
    $patched = $original `
      -replace "parameter int unsigned NumSets  = \d+,", "parameter int unsigned NumSets  = $sets," `
      -replace "parameter int unsigned AddrW    = \d+,", "parameter int unsigned AddrW    = $aw,"
    [System.IO.File]::WriteAllText($fv, $patched, $utf8NoBom)

    $log = Join-Path $root "fv\sweep_${sets}_${aw}.log"
    $t = Measure-Command { sby -f (Join-Path $root "fv\filter_prove.sby") *>&1 | Out-File -Encoding utf8 $log }
    $txt = Get-Content $log -Raw
    $status = if ($txt -match "DONE \(PASS") { "PROVED" }
              elseif ($txt -match "DONE \(FAIL") { "FAILED" }
              else { "TOOL ERROR" }
    $rows += [pscustomobject]@{
      Sets = $sets; AddrW = $aw; TagW = $aw - [math]::Log($sets,2) - 4
      Status = $status; Seconds = [math]::Round($t.TotalSeconds,1)
    }
    Write-Host ("{0,3} sets, {1,2}-bit addr : {2,-10} {3,6} s" -f $sets, $aw, $status, [math]::Round($t.TotalSeconds,1))
  }
}
finally {
  [System.IO.File]::WriteAllText($fv, $original, $utf8NoBom)
}

$rows | Export-Csv -NoTypeInformation -Path (Join-Path $root "results\fv_geometry.csv")
Write-Host "wrote results\fv_geometry.csv"
