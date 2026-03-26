# Forwards to scripts/run_xvlog_src.ps1 (single source of truth).
param(
    [string]$XvlogExe = "xvlog",
    [string]$VivadoExe = "vivado",
    [int]$TimeoutSeconds = 120,
    [switch]$NoCleanup,
    [switch]$UseDirectXvlog
)

$ErrorActionPreference = "Stop"
$impl = Join-Path $PSScriptRoot "scripts\run_xvlog_src.ps1"
if (-not (Test-Path $impl)) { throw "Missing $impl" }
& $impl @PSBoundParameters
