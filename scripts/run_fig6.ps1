# =============================================================================
#  run_fig6.ps1 -- execution time against problem size, for the reference's
#  Fig. 6 comparison.
#
#  Kamaleldin et al.'s Fig. 6 plots total execution time of matrix
#  multiplication, 2-D convolution and FFT over coherent and non-coherent
#  multi-core systems, sweeping PROBLEM SIZE at a fixed clock. Everything this
#  project had measured before swept memory latency instead, at one size per
#  kernel, so none of it could be plotted on those axes.
#
#  This produces the missing points. Three configurations per (kernel, size):
#
#    tb_bench_nc   non-coherent   -- the reference's "Cores w/o Data Cache"
#    tb_bench      coherent       -- the reference's "Cores w/ Data Cache"
#    tb_bench_sf   coherent+filter-- this work, absent from the reference
#
#  Ordered cheapest-first on purpose. matmul at 128x128 is roughly eight times
#  the work of 64x64 and its non-coherent build eight times that again, so it
#  runs last: everything else is on disk before the long pole starts, and an
#  interrupted sweep still yields a usable figure for two kernels of three.
#
#  Appends to results/fig6.csv, and SKIPS any (kernel, tb) pair already in it,
#  so an interrupted run resumes rather than repeating hours of simulation.
#
#  Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\run_fig6.ps1
#          ... -Only "conv2d_32,fft_512"      restrict to some kernels
# =============================================================================
param(
  [string]$Only = "",
  [string]$Csv  = "results\fig6.csv"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$csv  = Join-Path $root $Csv

# Cheapest first; matmul_128 last. The size column is what the figure's x-axis
# shows, kept here so the plot script never has to parse a kernel name.
$work = @(
  @{k="conv2d_32";  kern="conv2d"; size="32x32"},
  @{k="matmul_32";  kern="matmul"; size="32x32"},
  @{k="fft_512";    kern="fft";    size="512"},
  @{k="fft_1024";   kern="fft";    size="1024"},
  @{k="conv2d_128"; kern="conv2d"; size="128x128"},
  @{k="matmul_128"; kern="matmul"; size="128x128"},
  # Cache-blocked FFT: same transform, same golden, early stages run block-major.
  @{k="fftb_256";   kern="fftb";   size="256"},
  @{k="fftb_512";   kern="fftb";   size="512"},
  @{k="fftb_1024";  kern="fftb";   size="1024"}
)
if ($Only -ne "") {
  $want = $Only.Split(",") | ForEach-Object { $_.Trim() }
  $work = $work | Where-Object { $want -contains $_.k }
}

$configs = @(
  @{tb="tb_bench_nc"; cfg="noncoherent"},
  @{tb="tb_bench";    cfg="coherent"},
  @{tb="tb_bench_sf"; cfg="filtered"}
)

if (-not (Test-Path $csv)) {
  New-Item -ItemType Directory -Force -Path (Split-Path $csv) | Out-Null
  "kernel,size,config,cycles" | Out-File -Encoding ascii $csv
}
$done = @{}
Get-Content $csv | Select-Object -Skip 1 | ForEach-Object {
  $f = $_.Split(",")
  if ($f.Count -ge 3) { $done["$($f[0])_$($f[1])_$($f[2])"] = $true }
}

foreach ($w in $work) {
  foreach ($c in $configs) {
    $key = "$($w.kern)_$($w.size)_$($c.cfg)"
    if ($done.ContainsKey($key)) { Write-Host "skip  $key (already in csv)"; continue }

    $hex = Join-Path $root "sw\build\soc_bench_$($w.k).hex"
    if (-not (Test-Path $hex)) { Write-Host "MISSING IMAGE $hex" -ForegroundColor Red; continue }

    $t0 = Get-Date
    Write-Host "run   $key ..." -NoNewline
    $out = powershell -NoProfile -ExecutionPolicy Bypass `
             -File (Join-Path $root "sim\run_xsim.ps1") `
             -Tb $c.tb -Hex $hex -OutDir "sim\f6_$($w.k)_$($c.tb)" 2>&1

    # slowest_pe_cycles is the figure's quantity: the reference plots total
    # execution time of the kernel, which is when the last PE finishes.
    $cyc = $null
    $m = $out | Select-String -Pattern "slowest_pe_cycles=(\d+)" | Select-Object -First 1
    if ($m -and $m -match "slowest_pe_cycles=(\d+)") { $cyc = [int]$Matches[1] }
    $ok = ($out | Select-String -Pattern "PASSED" | Select-Object -First 1) -ne $null

    $dt = ((Get-Date) - $t0).TotalMinutes
    if ($cyc -and $ok) {
      "$($w.kern),$($w.size),$($c.cfg),$cyc" | Out-File -Encoding ascii -Append $csv
      Write-Host (" {0} cycles  [{1:N1} min]" -f $cyc, $dt) -ForegroundColor Green
    } else {
      # A failed golden check makes the number meaningless, so it is not
      # written. The figure must never contain a point from a run that did not
      # verify.
      Write-Host (" FAILED (passed={0}, cycles={1}) [{2:N1} min]" -f $ok, $cyc, $dt) -ForegroundColor Red
      ($out | Select-Object -Last 12) | ForEach-Object { Write-Host "      $_" }
    }
  }
}

Write-Host ""
Write-Host "=== $csv ==="
Get-Content $csv
Write-Host "FIG6_SWEEP_DONE"
