# =============================================================================
#  run_fig5.ps1 -- memory-copy latency against transfer size.
#
#  Kamaleldin et al.'s Fig. 5 plots memcpy latency for coherent and
#  non-coherent multi-core systems over 4, 8, 16 and 32 KiB, and reports the
#  latency "approximately reduced by 50 %" with the data cache.
#
#  Whether that reproduces depends entirely on how slow the shared memory is,
#  which their text does not state. At our default MemLat=2 -- a BRAM answering
#  almost immediately -- memcpy has nothing to hide and the extension LOSES
#  2.5 %; at MemLat=20 it wins 56 %, which is close to their figure. So this
#  sweeps size at BOTH latencies rather than picking the one that agrees, and
#  the figure carries both panels.
#
#  Three configurations per point:
#    tb_bench_nc*  non-coherent    -- their "4-Cores w/o Data Cache"
#    tb_bench*     coherent        -- their "4-Cores w/ Data Cache"
#    tb_bench_sf*  coherent+filter -- this work
#
#  Appends to results/fig5.csv and skips pairs already present, so an
#  interrupted sweep resumes. A run that fails its golden check is not written.
#
#  Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\run_fig5.ps1
# =============================================================================
param(
  [string]$Csv = "results\fig5.csv"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$csv  = Join-Path $root $Csv

$sizes = @(
  @{k="memcpy_4k";  size="4"},
  @{k="memcpy_8k";  size="8"},
  @{k="memcpy_16k"; size="16"},
  @{k="memcpy_32k"; size="32"}
)

# MemLat 2 is the default build; the _l20 twins are the same designs with a
# twentyfold slower shared memory.
$configs = @(
  @{tb="tb_bench_nc";     cfg="noncoherent"; lat="2"},
  @{tb="tb_bench";        cfg="coherent";    lat="2"},
  @{tb="tb_bench_sf";     cfg="filtered";    lat="2"},
  @{tb="tb_bench_nc_l8";  cfg="noncoherent"; lat="8"},
  @{tb="tb_bench_l8";     cfg="coherent";    lat="8"},
  @{tb="tb_bench_sf_l8";  cfg="filtered";    lat="8"},
  @{tb="tb_bench_nc_l20"; cfg="noncoherent"; lat="20"},
  @{tb="tb_bench_l20";    cfg="coherent";    lat="20"},
  @{tb="tb_bench_sf_l20"; cfg="filtered";    lat="20"}
)

if (-not (Test-Path $csv)) {
  New-Item -ItemType Directory -Force -Path (Split-Path $csv) | Out-Null
  "kib,memlat,config,cycles" | Out-File -Encoding ascii $csv
}
$done = @{}
Get-Content $csv | Select-Object -Skip 1 | ForEach-Object {
  $f = $_.Split(",")
  if ($f.Count -ge 3) { $done["$($f[0])_$($f[1])_$($f[2])"] = $true }
}

foreach ($s in $sizes) {
  foreach ($c in $configs) {
    $key = "$($s.size)_$($c.lat)_$($c.cfg)"
    if ($done.ContainsKey($key)) { Write-Host "skip  $key"; continue }

    $hex = Join-Path $root "sw\build\soc_bench_$($s.k).hex"
    if (-not (Test-Path $hex)) { Write-Host "MISSING $hex" -ForegroundColor Red; continue }

    $t0 = Get-Date
    Write-Host "run   $($s.size)KiB memlat=$($c.lat) $($c.cfg) ..." -NoNewline
    $out = powershell -NoProfile -ExecutionPolicy Bypass `
             -File (Join-Path $root "sim\run_xsim.ps1") `
             -Tb $c.tb -Hex $hex -OutDir "sim\f5_$($s.k)_$($c.tb)" 2>&1

    $cyc = $null
    $m = $out | Select-String -Pattern "slowest_pe_cycles=(\d+)" | Select-Object -First 1
    if ($m -and $m -match "slowest_pe_cycles=(\d+)") { $cyc = [int]$Matches[1] }
    $ok = ($out | Select-String -Pattern "PASSED" | Select-Object -First 1) -ne $null

    $dt = ((Get-Date) - $t0).TotalMinutes
    if ($cyc -and $ok) {
      "$($s.size),$($c.lat),$($c.cfg),$cyc" | Out-File -Encoding ascii -Append $csv
      Write-Host (" {0} cycles  [{1:N1} min]" -f $cyc, $dt) -ForegroundColor Green
    } else {
      Write-Host (" FAILED (passed={0}, cycles={1})" -f $ok, $cyc) -ForegroundColor Red
      ($out | Select-Object -Last 10) | ForEach-Object { Write-Host "      $_" }
    }
  }
}

Write-Host ""
Get-Content $csv
Write-Host "FIG5_SWEEP_DONE"
