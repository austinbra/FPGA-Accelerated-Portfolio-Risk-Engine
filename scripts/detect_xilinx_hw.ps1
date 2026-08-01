param(
    [int]$TimeoutSeconds = 120
)

$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$tcl = Join-Path $PSScriptRoot "detect_xilinx_hw.tcl"
$runner = Join-Path $PSScriptRoot "vivado_build_runner.py"
$vivado = (Get-Command vivado -ErrorAction Stop).Source
$logFile = Join-Path $repo ".tmp\vivado_hw\detect_xilinx_hw.log"

Write-Host "Detecting Xilinx hardware over JTAG ..."
$runnerArgs = @(
    $runner,
    "--repo", $repo,
    "--vivado", $vivado,
    "--tcl-script", $tcl,
    "--timeout-seconds", $TimeoutSeconds,
    "--log-file", $logFile
)
python @runnerArgs
$ec = $LASTEXITCODE
if ($null -ne $ec -and $ec -ne 0) {
    throw "Vivado hardware detection exited with code $ec"
}

$devices = Select-String -Path $logFile -Pattern "^DEVICE "
if (-not $devices) {
    throw "Vivado exited successfully but reported no DEVICE lines. See $logFile"
}
$devices.Line | ForEach-Object { Write-Host $_ }
Write-Host "Hardware detection finished OK."
