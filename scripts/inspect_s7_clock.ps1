param(
    [string]$Checkpoint = "vivado_build\arty_s7_50_multi_lanes2_10p5ns_rowopt\routed.dcp",
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$vivado = "C:\Xilinx\Vivado\2025.1\Vivado\bin\vivado.bat"
$checkpointPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Checkpoint))
$outputDir = Join-Path $repoRoot ".tmp\clock_audit"
$log = Join-Path $outputDir "inspect_s7_clock.log"
$errorLog = Join-Path $outputDir "inspect_s7_clock.stderr.log"

if (-not (Test-Path -LiteralPath $vivado)) {
    throw "Vivado not found: $vivado"
}
if (-not (Test-Path -LiteralPath $checkpointPath)) {
    throw "Checkpoint not found: $checkpointPath"
}

New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
$env:TEMP = $outputDir
$env:TMP = $outputDir

$runner = Join-Path $PSScriptRoot "vivado_build_runner.py"
$tcl = Join-Path $PSScriptRoot "inspect_s7_clock.tcl"
$runnerArgs = @(
    $runner,
    "--repo", $repoRoot,
    "--vivado", $vivado,
    "--tcl-script", $tcl,
    "--timeout-seconds", $TimeoutSeconds,
    "--log-file", $log,
    "--tclarg", $checkpointPath
)

python @runnerArgs
$ec = $LASTEXITCODE
if ($null -ne $ec -and $ec -ne 0) {
    Get-Content -LiteralPath $log -Tail 80
    throw "Vivado clock audit exited with code $ec"
}

Get-Content -LiteralPath $log | Select-String -Pattern "CLOCK_AUDIT"
Write-Host "Full log: $log"
