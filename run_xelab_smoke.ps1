# Forwards to scripts/run_xelab_smoke.ps1 (single source of truth).
param(
    [string]$XvlogExe = "xvlog",
    [string]$XelabExe = "xelab",
    [int]$XvlogTimeoutSeconds = 600,
    [int]$XelabTimeoutSeconds = 600,
    [switch]$DisableMultithreading = $true,
    [switch]$NoCleanup
)

$ErrorActionPreference = "Stop"
$impl = Join-Path $PSScriptRoot "scripts\run_xelab_smoke.ps1"
if (-not (Test-Path $impl)) { throw "Missing $impl" }
& $impl @PSBoundParameters
