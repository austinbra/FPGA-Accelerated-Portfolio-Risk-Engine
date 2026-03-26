param(
    [string]$XvlogExe = "xvlog",
    [string]$VivadoExe = "vivado",
    [int]$TimeoutSeconds = 120,
    [switch]$NoCleanup,
    [switch]$UseDirectXvlog  # Use xvlog directly instead of vivado -mode batch (slower startup)
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path $PSScriptRoot -Parent
if (-not $projectRoot) { $projectRoot = Get-Location }

function Invoke-ToolWithTimeout {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string[]]$Args,
        [Parameter(Mandatory = $true)][int]$TimeoutSec,
        [string]$WorkingDir = $projectRoot
    )

    $argString = ($Args | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    Write-Host "Running: $Exe $argString"
    Write-Host "  (timeout: ${TimeoutSec}s, cwd: $WorkingDir)"

    $proc = Start-Process -FilePath $Exe -ArgumentList $Args -PassThru -NoNewWindow -WorkingDirectory $WorkingDir
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        Write-Warning "Timeout (${TimeoutSec}s): killing $Exe (PID=$($proc.Id))"
        cmd /c "taskkill /F /T /PID $($proc.Id)" 2>$null
        throw "$Exe timed out after $TimeoutSec seconds"
    }
    $ec = $proc.ExitCode
    if ($null -ne $ec -and $ec -ne 0) {
        throw "$Exe failed with exit code $ec"
    }
}

$sources = @(
    "src/fpga_cfg_pkg.sv",
    "src/helpers/rv_skid_arr_gate.sv",
    "src/helpers/event_align_fifo_arr.sv",
    "src/math/fxMul.sv",
    "src/math/fxDiv.sv",
    "src/math/fxExpLUT.sv",
    "src/math/fxLnLUT.sv",
    "src/math/fxSqrt.sv",
    "src/math/fxInvCDF_ZS.sv",
    "src/steps/sobol.sv",
    "src/steps/inverseCDF_fold.sv",
    "src/steps/inverseCDF.sv",
    "src/steps/GBM.sv",
    "src/steps/accumulator.sv",
    "src/steps/regression.sv",
    "src/steps/lsm_decision.sv",
    "src/io/uart/uart_rx.sv",
    "src/io/uart/uart_tx.sv",
    "src/io/uart/uart_rx32.sv",
    "src/io/uart/uart_tx32.sv",
    "src/io/handlers/uart_input_handler.sv",
    "src/top/top_option_pricer.sv"
)

if (-not $UseDirectXvlog) {
    # Prefer vivado -mode batch: single Vivado session, avoids repeated slow xvlog startup
    $tclScript = Join-Path $projectRoot "scripts\run_xvlog.tcl"
    if (Test-Path $tclScript) {
        Write-Host "Using Vivado batch mode (recommended)"
        Invoke-ToolWithTimeout -Exe $VivadoExe -Args @("-mode", "batch", "-source", $tclScript, "-notrace") -TimeoutSec $TimeoutSeconds
    } else {
        Write-Host "Tcl script not found, falling back to direct xvlog"
        $xvlogArgs = @("-nolog", "-sv") + $sources
        Invoke-ToolWithTimeout -Exe $XvlogExe -Args $xvlogArgs -TimeoutSec $TimeoutSeconds
    }
} else {
    $xvlogArgs = @("-nolog", "-sv") + $sources
    Invoke-ToolWithTimeout -Exe $XvlogExe -Args $xvlogArgs -TimeoutSec $TimeoutSeconds
}

Write-Host "xvlog src compile completed successfully."

if (-not $NoCleanup) {
    & "$PSScriptRoot\cleanup_artifacts.ps1" -Quiet
}
