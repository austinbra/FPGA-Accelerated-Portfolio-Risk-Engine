param(
    [switch]$SynthOnly,
    [switch]$MultiExercise,
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

if ($MultiExercise) {
    $env:VIVADO_MULTI_EXERCISE = "1"
    $buildDir = Join-Path $repo "vivado_build\arty_a7_100_multi"
} else {
    Remove-Item Env:VIVADO_MULTI_EXERCISE -ErrorAction SilentlyContinue
    $buildDir = Join-Path $repo "vivado_build\arty_a7_100"
}

Write-Host "Running Vivado batch for Arty A7-100T (repo: $repo) ..."
if ($MultiExercise) {
    Write-Host "Mode: MULTI_EXERCISE=1"
} else {
    Write-Host "Mode: single-date default"
}
Write-Host "Build directory: $buildDir"

$tclScript = Join-Path $PSScriptRoot "vivado_build_arty_a7.tcl"
$vivadoCommand = Get-Command vivado -ErrorAction Stop
$vivadoPath = $vivadoCommand.Source
$runner = Join-Path $PSScriptRoot "vivado_build_runner.py"
$logName = if ($MultiExercise) { "vivado_arty_a7_multi" } else { "vivado_arty_a7" }
if ($SynthOnly) { $logName += "_synth" } else { $logName += "_impl" }
$logFile = Join-Path $repo ".tmp\$logName.log"

$runnerArgs = @(
    $runner,
    "--repo", $repo,
    "--vivado", $vivadoPath,
    "--tcl-script", $tclScript,
    "--timeout-seconds", $TimeoutSeconds,
    "--log-file", $logFile
)
if ($SynthOnly) { $runnerArgs += "--synth-only" }
if ($MultiExercise) { $runnerArgs += "--multi-exercise" }

python @runnerArgs
$ec = $LASTEXITCODE
if ($null -ne $ec -and $ec -ne 0) {
    throw "Vivado exited with code $ec"
}

Write-Host "Vivado build finished OK."
if (-not $SynthOnly) {
    if ($MultiExercise) {
        Write-Host "Bitstream (multi-date): $buildDir\arty_a7_qmc_multi.bit"
    } else {
        Write-Host "Bitstream (default): $buildDir\arty_a7_qmc.bit"
    }
} else {
    Write-Host "Synthesis utilization report: $buildDir\utilization_synth.rpt"
}
