param(
    [ValidateSet("board100", "core95")]
    [string]$Mode = "board100",
    [int]$TimeoutSeconds = 900
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $PSScriptRoot "vivado_build_runner.py"
$tcl = Join-Path $PSScriptRoot "vivado_build_s7_uart_diag.tcl"
$vivado = (Get-Command vivado -ErrorAction Stop).Source
$log = Join-Path $repo ".tmp\vivado_s7_uart_diag_$Mode.log"

$env:UART_DIAG_USE_CORE_CLOCK = if ($Mode -eq "core95") { "1" } else { "0" }

$runnerArgs = @(
    $runner,
    "--repo", $repo,
    "--vivado", $vivado,
    "--tcl-script", $tcl,
    "--timeout-seconds", $TimeoutSeconds,
    "--log-file", $log
)
python @runnerArgs
if ($LASTEXITCODE -ne 0) {
    throw "S7 UART diagnostic build failed with exit code $LASTEXITCODE"
}

$buildDir = Join-Path $repo "vivado_build\arty_s7_uart_diag_$Mode"
Write-Host "Bitstream: $buildDir\arty_s7_uart_diag.bit"
Get-Content (Join-Path $buildDir "clock_audit.txt")
