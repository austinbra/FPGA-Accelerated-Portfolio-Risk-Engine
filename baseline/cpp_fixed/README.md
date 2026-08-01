# Fixed-Point C++ Pricing Mirror

This directory contains the C++17 executable specification for the FPGA pricing
kernel. It serves three roles:

- bit-exact raw-price oracle for RTL and physical hardware;
- CPU implementation for scenario/Greek workflow development;
- named CPU timing boundaries through Google Benchmark.

The C++ mirror did not use the faulty RTL divider output packet. Its canonical
raw prices remain 391,343 for 1,024 x 4 and 428,757 for 1,024 x 12. Corrected
full RTL with generated Xilinx divider VHDL now matches both values exactly.

## Build the CLI

From the repository root:

```powershell
cd baseline\cpp_fixed
g++ -std=c++17 -O3 -DNDEBUG main.cpp pricing.cpp linalg.cpp rtl_math.cpp sobol_wrapper.cpp utils.cpp -o fixed_baseline
cd ..\..
```

`-O3 -DNDEBUG` is appropriate for performance measurement. For debugging,
remove `-DNDEBUG` and use `-O0 -g`; do not compare that binary with FPGA timing.

## Run Canonical Workloads

```powershell
.\baseline\cpp_fixed\fixed_baseline.exe `
  --input-file baseline\cpp_fixed\params_latency_1024x4.txt `
  --fpga-style `
  --exercise-mode multi

.\baseline\cpp_fixed\fixed_baseline.exe `
  --input-file baseline\cpp_fixed\params_monthly_1024x12.txt `
  --fpga-style `
  --exercise-mode multi
```

Expected raw Q16.16 outputs:

| Workload | Raw | Decoded |
|---|---:|---:|
| 1,024 paths x 4 steps | 391,343 | 5.97142029 |
| 1,024 paths x 12 steps | 428,757 | 6.54231262 |

Raw equality is the hardware parity check. Decimal text can hide a one-LSB
difference.

## FPGA-Style Contract

The `--fpga-style` path mirrors the active RTL:

- reads `src/gen/direction.mem`;
- starts at Sobol index 1;
- truncates `sobol_out[31:16]`;
- guards the lower endpoint for the inverse-normal transform;
- uses matching Q16.16 multiply, divide, LUT, sqrt, regression, discount, and
  final-average rules;
- applies the same singular/beta-cap fallback;
- applies the same valuation-time intrinsic floor.

Use:

- `--exercise-mode single` for historical single-exercise compatibility;
- `--exercise-mode multi` for the active discrete-date PUT kernel;
- `--option-type 0` for CALL;
- `--option-type 1` for PUT.

No-dividend CALLs use terminal exercise while `q=0`.

## File-Driven Input

Format:

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

Example:

```powershell
.\baseline\cpp_fixed\fixed_baseline.exe `
  --input-file baseline\cpp_fixed\params_example.txt `
  --fpga-style `
  --exercise-mode multi
```

## What Google Benchmark Adds

Timing a command with `Measure-Command` includes process startup and gives poor
control over warmup and repetitions. Google Benchmark runs an in-process
fixture, repeats it, and emits aggregate statistics plus JSON.

The executable exposes four families:

- `BM_HotKernelMultiPutMatrix`: directions and reusable path storage persist;
  path generation and pricing are timed.
- `BM_PricingCoreMultiPutMatrix`: path allocation is also timed.
- `BM_EndToEndMultiPutMatrix`: direction-file loading is also timed.
- `BM_MultiDateInductionOnly`: only backward induction is timed after paths are
  generated outside the measurement.

The first three are complete-pricing boundaries. Induction-only is useful for
profiling but is not a complete FPGA comparison.

Every timed complete-pricing iteration checks its raw result against the known
oracle. One-time LUT setup and process startup are outside the timed region.

## Build Google Benchmark

From the repository root:

```powershell
New-Item -ItemType Directory -Force .tmp\bench-tmp | Out-Null
$env:TEMP = (Resolve-Path .tmp\bench-tmp).Path
$env:TMP = $env:TEMP

cmake `
  -S baseline\cpp_fixed `
  -B .tmp\bench-google `
  -G "MinGW Makefiles" `
  -DCMAKE_BUILD_TYPE=Release

cmake --build .tmp\bench-google --target qmc_google_benchmark -j
```

CMake uses an installed Google Benchmark package when available; otherwise it
fetches the pinned official v1.9.4 release into the ignored build tree.

## Run the Exact Comparison

```powershell
.\.tmp\bench-google\qmc_google_benchmark.exe `
  "--benchmark_filter=BM_(HotKernel|PricingCore|EndToEnd)MultiPutMatrix" `
  "--benchmark_repetitions=15" `
  "--benchmark_min_time=0.05s" `
  "--benchmark_report_aggregates_only=true" `
  "--benchmark_out=.tmp/google-benchmark-final.json" `
  "--benchmark_out_format=json"
```

Use Release mode and at least 15 repetitions. Record CPU model, compiler, and
benchmark JSON with the result.

## Corrected Recorded Means

Measured with MinGW-W64 g++ 14.2.0 on the recorded Intel64 Family 6 Model 186
host, 15 repetitions:

| Workload | Hot kernel | Pricing core | End to end |
|---|---:|---:|---:|
| 1,024 x 4 | 0.485392 ms | 0.551170 ms | 0.889880 ms |
| 1,024 x 12 | 1.187450 ms | 1.208134 ms | 1.611681 ms |

Corrected four-lane FPGA core intervals at the routed A7 105.263 MHz clock are
0.867369 ms and 2.791005 ms respectively.

Boundary-specific ratios:

| Workload | Hot/FPGA | Pricing/FPGA | End-to-end/FPGA |
|---|---:|---:|---:|
| 1,024 x 4 | 0.560x | 0.635x | 1.026x |
| 1,024 x 12 | 0.425x | 0.433x | 0.577x |

A value below 1 means that CPU boundary is shorter. A value above 1 means the
FPGA core interval is shorter. These are not interchangeable with UART
round-trip or complete application latency.

## Learning to Read Benchmark Output

For a benchmark row:

- **real_time** is wall-clock time per iteration and is the comparison used in
  this project;
- **cpu_time** is processor time consumed by the benchmark thread;
- **iterations** is how many operations Google Benchmark ran;
- aggregate suffixes such as `_mean`, `_median`, and `_stddev` summarize the
  requested repetitions;
- the `time_unit` field determines whether the number is ns, us, or ms.

Prefer the JSON to copying console columns. The evidence collector validates
units, repetition count, expected benchmark names, compiler mode, and source
provenance.

## Using the Mirror for Risk Work

`scripts/bump_revalue.py` calls the CLI for base and bumped jobs. It restarts at
Sobol index 1 for common random numbers, then computes central-difference delta,
gamma, and vega.

The recommended next C++ task is to extract the pricing request/result contract
into a reusable library while keeping this CLI as a thin adapter. That gives
portfolio Python code a stable, testable CPU backend and develops useful C++ API
and ownership skills before adding new RTL.

## Comparison Rules

When comparing CPU and FPGA:

- keep paths, steps, parameters, exercise mode, lanes, and Sobol directions
  identical;
- use the FPGA internal `core_cycles` divided by routed core frequency;
- name the CPU boundary;
- report UART transport separately;
- never use old one-cycle-stub counts;
- never state a generic speedup from unlike boundaries.

The tracked source of record is
[`../../results/claims/claim_evidence.md`](../../results/claims/claim_evidence.md).
