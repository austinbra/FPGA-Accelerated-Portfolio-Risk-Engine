<#
.SYNOPSIS
  Simulate an Arty A7-100T run without hardware: Vivado xsim UART compute TB + CPU baseline.

.DESCRIPTION
  Runs the same RTL + UART stimulus as the board testbench, parses the DUT core_cycle counter from
  the [VIRTUAL_A7] log line, and scales cycles by the caller-supplied clock assertion. Reports
  exact raw-price parity and separate CPU-reported and simulated-core intervals
  using the same parameter file. Boundary ratios live only in the claim report.

  Assumption: post-route cycle semantics match RTL simulation (same reset, same UART batch).
#>
param(
    [string]$ParamFile = "",
    [int]$NumLanes = 4,
    [double]$FclkHz = 105263158.0,
    [ValidateSet("Single", "Multi")]
    [string]$ExerciseMode = "Multi",
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
$localTmp = Join-Path $repo ".tmp"
New-Item -ItemType Directory -Force -Path $localTmp | Out-Null
$env:TEMP = $localTmp
$env:TMP = $localTmp

if (-not $ParamFile) {
    $ParamFile = Join-Path $repo "baseline\cpp_fixed\params_latency_1024x4.txt"
}
if (-not (Test-Path $ParamFile)) {
    throw "Param file not found: $ParamFile"
}

function Q16FromDouble([double]$x) {
    if ([double]::IsNaN($x) -or [double]::IsInfinity($x)) {
        throw "Q16.16 input must be finite: $x"
    }
    if ($x -lt -32768.0 -or $x -gt 32767.0) {
        throw "Q16.16 input outside C++ model range [-32768,32767]: $x"
    }
    $scaled = [double]$x * 65536.0
    if ($scaled -ge 0.0) {
        return [int32][math]::Floor($scaled + 0.5)
    }
    return [int32][math]::Ceiling($scaled - 0.5)
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
$opt = 1
if ($kv.ContainsKey("option_type")) { $opt = [int]$kv["option_type"] }
if ($kv.ContainsKey("exercise_mode")) {
    $fileExerciseMode = $kv["exercise_mode"].ToLowerInvariant()
    if ($fileExerciseMode -notin @("single", "multi")) {
        throw "exercise_mode in parameter file must be single or multi"
    }
    if ($fileExerciseMode -ne $ExerciseMode.ToLowerInvariant()) {
        throw "ExerciseMode $ExerciseMode conflicts with parameter file $fileExerciseMode"
    }
}

if ($NumLanes -lt 1) { throw "NumLanes must be >= 1" }
if ($FclkHz -le 0) { throw "FclkHz must be positive" }
if ($ExerciseMode -eq "Multi" -and @(1, 2, 4, 8) -notcontains $NumLanes) {
    throw "Multi exercise supports NumLanes in {1,2,4,8}; got $NumLanes"
}
if ($paths -lt 1 -or $paths -gt 1024) { throw "paths must be in [1,1024]" }
if ($steps -lt 1 -or $steps -gt 50) { throw "steps must be in [1,50]" }
if (($paths % $NumLanes) -ne 0) {
    throw "paths ($paths) must be divisible by NumLanes ($NumLanes) (same rule as silicon)."
}
if ($opt -notin @(0, 1)) { throw "option_type must be 0 (CALL) or 1 (PUT)" }
if ($S0 -le 0 -or $K -le 0 -or $sig -le 0 -or $Tt -le 0) {
    throw "S0, K, sigma, and T must be positive"
}
# Force finite/range checks before invoking the simulator.
@($S0, $K, $rf, $sig, $Tt) | ForEach-Object { $null = Q16FromDouble $_ }
$isHeadlineConfig = (
    $ExerciseMode -eq "Multi" -and $NumLanes -eq 4 -and
    [math]::Abs($FclkHz - 105263158.0) -lt 0.5
)

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
    Write-Host "  Exercise:    $ExerciseMode"
    Write-Host "  Clock assertion: $FclkHz Hz (used only to scale simulated core cycles)"
    if ($isHeadlineConfig) { Write-Host "  Routed reference: canonical multi/4-lane/105.263-MHz configuration" }
    Write-Host "  Plusargs:    $($plus -join ' ')"
}

$tb = Join-Path $PSScriptRoot "run_tb_top_uart_safe.ps1"
$simLog = Join-Path $localTmp ("virtual_a7_xsim_{0}.log" -f [Guid]::NewGuid().ToString("N"))

try {
    $tbOptions = @{
        NumLanes = $NumLanes
        TestPlusarg = $plus
        XsimTimeoutSeconds = $XsimTimeoutSeconds
    }
    if ($ExerciseMode -eq "Multi") {
        $tbOptions.MultiExercise = $true
    } else {
        $tbOptions.ComputeMode = $true
    }
    & $tb @tbOptions *>&1 | Tee-Object -FilePath $simLog
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
$markerValue = [Convert]::ToUInt32($marker.Substring(2), 16)
if ([uint64]$markerValue -ne 2882338817) {
    throw "Unexpected RTL result marker: $marker"
}

if ($simPaths -ne $paths -or $simSteps -ne $steps) {
    Write-Warning "Sim reported paths/steps ($simPaths,$simSteps) differ from file ($paths,$steps); check TB."
}

$period = 1.0 / $FclkHz
$fpgaComputeS = [double]$coreCycles * $period

# CPU baseline (same param file as uart_host)
$cpuLog = Join-Path $localTmp ("virtual_a7_cpu_{0}.log" -f [Guid]::NewGuid().ToString("N"))
& python (Join-Path $repo "src\uart_host.py") @(
    "--mode", "benchmark",
    "--target", "cpu",
    "--param-file", $ParamFile,
    "--exercise-mode", $ExerciseMode.ToLowerInvariant()
) *>&1 | Tee-Object -FilePath $cpuLog
if ($LASTEXITCODE -ne 0) {
    throw "uart_host.py --target cpu failed (exit $LASTEXITCODE). Log: $cpuLog"
}

$cpuTxt = Get-Content $cpuLog -Raw
$cpuQ16 = $null
if ($cpuTxt -match '\[CPU\]\s+price_raw=(-?\d+)\s+price=([0-9eE\+\-\.]+)\s+runtime_s=([0-9eE\+\-\.]+)') {
    $cpuQ16 = [int64]$Matches[1]
    $cpuPrice = [double]$Matches[2]
    $cpuWall = [double]$Matches[3]
} elseif ($cpuTxt -match '\[CPU\]\s+price=([0-9eE\+\-\.]+)\s+runtime_s=([0-9eE\+\-\.]+)') {
    $cpuPrice = [double]$Matches[1]
    $cpuWall = [double]$Matches[2]
} else {
    throw "Could not parse [CPU] price/runtime from uart_host output. Log: $cpuLog"
}

if ($null -eq $cpuQ16 -and $cpuTxt -match 'Estimated Option Price \(Q16\.16\):\s*(-?\d+)') {
    $cpuQ16 = [int64]$Matches[1]
}

# Decode FPGA Q16.16 (same as uart_host)
$prBits = [Convert]::ToUInt32($priceRaw.Substring(2), 16)
if ([uint64]$prBits -eq 3735879681) { throw "RTL returned core timeout (0xDEAD0001)" }
if ([uint64]$prBits -eq 3735879682) { throw "RTL rejected the workload (0xDEAD0002)" }
$pr = [int64]$prBits
if ([uint64]$prBits -ge 2147483648) { $pr -= 4294967296 }
$fpgaPrice = [double]$pr / 65536.0
$fpgaQ16 = [int64]$pr
if ($null -eq $cpuQ16) {
    throw "C++ output did not contain a raw Q16.16 price"
}
if ($cpuQ16 -ne $fpgaQ16) {
    throw "Q16.16 parity failure: sim=$fpgaQ16 vs cpu=$cpuQ16"
}

$delta = [math]::Abs($fpgaPrice - $cpuPrice)
$rel = if ([math]::Abs($cpuPrice) -gt 1e-12) { ($delta / [math]::Abs($cpuPrice)) * 100.0 } else { 0.0 }

if ($ReportFormat -eq "Verbose") {
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "VIRTUAL ARTY A7-100T (sim cycles x supplied clock assertion, no board)"
    Write-Host "============================================================"
    Write-Host "  Marker:           $marker"
    Write-Host "  Price (sim DUT):  $fpgaPrice (raw $priceRaw)"
    Write-Host "  Core cycles:      $coreCycles"
    Write-Host ('  Assumed period:   {0:F9} s  (at {1} Hz)' -f $period, $FclkHz)
    Write-Host "  FPGA compute (est): $([string]::Format('{0:F9}', $fpgaComputeS)) s"
    Write-Host "  CPU price (dbl):  $cpuPrice"
    Write-Host "  CPU reported interval: $cpuWall s"
    if ($null -ne $cpuQ16) {
        $cpuQ16hex = ('{0:X8}' -f ($cpuQ16 -band 0xFFFFFFFF))
        Write-Host "  CPU price (Q16):  $cpuQ16  (0x$cpuQ16hex)"
        Write-Host "  Q16.16 check:     MATCH (FPGA sim == C++ baseline for this param set)"
    }
    Write-Host ('  Price |dbl delta|: {0}  (rel {1:F4} %; double can diverge at low N)' -f $delta, $rel)
    Write-Host "  Timing ratio:      not reported here; use results/claims for named CPU boundaries"

    if (-not $TimingReport -and $isHeadlineConfig) { $TimingReport = Join-Path $repo "vivado_build\arty_a7_100_multi_lanes4_9p5ns_rowopt\timing_post_route.rpt" }
    if (-not $UtilReport -and $isHeadlineConfig) { $UtilReport = Join-Path $repo "vivado_build\arty_a7_100_multi_lanes4_9p5ns_rowopt\utilization.rpt" }
    if (Test-Path $TimingReport) {
        Write-Host ""
        Write-Host "Reference (last build, if present): $TimingReport"
        Select-String -Path $TimingReport -Pattern "WNS\(ns\)|core_clk_unbuffered|105\.263|9\.500" | Select-Object -First 8 | ForEach-Object { Write-Host "  $($_.Line.Trim())" }
    }
    if (Test-Path $UtilReport) {
        Write-Host "Reference: $UtilReport (slice LUT summary)"
        Select-String -Path $UtilReport -Pattern "Slice LUTs|Slice Registers|DSP48" | Select-Object -First 6 | ForEach-Object { Write-Host "  $($_.Line.Trim())" }
    }

    Write-Host "============================================================"
    Write-Host "Raw sim log: $simLog"
    Write-Host "Raw CPU log: $cpuLog"
    Write-Host ""
    Write-Host "Note: core time is simulated cycle count divided by the supplied clock assertion."
    Write-Host "============================================================"
}

if ($ReportFormat -eq "UartShaped") {
    $mk = [Convert]::ToUInt32($marker.Substring(2), 16)
    $pru = [Convert]::ToUInt32($priceRaw.Substring(2), 16)
    function U32Bits([int32]$value) {
        if ($value -lt 0) { return [uint64](4294967296 + [int64]$value) }
        return [uint64]$value
    }
    $e0 = [uint64]$paths
    $e1 = [uint64]$steps
    $e2 = U32Bits (Q16FromDouble $S0)
    $e3 = U32Bits (Q16FromDouble $K)
    $e4 = U32Bits (Q16FromDouble $rf)
    $e5 = U32Bits (Q16FromDouble $sig)
    $e6 = U32Bits (Q16FromDouble $Tt)
    $e7 = [uint64]($opt -band 1)
    function DecEcho([uint64]$raw) {
        $si = [int64]$raw
        if ($raw -ge 2147483648) { $si -= 4294967296 }
        return [double]$si / 65536.0
    }

    Write-Host ""
    Write-Host "=================================================="
    Write-Host "UART_HOST_SHAPED_REPORT (RTL simulation, not USB)"
    Write-Host "=================================================="
    Write-Host "Provenance: RTL in Vivado xsim (UART compute TB). core_cycles is the DUT counter; compute_time_s = core_cycles / the caller-supplied $FclkHz Hz assertion. This is not a USB-UART or post-route wall measurement."
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
    Write-Host ('  CPU reported interval: {0:F6} s' -f $cpuWall)
    Write-Host ('  FPGA core time from sim cycles: {0:F9} s' -f $fpgaComputeS)
    Write-Host "  Timing ratio: not reported here; use results/claims for named CPU boundaries"
    Write-Host "=================================================="
    Write-Host "Audit logs: xsim=$simLog cpu=$cpuLog"
}
