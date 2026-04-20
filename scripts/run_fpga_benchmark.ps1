param(
    [string]$Port = "",
    [int]$Baud = 115200,
    [string]$ParamFile = "",
    [double]$FclkHz = 83333333.0,
    [switch]$SkipProgram,
    [switch]$SkipCpu,
    [switch]$BuildCpu
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
    & (Join-Path $PSScriptRoot "program_arty_a7.ps1")
}

$target = if ($SkipCpu) { "fpga" } else { "both" }

$args = @(
    (Join-Path $repo "src\uart_host.py"),
    "--mode", "benchmark",
    "--target", $target,
    "--param-file", $ParamFile,
    "--port", $Port,
    "--baud", "$Baud",
    "--fpga-fclk-hz", ("{0:F0}" -f $FclkHz)
)
if ($BuildCpu) { $args += "--build-cpu" }

Write-Host ">>> Running UART benchmark on $Port @ $Baud (fclk=$FclkHz Hz) ..."
& python @args
if ($LASTEXITCODE -ne 0) {
    throw "uart_host.py exited with code $LASTEXITCODE"
}
