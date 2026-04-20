param(
    [string]$Bit = "",
    [int]$TimeoutSeconds = 600
)

$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
Set-Location $repo

if (-not $Bit) {
    $Bit = Join-Path $repo "vivado_build\arty_a7_100\arty_a7_qmc.bit"
}

if (-not (Test-Path $Bit)) {
    throw "Bitstream not found: $Bit  (run scripts/run_vivado_build_arty_a7.ps1 first)"
}

Write-Host "Programming Arty A7-100T with: $Bit"
$tcl = Join-Path $PSScriptRoot "program_arty_a7.tcl"
$proc = Start-Process -FilePath "vivado" -ArgumentList @(
    "-mode", "batch",
    "-source", $tcl,
    "-tclargs", $Bit
) -PassThru -NoNewWindow

if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
    Write-Warning "Timeout (${TimeoutSeconds}s): killing vivado PID=$($proc.Id)"
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    throw "Vivado programming timed out"
}

if ($null -ne $proc.ExitCode -and $proc.ExitCode -ne 0) {
    throw "Vivado programming exited with code $($proc.ExitCode)"
}

Write-Host "Board programmed OK."
