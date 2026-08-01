param(
    [switch]$NoGui
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$outputDir = Join-Path $repoRoot ".tmp\waveforms\uart_rx_lab"
$iverilog = "C:\Program Files\iverilog\bin\iverilog.exe"
$vvp = "C:\Program Files\iverilog\bin\vvp.exe"
$gtkwave = "C:\Program Files\iverilog\gtkwave\bin\gtkwave.exe"

foreach ($tool in @($iverilog, $vvp)) {
    if (-not (Test-Path -LiteralPath $tool)) {
        throw "Required Icarus Verilog tool not found: $tool"
    }
}

New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
$env:TEMP = $outputDir
$env:TMP = $outputDir

$simulation = Join-Path $outputDir "uart_rx_lab.vvp"
$waveform = Join-Path $outputDir "uart_rx_lab.vcd"

Push-Location $outputDir
try {
    & $iverilog -g2012 -s tb_uart_waveform -o $simulation `
        (Join-Path $repoRoot "src\io\uart\uart_rx.sv") `
        (Join-Path $repoRoot "src\io\uart\uart_rx32.sv") `
        (Join-Path $repoRoot "tb\tb_uart_waveform.sv")
    if ($LASTEXITCODE -ne 0) {
        throw "iverilog failed with exit code $LASTEXITCODE"
    }

    & $vvp $simulation
    if ($LASTEXITCODE -ne 0) {
        throw "UART waveform simulation failed with exit code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}

Write-Host "Waveform: $waveform"

if (-not $NoGui) {
    if (-not (Test-Path -LiteralPath $gtkwave)) {
        throw "GTKWave not found: $gtkwave"
    }
    $startupScript = Join-Path $PSScriptRoot "uart_waveform.gtkw.tcl"
    Start-Process -FilePath $gtkwave -ArgumentList @($waveform, "--script=$startupScript")
    Write-Host "Opened GTKWave. Signal phase 1 is continuous, 2 is bad-stop, and 3 is guarded."
}
