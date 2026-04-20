param(
    [switch]$SynthOnly,
    [int]$TimeoutSeconds = 14400
)

$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
Set-Location $repo

if ($SynthOnly) {
    $env:VIVADO_SYNTH_ONLY = "1"
} else {
    Remove-Item Env:VIVADO_SYNTH_ONLY -ErrorAction SilentlyContinue
}

Write-Host "Running Vivado batch for Arty A7-100T (repo: $repo) ..."
$proc = Start-Process -FilePath "vivado" -ArgumentList @(
    "-mode", "batch",
    "-source", (Join-Path $PSScriptRoot "vivado_build_arty_a7.tcl")
) -PassThru -NoNewWindow

if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
    Write-Warning "Timeout (${TimeoutSeconds}s): killing vivado PID=$($proc.Id)"
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    throw "Vivado build timed out"
}

$ec = $proc.ExitCode
if ($null -ne $ec -and $ec -ne 0) {
    throw "Vivado exited with code $ec"
}

Write-Host "Vivado build finished OK."
if (-not $SynthOnly) {
    Write-Host "Bitstream (default): $repo\vivado_build\arty_a7_100\arty_a7_qmc.bit"
}
