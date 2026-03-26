param(
    [string]$XvlogExe = "xvlog",
    [string]$XelabExe = "xelab",
    [int]$XvlogTimeoutSeconds = 600,
    [int]$XelabTimeoutSeconds = 600,
    [switch]$DisableMultithreading = $true,
    [switch]$NoCleanup
)

$ErrorActionPreference = "Stop"

function Invoke-ToolWithTimeout {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string[]]$Args,
        [Parameter(Mandatory = $true)][int]$TimeoutSec
    )

    $argString = ($Args | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    Write-Host "Running: $Exe $argString"

    $projectRoot = Split-Path $PSScriptRoot -Parent
    $proc = Start-Process -FilePath $Exe -ArgumentList $Args -PassThru -NoNewWindow -WorkingDirectory $projectRoot
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        Write-Warning "Timeout ($TimeoutSec s): killing $Exe (PID=$($proc.Id))"
        cmd /c "taskkill /F /T /PID $($proc.Id)" | Out-Null
        throw "$Exe timed out after $TimeoutSec seconds"
    }
    $ec = $proc.ExitCode
    if ($null -ne $ec -and $ec -ne 0) {
        throw "$Exe failed with exit code $ec"
    }
}

$sources = @(
    "src/sim/fxDiv_core_stub.sv",
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

$xvlogArgs = @("-nolog", "-sv") + $sources
Invoke-ToolWithTimeout -Exe $XvlogExe -Args $xvlogArgs -TimeoutSec $XvlogTimeoutSeconds

$tops = @(
    "work.top_mc_option_pricer",
    "work.uart_input_handler",
    "work.sobol",
    "work.inverseCDF_fold",
    "work.inverseCDF",
    "work.GBM",
    "work.accumulator",
    "work.regression",
    "work.lsm_decision"
)

foreach ($top in $tops) {
    $snap = ($top -replace "^work\.", "") + "_sim"
    $args = @("-nolog", $top, "-debug", "typical", "-s", $snap)
    if ($DisableMultithreading) {
        $args += @("--mt", "off")
    }
    Invoke-ToolWithTimeout -Exe $XelabExe -Args $args -TimeoutSec $XelabTimeoutSeconds
}

Write-Host "xelab smoke elaboration completed successfully."

if (-not $NoCleanup) {
    & "$PSScriptRoot\cleanup_artifacts.ps1" -Quiet
}
