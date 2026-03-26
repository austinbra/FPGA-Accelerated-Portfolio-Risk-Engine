param(
    [switch]$IncludeSimDirs,
    [switch]$Quiet
)

$ErrorActionPreference = "SilentlyContinue"
$cleanRoot = Split-Path $PSScriptRoot -Parent

$filePatterns = @(
    "*.log",
    "*.jou",
    "*.pb",
    "*.wdb",
    "*.str",
    "*.debug",
    "webtalk*.log",
    "vivado*.log"
)

$removedFiles = 0
foreach ($pattern in $filePatterns) {
    $files = Get-ChildItem -Path $cleanRoot -Filter $pattern -File
    foreach ($f in $files) {
        Remove-Item -Force $f.FullName
        if (-not $?) { continue }
        $removedFiles++
        if (-not $Quiet) { Write-Host "Removed file: $($f.Name)" }
    }
}

$removedDirs = 0
if ($IncludeSimDirs) {
    foreach ($d in @("xsim.dir", ".Xil")) {
        $dPath = Join-Path $cleanRoot $d
        if (Test-Path $dPath) {
            Remove-Item -Recurse -Force $dPath
            if ($?) {
                $removedDirs++
                if (-not $Quiet) { Write-Host "Removed directory: $d" }
            }
        }
    }
}

if (-not $Quiet) {
    Write-Host "Cleanup complete: removed $removedFiles file(s), $removedDirs director(y/ies)."
}
