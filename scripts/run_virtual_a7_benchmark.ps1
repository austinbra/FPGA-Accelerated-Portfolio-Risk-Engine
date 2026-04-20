<#
.SYNOPSIS
  Simulate an Arty A7-100T run without hardware: Vivado xsim UART compute TB + CPU baseline.

.DESCRIPTION
  Runs the same RTL + UART stimulus as the board testbench, parses the DUT core_cycle counter from
  [VIRTUAL_A7] log line, and scales compute time by the STA target used for xc7a100t (default
  83.333 MHz = 12 ns period from constraints/arty_a7_100.xdc). Compares price and speedup vs
  the fixed-point C++ baseline using the same params file.

  Assumption: post-route cycle semantics match RTL simulation (same reset, same UART batch).
#>
param(
    [string]$ParamFile = "",
    [int]$NumLanes = 1,
    [double]$FclkHz = 83333333.333333333,
    [int]$XsimTimeoutSeconds = 7200,
    [string]$TimingReport = "",
    [string]$UtilReport = "",
    # verbose = full technical report. UartShaped = print a block shaped like uart_host.py --target both
    # (still includes a mandatory Provenance line; use for slides only together with that line).
    [ValidateSet("Verbose", "UartShaped")]
    [string]$ReportFormat = "Verbose"
)

$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
Set-Location $repo

if (-not $ParamFile) {
    $ParamFile = Join-Path $repo "baseline\cpp_fixed\params_example.txt"
}
if (-not (Test-Path $ParamFile)) {
    throw "Param file not found: $ParamFile"
}

function Q16FromDouble([double]$x) {
    return [int32][math]::Round([double]$x * 65536.0)
}

$kv = @{}
Get-Content $ParamFile | ForEach-Object {
    $line = $_.Trim()
    if (-not $line -or $line.StartsWith("#")) { return }
    $eq = $line.IndexOf("=")
    if ($eq -lt 1) { return }
    $k = $line.Substring(0, $eq).Trim()
    $v = $line.Substring($eq + 1).Trim()
    $kv[$k] = $v
}

$required = @("paths", "steps", "S0", "K", "r", "sigma", "T")
foreach ($r in $required) {
    if (-not $kv.ContainsKey($r)) { throw "Param file missing key: $r" }
}

$paths = [int]$kv["paths"]
$steps = [int]$kv["steps"]
$S0 = [double]$kv["S0"]
$K = [double]$kv["K"]
$rf = [double]$kv["r"]
$sig = [double]$kv["sigma"]
$Tt = [double]$kv["T"]
$opt = 0
if ($kv.ContainsKey("option_type")) { $opt = [int]$kv["option_type"] }

if ($NumLanes -lt 1) { throw "NumLanes must be >= 1" }
if (($paths % $NumLanes) -ne 0) {
    throw "paths ($paths) must be divisible by NumLanes ($NumLanes) (same rule as silicon)."
}

$plus = @(
    "paths=$paths",
    "steps=$steps",
    "S0=$(Q16FromDouble $S0)",
    "K=$(Q16FromDouble $K)",
    "r=$(Q16FromDouble $rf)",
    "sigma=$(Q16FromDouble $sig)",
    "T=$(Q16FromDouble $Tt)",
    "opt=$opt"
)

if ($ReportFormat -eq "Verbose") {
    Write-Host "Virtual A7-100T benchmark"
    Write-Host "  Param file:  $ParamFile"
    Write-Host "  NUM_LANES:   $NumLanes"
    Write-Host "  Assumed fclk: $FclkHz Hz (matches STA target in constraints/arty_a7_100.xdc)"
    Write-Host "  Plusargs:    $($plus -join ' ')"
}

$tb = Join-Path $PSScriptRoot "run_tb_top_uart_safe.ps1"
$simLog = Join-Path ([System.IO.Path]::GetTempPath()) ("virtual_a7_xsim_{0}.log" -f [Guid]::NewGuid().ToString("N"))

try {
    & $tb -ComputeMode -NumLanes $NumLanes -TestPlusarg $plus -XsimTimeoutSeconds $XsimTimeoutSeconds *>&1 | Tee-Object -FilePath $simLog
} catch {
    Write-Host "xsim invocation failed; full log: $simLog"
    throw
}

$txt = Get-Content $simLog -Raw
if ($txt -notmatch '\[VIRTUAL_A7\]\s+paths=(\d+)\s+steps=(\d+)\s+core_cycles=(\d+)\s+price_raw=(0x[0-9a-fA-F]+)\s+marker=(0x[0-9a-fA-F]+)') {
    throw "Could not parse [VIRTUAL_A7] line from simulation log. See: $simLog"
}

$simPaths = [int]$Matches[1]
$simSteps = [int]$Matches[2]
$coreCycles = [int64]$Matches[3]
$priceRaw = $Matches[4]
$marker = $Matches[5]

if ($simPaths -ne $paths -or $simSteps -ne $steps) {
    Write-Warning "Sim reported paths/steps ($simPaths,$simSteps) differ from file ($paths,$steps); check TB."
}

$period = 1.0 / $FclkHz
$fpgaComputeS = [double]$coreCycles * $period

# CPU baseline (same param file as uart_host)
$cpuLog = Join-Path ([System.IO.Path]::GetTempPath()) ("virtual_a7_cpu_{0}.log" -f [Guid]::NewGuid().ToString("N"))
& python (Join-Path $repo "src\uart_host.py") @(
    "--mode", "benchmark",
    "--target", "cpu",
    "--param-file", $ParamFile
) *>&1 | Tee-Object -FilePath $cpuLog
if ($LASTEXITCODE -ne 0) {
    throw "uart_host.py --target cpu failed (exit $LASTEXITCODE). Log: $cpuLog"
}

$cpuTxt = Get-Content $cpuLog -Raw
if ($cpuTxt -notmatch '\[CPU\]\s+price=([0-9eE\+\-\.]+)\s+runtime_s=([0-9eE\+\-\.]+)') {
    throw "Could not parse [CPU] price/runtime from uart_host output. Log: $cpuLog"
}
$cpuPrice = [double]$Matches[1]
$cpuWall = [double]$Matches[2]

$cpuQ16 = $null
if ($cpuTxt -match 'Estimated Option Price \(Q16\.16\):\s*(-?\d+)') {
    $cpuQ16 = [int64]$Matches[1]
}

# Decode FPGA Q16.16 (same as uart_host)
$pr = [Convert]::ToInt32($priceRaw.Substring(2), 16)
if ($pr -band 0x80000000) { $pr = $pr - 0x100000000 }
$fpgaPrice = [double]$pr / 65536.0
$fpgaQ16 = [int64]$pr

$delta = [math]::Abs($fpgaPrice - $cpuPrice)
$rel = if ([math]::Abs($cpuPrice) -gt 1e-12) { ($delta / [math]::Abs($cpuPrice)) * 100.0 } else { 0.0 }

if ($ReportFormat -eq "Verbose") {
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "VIRTUAL ARTY A7-100T (sim cycles x STA period, no board)"
    Write-Host "============================================================"
    Write-Host "  Marker:           $marker"
    Write-Host "  Price (sim DUT):  $fpgaPrice (raw $priceRaw)"
    Write-Host "  Core cycles:      $coreCycles"
    Write-Host ('  Assumed period:   {0:F9} s  (at {1} Hz)' -f $period, $FclkHz)
    Write-Host "  FPGA compute (est): $([string]::Format('{0:F9}', $fpgaComputeS)) s"
    Write-Host "  CPU price (dbl):  $cpuPrice"
    Write-Host "  CPU wall time:    $cpuWall s"
    if ($null -ne $cpuQ16) {
        $cpuQ16hex = ('{0:X8}' -f ($cpuQ16 -band 0xFFFFFFFF))
        Write-Host "  CPU price (Q16):  $cpuQ16  (0x$cpuQ16hex)"
        if ($cpuQ16 -eq $fpgaQ16) {
            Write-Host "  Q16.16 check:     MATCH (FPGA sim == C++ baseline for this param set)"
        } else {
            Write-Host "  Q16.16 check:     differs (sim=$fpgaQ16 vs cpu=$cpuQ16) - C++ baseline is not bit-identical QMC to RTL; cycles and STA-scaled time still represent silicon intent."
        }
    }
    Write-Host ('  Price |dbl delta|: {0}  (rel {1:F4} %; double can diverge at low N)' -f $delta, $rel)
    if ($fpgaComputeS -gt 0 -and $cpuWall -gt 0) {
        $spv = $cpuWall / $fpgaComputeS
        Write-Host ('  Speedup est:      {0:F2}x  (CPU wall / FPGA compute at STA fclk)' -f $spv)
    }

    if (-not $TimingReport) { $TimingReport = Join-Path $repo "vivado_build\arty_a7_100\timing_post_route.rpt" }
    if (-not $UtilReport) { $UtilReport = Join-Path $repo "vivado_build\arty_a7_100\utilization.rpt" }
    if (Test-Path $TimingReport) {
        Write-Host ""
        Write-Host "Reference (last build, if present): $TimingReport"
        Select-String -Path $TimingReport -Pattern "WNS\(ns\)|sys_clk|83\.333" | Select-Object -First 8 | ForEach-Object { Write-Host "  $($_.Line.Trim())" }
    }
    if (Test-Path $UtilReport) {
        Write-Host "Reference: $UtilReport (slice LUT summary)"
        Select-String -Path $UtilReport -Pattern "Slice LUTs|Slice Registers|DSP48" | Select-Object -First 6 | ForEach-Object { Write-Host "  $($_.Line.Trim())" }
    }

    Write-Host "============================================================"
    Write-Host "Raw sim log: $simLog"
    Write-Host "Raw CPU log: $cpuLog"
    Write-Host ""
    Write-Host "Note: RTL sim uses 100 MHz TB clock; only wall-time scaling uses the A7-100T STA fclk."
    Write-Host "============================================================"
}

if ($ReportFormat -eq "UartShaped") {
    $mk = [Convert]::ToUInt32($marker.Substring(2), 16)
    $pru = [Convert]::ToUInt32($priceRaw.Substring(2), 16)
    $e0 = [uint32]$paths
    $e1 = [uint32]$steps
    $e2 = [uint32](Q16FromDouble $S0)
    $e3 = [uint32](Q16FromDouble $K)
    $e4 = [uint32](Q16FromDouble $rf)
    $e5 = [uint32](Q16FromDouble $sig)
    $e6 = [uint32](Q16FromDouble $Tt)
    $e7 = [uint32]($opt -band 1)
    $sp = if ($fpgaComputeS -gt 0 -and $cpuWall -gt 0) { $cpuWall / $fpgaComputeS } else { 0.0 }

    function DecEcho([uint32]$raw) {
        $si = [int32]$raw
        return [double]$si / 65536.0
    }

    Write-Host ""
    Write-Host "=================================================="
    Write-Host "UART_HOST_SHAPED_REPORT (RTL simulation, not USB)"
    Write-Host "=================================================="
    Write-Host "Provenance: Digilent Arty A7-100T RTL in Vivado xsim (UART compute TB). core_cycles is the DUT counter; compute_time_s = core_cycles / $FclkHz Hz (post-route STA target in constraints/arty_a7_100.xdc). This is not a USB-UART wall measurement."
    Write-Host "If you program an A7-100T with this RTL and run the same param batch at that core frequency, you should see the same UART result packet (subject to MMCM/clock setup on the board)."
    Write-Host ""
    Write-Host "[FPGA] UART-shaped (from simulation)"
    for ($i = 0; $i -lt 8; $i++) {
        $raw = @( $e0, $e1, $e2, $e3, $e4, $e5, $e6, $e7 )[$i]
        $dec = if ($i -ge 2) { DecEcho $raw } else { $raw }
        Write-Host ('  echo[{0}] raw=0x{1:X8} decoded={2}' -f $i, $raw, $dec)
    }
    Write-Host ('[FPGA] result_marker=0x{0:X8}' -f $mk)
    Write-Host ('[FPGA] price_raw=0x{0:X8} price={1:F8}' -f $pru, $fpgaPrice)
    Write-Host "[FPGA] core_cycles=$coreCycles"
    Write-Host ('[FPGA] compute_time_s={0:F9}' -f $fpgaComputeS)
    Write-Host "[FPGA] uart_roundtrip_s=N/A (no serial port in RTL sim)"
    Write-Host ""
    Write-Host "=================================================="
    Write-Host "BENCHMARK COMPARISON"
    Write-Host "=================================================="
    Write-Host ('  CPU price:  {0:F8}' -f $cpuPrice)
    Write-Host ('  FPGA price: {0:F8}' -f $fpgaPrice)
    Write-Host ('  Price delta: {0:F8} (rel_err={1:F4}%)' -f $delta, $rel)
    Write-Host ('  CPU wall time: {0:F6} s' -f $cpuWall)
    Write-Host ('  FPGA compute time: {0:F9} s' -f $fpgaComputeS)
    if ($sp -gt 0) {
        Write-Host ('  Speedup (CPU_wall / FPGA_compute): {0:F2}x' -f $sp)
    }
    Write-Host "=================================================="
    Write-Host "Audit logs: xsim=$simLog cpu=$cpuLog"
}
