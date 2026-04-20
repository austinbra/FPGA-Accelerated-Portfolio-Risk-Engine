param(
    [string]$XvlogExe = "xvlog",
    [string]$XelabExe = "xelab",
    [string]$XsimExe = "xsim",
    [int]$XvlogTimeoutSeconds = 1800,
    [int]$XelabTimeoutSeconds = 600,
    [int]$XsimTimeoutSeconds = 600,
    [switch]$ComputeMode,
    [switch]$Multibatch,  # Run tb_top_option_pricer_uart_multibatch (2 batches, compute mode)
    [switch]$NoCleanup,
    [switch]$DebugAcc,   # -d ACC_DEBUG for accumulator stall diagnosis
    [switch]$DebugFsm,   # -d TOP_FSM_DEBUG for FSM state tracing
    [switch]$DebugReg,   # -d REG_DEBUG for regression pipeline tracing
    [int]$NumLanes = 1,  # 1 = default; 2/3/4/8 select lane wrappers (see .user/VALIDATION.md)
    [string[]]$TestPlusarg = @()  # e.g. paths=64 steps=12 S0=6553600 ... passed to xsim -testplusarg
)

$ErrorActionPreference = "Stop"

function Format-ExeArgument([string]$s) {
    # CreateProcess command line: quote args that contain spaces, quotes, or '=' (xsim splits bare KEY=value).
    if ($s -match '[\s="]') {
        '"' + (($s -replace '\\', '\\\\') -replace '"', '\"') + '"'
    } elseif ($s -match '=') {
        '"' + $s + '"'
    } else {
        $s
    }
}

function Invoke-ToolWithTimeout {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string[]]$CmdArgs,
        [Parameter(Mandatory = $true)][int]$TimeoutSec
    )

    $argString = ($CmdArgs | ForEach-Object { Format-ExeArgument $_ }) -join ' '
    Write-Host "Running: $Exe $argString"

    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        # Single Arguments string so KEY=value plusargs are not split at '=' by the shell/loader.
        $argLine = ($CmdArgs | ForEach-Object { Format-ExeArgument $_ }) -join ' '
        $proc = Start-Process -FilePath $Exe -ArgumentList $argLine -PassThru -NoNewWindow `
            -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile `
            -WorkingDirectory (Split-Path $PSScriptRoot -Parent)
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            Write-Warning "Timeout ($TimeoutSec s): killing $Exe (PID=$($proc.Id))"
            cmd /c "taskkill /F /T /PID $($proc.Id)" | Out-Null
            throw "$Exe timed out after $TimeoutSec seconds"
        }
        $out = Get-Content $stdoutFile -Raw -ErrorAction SilentlyContinue
        $err = Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue
        if ($out) { Write-Output $out }
        if ($err) { Write-Output $err }
        # ExitCode can be null with Start-Process on some Windows setups; only fail on definite non-zero
        $ec = $proc.ExitCode
        if ($null -ne $ec -and $ec -ne 0) {
            throw "$Exe failed with exit code $ec"
        }
    } finally {
        Remove-Item $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

$sources = @(
    "fpga/mem_paths_pkg.sv",
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
    "src/top/top_option_pricer.sv",
    "tb/tb_top_option_pricer_uart.sv"
)

$baseArgs = @("-nolog", "-sv")
if ($DebugAcc) { $baseArgs += "-d"; $baseArgs += "ACC_DEBUG" }
if ($DebugFsm) { $baseArgs += "-d"; $baseArgs += "TOP_FSM_DEBUG" }
if ($DebugReg) { $baseArgs += "-d"; $baseArgs += "REG_DEBUG" }

# Single xvlog invocation (batched mode caused timeouts on heavy LUT modules)
Write-Host "xvlog ($($sources.Count) files)"
Invoke-ToolWithTimeout -Exe $XvlogExe -CmdArgs ($baseArgs + $sources) -TimeoutSec $XvlogTimeoutSeconds

if ($Multibatch) {
    $top = "work.tb_top_option_pricer_uart_multibatch"
    $snap = "tb_top_option_pricer_uart_multibatch_sim"
} elseif ($ComputeMode) {
    if ($NumLanes -eq 2) {
        $top = "work.tb_top_option_pricer_uart_compute_lanes2"
        $snap = "tb_top_option_pricer_uart_compute_lanes2_sim"
    } elseif ($NumLanes -eq 3) {
        $top = "work.tb_top_option_pricer_uart_compute_lanes3"
        $snap = "tb_top_option_pricer_uart_compute_lanes3_sim"
    } elseif ($NumLanes -eq 4) {
        $top = "work.tb_top_option_pricer_uart_compute_lanes4"
        $snap = "tb_top_option_pricer_uart_compute_lanes4_sim"
    } elseif ($NumLanes -eq 8) {
        $top = "work.tb_top_option_pricer_uart_compute_lanes8"
        $snap = "tb_top_option_pricer_uart_compute_lanes8_sim"
    } else {
        $top = "work.tb_top_option_pricer_uart_compute"
        $snap = "tb_top_option_pricer_uart_compute_sim"
    }
} else {
    $top = "work.tb_top_option_pricer_uart"
    $snap = "tb_top_option_pricer_uart_sim"
}

Invoke-ToolWithTimeout -Exe $XelabExe -CmdArgs @("-nolog", $top, "-debug", "typical", "-s", $snap, "--mt", "off") -TimeoutSec $XelabTimeoutSeconds

$xsimArgs = @("-nolog", $snap, "-runall", "-onfinish", "quit")
# One -testplusarg per KEY=value (no spaces inside values). Joining into one string breaks
# Start-Process argv quoting on Windows for long plusarg lines.
foreach ($tp in @($TestPlusarg | Where-Object { $_ })) {
    $xsimArgs += "-testplusarg"
    $xsimArgs += [string]$tp
}
Invoke-ToolWithTimeout -Exe $XsimExe -CmdArgs $xsimArgs -TimeoutSec $XsimTimeoutSeconds

Write-Host "Safe UART TB run completed."

if (-not $NoCleanup) {
    & "$PSScriptRoot\cleanup_artifacts.ps1" -Quiet
}
