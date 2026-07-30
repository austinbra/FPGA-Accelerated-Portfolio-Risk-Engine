# Fixed-Point C++ Pricing Mirror

This directory contains the C++17 fixed-point mirror developed alongside the
FPGA pricing kernel. It has two jobs:

- provide a bit-exact parity oracle for RTL,
- provide the CPU target for the implemented single-contract bump/revalue
  workflow when a board is not connected.

## Build

From this directory:

```powershell
g++ -std=c++17 -O3 -DNDEBUG main.cpp pricing.cpp linalg.cpp rtl_math.cpp sobol_wrapper.cpp utils.cpp -o fixed_baseline
```

From the repository root:

```powershell
cd baseline\cpp_fixed
g++ -std=c++17 -O3 -DNDEBUG main.cpp pricing.cpp linalg.cpp rtl_math.cpp sobol_wrapper.cpp utils.cpp -o fixed_baseline
cd ..\..
```

## Google Benchmark

The Google Benchmark executable measures the bit-exact multi-date PUT
in-process. It reports three complete-pricing boundaries plus induction-only:

- `BM_HotKernelMultiPutMatrix`: direction data and path storage are persistent;
  Sobol/GBM generation and LSM induction are timed. This is the closest match
  to a persistent FPGA kernel.
- `BM_PricingCoreMultiPutMatrix`: also times path-vector allocation.
- `BM_EndToEndMultiPutMatrix`: also loads the Sobol direction file per request.
- `BM_MultiDateInductionOnly`: induction on paths generated before timing.

One-time RTL LUT loading is excluded. Every timed full-pricing iteration checks
its Q16.16 result against the matching RTL oracle.

From the repository root:

```powershell
New-Item -ItemType Directory -Force .tmp\bench-tmp | Out-Null
$env:TEMP = (Resolve-Path .tmp\bench-tmp).Path
$env:TMP = $env:TEMP
cmake -S baseline\cpp_fixed -B .tmp\bench-google -G "MinGW Makefiles" -DCMAKE_BUILD_TYPE=Release
cmake --build .tmp\bench-google --target qmc_google_benchmark -j
.\.tmp\bench-google\qmc_google_benchmark.exe `
  "--benchmark_filter=BM_(HotKernel|PricingCore|EndToEnd)MultiPutMatrix" `
  "--benchmark_repetitions=15" `
  "--benchmark_min_time=0.05s" `
  "--benchmark_report_aggregates_only=true" `
  "--benchmark_out=.tmp/google-benchmark-final.json" `
  "--benchmark_out_format=json"
```

CMake first looks for an installed Google Benchmark package. If none is found,
it fetches the pinned official `v1.9.4` release into the build directory.

Measured on a 13th Gen Intel Core i9-13905H (20 logical CPUs), MinGW Release
`-O3 -DNDEBUG`, using 30 repetitions of the exact 1,024x12 case:

| Complete-pricing boundary | Real-time mean | Median | Std. dev. |
|---------------------------|---------------:|-------:|----------:|
| Hot kernel, persistent direction/storage | 1.285 ms | 1.283 ms | 0.055 ms |
| Pricing core plus path allocation | 1.336 ms | 1.332 ms | 0.148 ms |
| End-to-end plus direction-file load | 1.860 ms | 1.851 ms | 0.083 ms |

The machine-readable exact-case output is
`.tmp/google-benchmark-1024x12.json`; the full path/date matrix is
`.tmp/google-benchmark-final.json`. For FPGA/CPU comparisons, report all three
boundaries or use the hot-kernel row as the conservative apples-to-apples
number. UART round-trip and process startup are outside these timings.

## Run The FPGA-Style Mirror

The `--fpga-style` path mirrors the RTL contract:

- reads the RTL Sobol `direction.mem`,
- starts at Sobol index 1,
- truncates `sobol_out[31:16]`,
- applies the one-LSB lower guard for `u=0`,
- mirrors the RTL LUT/division/sqrt/inverse-CDF/GBM/regression/final-average math.
- applies the same valuation-time intrinsic-value floor as the stored-path RTL.

Example:

```powershell
.\baseline\cpp_fixed\fixed_baseline.exe --paths 1024 --steps 12 --S0 100 --K 100 --r 0.05 --sigma 0.2 --T 1 --option-type 1 --fpga-style --exercise-mode multi --direction-file src\gen\direction.mem --lut-dir src\gen
```

Use:

- `--exercise-mode single` for historical single-date compatibility,
- `--exercise-mode multi` for the current discrete-date early-exercise kernel,
- `--option-type 0` for CALL,
- `--option-type 1` for PUT.

No-dividend CALLs use the terminal fast path while `q=0`. PUT and CALL
results are both floored at intrinsic value at the valuation spot.

## File-Driven Run

Input file format:

```text
paths=1024
steps=12
S0=100.0
K=100.0
r=0.05
sigma=0.2
T=1.0
option_type=1
# optional:
# direction_file=../../src/gen/direction.mem
# lut_dir=../../src/gen
```

Run:

```powershell
.\fixed_baseline.exe --input-file params.txt --fpga-style --exercise-mode multi
```

Example file: `params_example.txt`.

## Role In The Continued Project

The bump/revalue runner calls this mirror before hardware under the combined
target. That lets scenario expansion, Greek arithmetic, and exact raw-price
parity be tested without a connected board.

Implemented consumer:

- `scripts/bump_revalue.py`.

For CPU/FPGA measurements, use the three named Google Benchmark boundaries and
the FPGA core cycle count. Keep UART round-trip time separate, and do not state
a generic speedup across asymmetric boundaries.
