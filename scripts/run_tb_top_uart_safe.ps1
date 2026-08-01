param(
    [string]$XvlogExe = "xvlog",
    [string]$XvhdlExe = "xvhdl",
    [string]$XelabExe = "xelab",
    [string]$XsimExe = "xsim",
    [int]$XvlogTimeoutSeconds = 1800,
    [int]$XelabTimeoutSeconds = 600,
    [int]$XsimTimeoutSeconds = 600,
    [switch]$ComputeMode,
    [ValidateSet("put", "call")]
    [string]$IntrinsicCase,
    [switch]$Multibatch,  # Run tb_top_option_pricer_uart_multibatch (2 batches, compute mode)
    [switch]$MultiExercise,  # Run stored-path multi-exercise RTL (lane count selected below)
    [switch]$SkipCompile,    # Reuse an existing xelab snapshot (fast benchmark sweeps)
    [switch]$NoCleanup,
    [switch]$DebugAcc,   # -d ACC_DEBUG for accumulator stall diagnosis
    [switch]$DebugFsm,   # -d TOP_FSM_DEBUG for FSM state tracing
    [switch]$DebugReg,   # -d REG_DEBUG for regression pipeline tracing
    [switch]$DebugNum,   # -d TOP_NUM_DEBUG for numerical comparison tracing
    [switch]$DebugDiv,   # -d FXDIV_DEBUG for generated-divider arithmetic checks
    [switch]$DebugDivTrace,  # Include per-transaction divider request/response trace
    [int]$NumLanes = 1,  # Multi-date: 1/2/4/8; legacy single-date also has 3 lanes
    [string]$VendorDividerModel = "",  # Generated sim/fxDiv_core.vhd preferred; .v netlist remains supported
    [string]$TestPlusargs = "",  # comma-separated form for Python/native callers
    [string[]]$TestPlusarg = @()  # e.g. paths=64 steps=12 S0=6553600 ... passed to xsim -testplusarg
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path $PSScriptRoot -Parent
$toolTmpRoot = Join-Path $repoRoot ".tmp"
New-Item -ItemType Directory -Force -Path $toolTmpRoot | Out-Null
$env:TEMP = $toolTmpRoot
$env:TMP = $toolTmpRoot

# A previous XSim library can silently satisfy an unresolved module name. Start
# every compile from an empty simulator library tree so the selected divider
# model is the one that is actually elaborated. -SkipCompile intentionally
# preserves the immediately preceding snapshot for a parameter-only rerun.
if (-not $SkipCompile) {
    $resolvedRepoRoot = [System.IO.Path]::GetFullPath($repoRoot).TrimEnd('\', '/')
    $xsimRoot = [System.IO.Path]::GetFullPath((Join-Path $resolvedRepoRoot "xsim.dir"))
    if ([System.IO.Path]::GetDirectoryName($xsimRoot) -ne $resolvedRepoRoot) {
        throw "Refusing to clean unexpected XSim path: $xsimRoot"
    }
    if (Test-Path -LiteralPath $xsimRoot) {
        Remove-Item -LiteralPath $xsimRoot -Recurse -Force
    }
}

if ($TestPlusargs) {
    $TestPlusarg += @($TestPlusargs -split "," | Where-Object { $_ })
}

try {
    Get-ChildItem Env: | Out-Null
} catch {
    # Some constrained launchers provide both Path and PATH. Start-Process
    # builds a case-insensitive environment map and fails on that duplicate.
    Remove-Item Env:PATH -ErrorAction SilentlyContinue
}

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

    $tag = [Guid]::NewGuid().ToString("N")
    $stdoutFile = Join-Path $toolTmpRoot ("tool_stdout_{0}.log" -f $tag)
    $stderrFile = Join-Path $toolTmpRoot ("tool_stderr_{0}.log" -f $tag)
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
        $combined = "$out`n$err"
        if ($combined -match "(?m)^(ERROR|FATAL|FAIL):") {
            throw "$Exe reported an ERROR/FATAL/FAIL message"
        }
        # ExitCode can be null with Start-Process on some Windows setups; only fail on definite non-zero
        $ec = $proc.ExitCode
        if ($null -ne $ec -and $ec -ne 0) {
            throw "$Exe failed with exit code $ec"
        }
    } finally {
        Remove-Item $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

$dividerSource = "src/sim/fxDiv_core_stub.sv"
$vendorDividerIsVhdl = $false
if ($VendorDividerModel) {
    $dividerSource = (Resolve-Path -LiteralPath $VendorDividerModel -ErrorAction Stop).Path
    $extension = [System.IO.Path]::GetExtension($dividerSource).ToLowerInvariant()
    $vendorDividerIsVhdl = $extension -in @(".vhd", ".vhdl")
    if ($vendorDividerIsVhdl) {
        Write-Host "Divider model: generated div_gen behavioral VHDL ($dividerSource)"
    } else {
        Write-Host "Divider model: generated div_gen primitive netlist ($dividerSource)"
    }
} else {
    Write-Host "Divider model: latency-calibrated behavioral stub (32-cycle div_gen contract)"
}

if ($VendorDividerModel) {
    $workLibrary = "qmc_work_vendor"
    $modelTag = "vendor"
    if ($vendorDividerIsVhdl) {
        $dividerLibrary = "qmc_fxdiv_vendor"
        $bindingKind = "generated_vhdl"
    } else {
        $dividerLibrary = $workLibrary
        $bindingKind = "generated_netlist"
    }
} else {
    $workLibrary = "qmc_work_stub"
    $dividerLibrary = $workLibrary
    $modelTag = "stub"
    $bindingKind = "behavioral_stub"
}

$dividerHashPath = if ([System.IO.Path]::IsPathRooted($dividerSource)) {
    $dividerSource
} else {
    Join-Path $repoRoot $dividerSource
}
$dividerHash = (Get-FileHash -LiteralPath $dividerHashPath -Algorithm SHA256).Hash
Write-Host "DIVIDER_BINDING model=$bindingKind work_library=$workLibrary divider_library=$dividerLibrary sha256=$dividerHash"

$sources = @("fpga/mem_paths_pkg.sv")
if (-not $vendorDividerIsVhdl) {
    $sources += $dividerSource
}
$sources += @(
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
    "src/top/top_option_pricer_multi.sv",
    "src/top/top_option_pricer_multi_stored.sv",
    "src/top/top_option_pricer.sv",
    "tb/tb_top_option_pricer_uart.sv"
)

$baseArgs = @("-nolog", "-sv")
if ($DebugAcc) { $baseArgs += "-d"; $baseArgs += "ACC_DEBUG" }
if ($DebugFsm) { $baseArgs += "-d"; $baseArgs += "TOP_FSM_DEBUG" }
if ($DebugReg) { $baseArgs += "-d"; $baseArgs += "REG_DEBUG" }
if ($DebugNum) { $baseArgs += "-d"; $baseArgs += "TOP_NUM_DEBUG" }
if ($DebugDiv -or $DebugDivTrace) { $baseArgs += "-d"; $baseArgs += "FXDIV_DEBUG" }
if ($DebugDivTrace) { $baseArgs += "-d"; $baseArgs += "FXDIV_TRACE" }

if (-not $SkipCompile) {
    if ($vendorDividerIsVhdl) {
        Invoke-ToolWithTimeout -Exe $XvhdlExe -CmdArgs @("-nolog", "--work", $dividerLibrary, $dividerSource) -TimeoutSec $XvlogTimeoutSeconds
    }
    # Single xvlog invocation (batched mode caused timeouts on heavy LUT modules)
    Write-Host "xvlog ($($sources.Count) files)"
    Invoke-ToolWithTimeout -Exe $XvlogExe -CmdArgs ($baseArgs + @("--work", $workLibrary) + $sources) -TimeoutSec $XvlogTimeoutSeconds
}

if ($IntrinsicCase) {
    $topName = "tb_top_option_pricer_uart_intrinsic_${IntrinsicCase}_lanes4"
    $top = "$workLibrary.$topName"
    $snap = "${topName}_${modelTag}_sim"
} elseif ($Multibatch) {
    $top = "$workLibrary.tb_top_option_pricer_uart_multibatch"
    $snap = "tb_top_option_pricer_uart_multibatch_${modelTag}_sim"
} elseif ($MultiExercise) {
    if ($NumLanes -eq 2) {
        $top = "$workLibrary.tb_top_option_pricer_uart_compute_multi_lanes2"
        $snap = "tb_top_option_pricer_uart_compute_multi_lanes2_${modelTag}_sim"
    } elseif ($NumLanes -eq 4) {
        $top = "$workLibrary.tb_top_option_pricer_uart_compute_multi_lanes4"
        $snap = "tb_top_option_pricer_uart_compute_multi_lanes4_${modelTag}_sim"
    } elseif ($NumLanes -eq 8) {
        $top = "$workLibrary.tb_top_option_pricer_uart_compute_multi_lanes8"
        $snap = "tb_top_option_pricer_uart_compute_multi_lanes8_${modelTag}_sim"
    } else {
        $top = "$workLibrary.tb_top_option_pricer_uart_compute_multi"
        $snap = "tb_top_option_pricer_uart_compute_multi_${modelTag}_sim"
    }
} elseif ($ComputeMode) {
    if ($NumLanes -eq 2) {
        $top = "$workLibrary.tb_top_option_pricer_uart_compute_lanes2"
        $snap = "tb_top_option_pricer_uart_compute_lanes2_${modelTag}_sim"
    } elseif ($NumLanes -eq 3) {
        $top = "$workLibrary.tb_top_option_pricer_uart_compute_lanes3"
        $snap = "tb_top_option_pricer_uart_compute_lanes3_${modelTag}_sim"
    } elseif ($NumLanes -eq 4) {
        $top = "$workLibrary.tb_top_option_pricer_uart_compute_lanes4"
        $snap = "tb_top_option_pricer_uart_compute_lanes4_${modelTag}_sim"
    } elseif ($NumLanes -eq 8) {
        $top = "$workLibrary.tb_top_option_pricer_uart_compute_lanes8"
        $snap = "tb_top_option_pricer_uart_compute_lanes8_${modelTag}_sim"
    } else {
        $top = "$workLibrary.tb_top_option_pricer_uart_compute"
        $snap = "tb_top_option_pricer_uart_compute_${modelTag}_sim"
    }
} else {
    $top = "$workLibrary.tb_top_option_pricer_uart"
    $snap = "tb_top_option_pricer_uart_${modelTag}_sim"
}

if (-not $SkipCompile) {
    $xelabTops = @($top)
    if ($VendorDividerModel -and -not $vendorDividerIsVhdl) {
        $xelabTops += "work.glbl"
    }
    $xelabArgs = @("-nolog") + $xelabTops + @("-debug", "typical", "-s", $snap, "--mt", "off")
    if ($vendorDividerIsVhdl) {
        $xelabArgs += @("-L", $dividerLibrary, "-L", "div_gen_v5_1_24")
    } elseif ($VendorDividerModel) {
        $xelabArgs += @("-L", "unisims_ver")
    }
    Invoke-ToolWithTimeout -Exe $XelabExe -CmdArgs $xelabArgs -TimeoutSec $XelabTimeoutSeconds
} else {
    Write-Host "Reusing xelab snapshot: $snap"
}

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
