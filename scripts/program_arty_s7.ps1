param(
    [string]$Bit = "",
    [switch]$AllowPartMismatch,
    [int]$TimeoutSeconds = 600
)

$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent

if (-not $Bit) {
    $Bit = Join-Path $repo "vivado_build\arty_s7_50_multi_lanes2_10p5ns_rowopt\arty_s7_qmc_multi.bit"
} elseif (-not [System.IO.Path]::IsPathRooted($Bit)) {
    $Bit = Join-Path $repo $Bit
}

if (-not (Test-Path -LiteralPath $Bit)) {
    throw "Bitstream not found: $Bit  (run scripts/run_vivado_build_arty_s7.ps1 first)"
}
$Bit = (Resolve-Path -LiteralPath $Bit).Path

$tcl = Join-Path $PSScriptRoot "program_arty_s7.tcl"
$runner = Join-Path $PSScriptRoot "vivado_build_runner.py"
$vivado = (Get-Command vivado -ErrorAction Stop).Source
$logFile = Join-Path $repo ".tmp\vivado_hw\program_arty_s7.log"

Write-Host "Programming Arty S7-50 with: $Bit"
$runnerArgs = @(
    $runner,
    "--repo", $repo,
    "--vivado", $vivado,
    "--tcl-script", $tcl,
    "--timeout-seconds", $TimeoutSeconds,
    "--log-file", $logFile,
    "--tclarg", $Bit
)
if ($AllowPartMismatch) {
    $runnerArgs += "--tclarg=--allow-part-mismatch"
}

python @runnerArgs
$ec = $LASTEXITCODE
if ($null -ne $ec -and $ec -ne 0) {
    throw "Vivado programming exited with code $ec"
}

Select-String -Path $logFile -Pattern "Detected hardware PART=|Arty S7-50 programmed OK:" |
    ForEach-Object { Write-Host $_.Line }
Write-Host "Arty S7-50 programmed OK."
