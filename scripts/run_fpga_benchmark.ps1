param(
    [string]$Port = "",
    [int]$Baud = 115200,
    [string]$ParamFile = "",
    [double]$FclkHz = 100000000.0,
    [int]$NumLanes = 4,
    [ValidateSet("Single", "Multi")]
    [string]$ExerciseMode = "Multi",
    [int]$Repetitions = 1,
    [string]$Bit = "",
    [switch]$SkipProgram,
    [switch]$SkipCpu,
    [switch]$BuildCpu
)

$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
Set-Location $repo

if (-not $ParamFile) {
    $ParamFile = Join-Path $repo "baseline\cpp_fixed\params_latency_1024x4.txt"
}
if (-not (Test-Path $ParamFile)) {
    throw "Param file not found: $ParamFile"
}
if (@(1, 2, 4, 8) -notcontains $NumLanes) {
    throw "NumLanes must be one of 1, 2, 4, or 8"
}

if (-not $Bit) {
    if ($ExerciseMode -ne "Multi" -or $NumLanes -ne 4) {
        throw "Non-default ExerciseMode/NumLanes requires -Bit pointing to the matching bitstream"
    }
    $Bit = Join-Path $repo "vivado_build\arty_a7_100_multi_lanes4_10ns\arty_a7_qmc_multi.bit"
}

if (-not $Port) {
    $ports = [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object
    if ($ports.Count -eq 0) {
        throw "No COM ports detected. Plug in the Arty A7-100T USB cable and retry (or pass -Port COMx)."
    }
    if ($ports.Count -eq 1) {
        $Port = $ports[0]
        Write-Host "Auto-selected serial port: $Port"
    } else {
        Write-Host "Multiple COM ports: $($ports -join ', ')"
        throw "Please specify -Port COMx (Arty A7 USB-UART normally appears as the higher-numbered 'USB Serial Port')."
    }
}

if (-not $SkipProgram) {
    Write-Host ">>> Programming Arty A7-100T ..."
    & (Join-Path $PSScriptRoot "program_arty_a7.ps1") -Bit $Bit
}

$target = if ($SkipCpu) { "fpga" } else { "both" }

$args = @(
    (Join-Path $repo "src\uart_host.py"),
    "--mode", "benchmark",
    "--target", $target,
    "--param-file", $ParamFile,
    "--port", $Port,
    "--baud", "$Baud",
    "--fpga-fclk-hz", ("{0:F0}" -f $FclkHz),
    "--num-lanes", "$NumLanes",
    "--exercise-mode", $ExerciseMode.ToLowerInvariant(),
    "--fpga-repetitions", "$Repetitions"
)
if ($BuildCpu) { $args += "--build-cpu" }

Write-Host ">>> Running UART benchmark on $Port @ $Baud (fclk=$FclkHz Hz, lanes=$NumLanes, exercise=$ExerciseMode) ..."
& python @args
if ($LASTEXITCODE -ne 0) {
    throw "uart_host.py exited with code $LASTEXITCODE"
}
