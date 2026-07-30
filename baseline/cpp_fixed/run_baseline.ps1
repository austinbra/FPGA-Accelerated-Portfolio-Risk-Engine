param(
    [int]$Paths = 1024,
    [int]$Steps = 12,
    [double]$S0 = 100.0,
    [double]$K = 100.0,
    [double]$R = 0.05,
    [double]$Sigma = 0.2,
    [double]$T = 1.0,
    [string]$InputFile = "",
    [switch]$UseBoost,
    [string]$BoostInclude = ""
)

$ErrorActionPreference = "Stop"

$defs = ""
$incs = ""
if ($UseBoost) {
    $defs = "-DUSE_BOOST_SOBOL"
}
if ($BoostInclude -ne "") {
    $incs = "-I`"$BoostInclude`""
}

g++ -std=c++17 $defs $incs main.cpp pricing.cpp linalg.cpp rtl_math.cpp sobol_wrapper.cpp utils.cpp -o fixed_baseline
if ($LASTEXITCODE -ne 0) {
    throw "Build failed."
}

if ($InputFile -ne "") {
    ./fixed_baseline --input-file $InputFile
} else {
    ./fixed_baseline --paths $Paths --steps $Steps --S0 $S0 --K $K --r $R --sigma $Sigma --T $T
}
