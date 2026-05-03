# FPGA-Accelerated QMC-LSM American Option Pricer

This repository is the completed thesis version of a hardware-accelerated American option pricing kernel. It implements Longstaff-Schwartz Monte Carlo (LSM) with a Sobol quasi-Monte Carlo stream, fixed-point arithmetic, UART control, C++/RTL parity tooling, financial accuracy studies, and Vivado implementation flows for Digilent Arty A7-100T and Arty S7-50 boards.

The project ends here as a pricing kernel. The next product story starts in [`.user/FUTURE_PROJECT.md`](.user/FUTURE_PROJECT.md): portfolio CSVs, scenario sweeps, Greeks, path-dependent payoffs, and risk reporting.

## Thesis Result

The final multi-exercise-date RTL build is timing-clean at 100 MHz on both supported thesis targets.

| Target | Part | Clock | WNS | TNS | Failing endpoints | Bitstream |
|--------|------|-------|-----|-----|-------------------|-----------|
| Arty A7-100T | XC7A100T | 100 MHz / 10 ns | +0.153 ns | 0.000 ns | 0 | `vivado_build/arty_a7_100_multi_10ns/arty_a7_qmc_multi.bit` |
| Arty S7-50 | XC7S50 | 100 MHz / 10 ns | +0.113 ns | 0.000 ns | 0 | `vivado_build/arty_s7_50_multi_10ns/arty_s7_qmc_multi.bit` |

Post-route utilization:

| Target | LUTs | Registers | DSP48E1 | RAMB36 |
|--------|------|-----------|---------|--------|
| Arty A7-100T | 23,167 / 63,400 = 36.54% | 27,873 / 126,800 = 21.98% | 80 / 240 = 33.33% | 16 / 135 = 11.85% |
| Arty S7-50 | 23,154 / 32,600 = 71.02% | 27,873 / 65,200 = 42.75% | 80 / 120 = 66.67% | 16 / 75 = 21.33% |

Timing was measured from Vivado post-route `report_timing_summary` after `route_design`. Resource use was measured from Vivado post-route `report_utilization`. FPGA compute time is measured from the RTL `core_cycles` counter divided by the implemented clock frequency. UART round-trip is reported separately by the host scripts because serial I/O is not the pricing-core timer.

## What It Prices

The core prices vanilla American-style options under geometric Brownian motion:

- PUT: full multi-exercise Longstaff-Schwartz backward induction at simulated dates `1..M-1`.
- CALL: no-dividend fast path while `q=0`; non-dividend American calls are not exercised early in the Black-Scholes/GBM model.
- Default numerical format: signed Q16.16.
- Default production random stream: Sobol QMC from `src/gen/direction.mem`, starting at Sobol index 1.

The design is useful as a hardware kernel because LSM scales to early-exercise, path-dependent, and eventually multi-asset derivatives where binomial trees and PDE grids become less attractive. This thesis version proves the kernel, the fixed-point mirror, the timing closure, and the validation approach.

## Architecture

```text
UART parameters
    -> init constants
    -> Sobol QMC
    -> inverse normal CDF
    -> GBM path generation
    -> terminal cashflow RAM
    -> backward LSM regression and decisions
    -> final discounted average
    -> UART result packet
```

Important implementation choices:

- **Sobol instead of pseudo-random MT:** deterministic QMC is repeatable, low state, FPGA-friendly, and useful for convergence studies.
- **Skip Sobol index 0:** Sobol index 0 produces a boundary value. Production starts at index 1.
- **Open-interval guard:** after RTL truncates `sobol_out[31:16]`, `u_q16=0` is remapped to `1`. This prevents inverse-CDF from seeing exactly zero, which would drive `ln(0)` toward infinity and can poison divisions or square-root inputs.
- **Fixed-point Q16.16:** enough precision for the thesis kernel while keeping multipliers, ROMs, and dividers tractable.
- **C++ FPGA-style mirror:** the software parity oracle uses the same Sobol direction file, LUTs, fixed-point transforms, regression policy, and final averaging as RTL.
- **Cashflow BRAM, not full path storage:** multi-date RTL stores one Q16.16 cashflow per path and regenerates deterministic path prefixes for each exercise step. This avoids storing `S[path][step]`, keeps BRAM modest, and preserves exact replay.
- **Centered regression basis:** PUT continuation uses `[1, S/K - 1, (S/K - 1)^2]`, which improves conditioning around the strike.
- **Regression fallback:** singular or unstable regression falls back to mean continuation; beta coefficients above the Q16.16 cap of 4096.0 also trigger fallback.
- **True multiplier pipeline:** `fxMul` registers the 64-bit raw product before Q-format rounding/truncation. This is the fix that enabled 100 MHz.

## Validation Snapshot

Price parity is measured by comparing the RTL UART simulation result against `baseline/cpp_fixed/fixed_baseline --fpga-style --exercise-mode ...` using identical Q16.16 parameters, Sobol stream, and LUTs.

| Case | C++ Q16.16 | RTL Q16.16 | Delta | Core cycles |
|------|------------|------------|-------|-------------|
| Single-date PUT, N=64, M=12 | 263,688 | 263,688 | 0 LSB | 75,603 |
| Multi-date PUT, N=64, M=12 | 373,676 | 373,676 | 0 LSB | 461,245 |
| Multi-date PUT, N=256, M=12 | 426,642 | 426,642 | 0 LSB | 1,843,158 |
| Multi-date PUT, N=1024, M=12 | 428,757 | 428,757 | 0 LSB | 7,370,906 |
| Multi-date CALL, N=64, M=12 | 482,546 | 482,546 | 0 LSB | 37,726 |

At 100 MHz, the measured core-only times are:

- N=64, M=12 multi-date PUT: `461245 / 100e6 = 4.61245 ms`.
- N=256, M=12 multi-date PUT: `1843158 / 100e6 = 18.43158 ms`.
- N=1024, M=12 multi-date PUT: `7370906 / 100e6 = 73.70906 ms`.

Larger simulation spot checks were also used during bring-up; the main post-route thesis timing/resource claims are the A7-100T and S7-50 100 MHz reports above.

## Accuracy Measurement

Hardware parity and financial accuracy are separate questions.

- **Parity:** Does RTL equal the bit-exact C++ mirror? Measured in raw Q16.16 LSBs.
- **Financial accuracy:** How far is the method from a high-precision reference? Measured in basis points of spot and basis points of reference price.

The financial reference is implemented in `scripts/financial_reference.py`:

- Cox-Ross-Rubinstein American binomial tree for PUT/CALL with `q=0`.
- Black-Scholes European formula for sanity checks.
- Single-exercise tree to isolate the old single-date modeling gap.

`scripts/accuracy_study.py` attributes error into:

- single-exercise modeling error,
- Sobol/LSM estimator and regression error,
- fixed-point hardware error,
- total error versus the American CRR reference.

The key result is that multi-date LSM materially improves PUT accuracy while fixed-point error remains controlled at useful path counts. The current kernel is therefore limited more by estimator/model choices than by RTL arithmetic.

## Build And Run

### Build the C++ mirror

```powershell
cd baseline/cpp_fixed
g++ -std=c++17 main.cpp pricing.cpp linalg.cpp rtl_math.cpp sobol_wrapper.cpp utils.cpp -o fixed_baseline
cd ..\..
```

Run the bit-exact multi-date software mirror:

```powershell
.\baseline\cpp_fixed\fixed_baseline.exe --paths 1024 --steps 12 --S0 100 --K 100 --r 0.05 --sigma 0.2 --T 1 --option-type 1 --fpga-style --exercise-mode multi --direction-file src\gen\direction.mem --lut-dir src\gen
```

### Compile, elaborate, and simulate RTL

```powershell
.\scripts\run_xvlog_src.ps1
.\scripts\run_xelab_smoke.ps1
.\scripts\run_tb_top_uart_safe.ps1 -ComputeMode
.\scripts\run_tb_top_uart_safe.ps1 -MultiExercise -TestPlusargs "paths=64,steps=12,S0=6553600,K=6553600,r=3277,sigma=13107,T=65536,opt=1"
```

### Run numerical parity gates

```powershell
python scripts\validate_numerical.py --exercise-mode single --paths 64 --steps 12 --option-type 1 --build-cpu
python scripts\validate_numerical.py --exercise-mode multi --paths 64 --steps 12 --option-type 1 --build-cpu
python scripts\validate_numerical.py --exercise-mode multi --paths 256 --steps 12 --option-type 1
python scripts\diagnose_numerical.py --paths 64 --steps 12 --option-type 1 --exercise-mode multi
```

### Run financial accuracy studies

```powershell
python scripts\accuracy_study.py --preset smoke --build-cpu --attribution
python scripts\accuracy_study.py --preset default --exercise-mode both --build-cpu --attribution --health-metrics --output-dir .tmp\accuracy_default_health
python scripts\accuracy_study.py --preset smoke --paths-list 1024,4096,8192 --steps-list 12,20 --moneyness-list 0.6,0.8,1.0,1.2,1.4 --sigma-list 0.05,0.2,0.4,0.6 --option-types put,call --exercise-mode both --build-cpu --attribution --health-metrics --output-dir .tmp\accuracy_stress_health
```

Outputs:

- `accuracy_results.csv`
- `accuracy_summary.md`
- `health/health_rows.csv` when `--health-metrics` is enabled.

### Build Vivado bitstreams

Arty A7-100T, multi-date, 100 MHz:

```powershell
.\scripts\run_vivado_build_arty_a7.ps1 -MultiExercise -ClockPeriodNs 10 -TimeoutSeconds 21600
```

Arty S7-50, multi-date, 100 MHz:

```powershell
.\scripts\run_vivado_build_arty_s7.ps1 -MultiExercise -ClockPeriodNs 10 -TimeoutSeconds 21600
```

The build scripts generate timing and utilization reports next to each bitstream.

### Program and benchmark hardware

```powershell
.\scripts\program_arty_a7.ps1 -Bit vivado_build\arty_a7_100_multi_10ns\arty_a7_qmc_multi.bit
python src\uart_host.py --mode benchmark --target fpga --param-file baseline\cpp_fixed\params_example.txt --port COM4 --fpga-fclk-hz 100000000
```

Use `--target both` to run the C++ mirror and FPGA UART path together. The host prints CPU wall time, FPGA core time from `core_cycles / fpga_fclk_hz`, UART round-trip time, price deltas, and speedup.

### Virtual hardware timing

When a board is not connected, the virtual flow runs the same UART compute testbench and scales the DUT cycle counter by the implemented clock.

```powershell
.\scripts\run_virtual_a7_benchmark.ps1 -ParamFile baseline\cpp_fixed\params_example.txt -NumLanes 1 -FclkHz 100000000
```

This is cycle-accurate for the RTL core and post-route clock target, but it is not a USB-UART silicon measurement.

## UART Protocol

The host sends one batch of Q16.16 parameters:

```text
paths, steps, S0, K, r, sigma, T, option_type
```

`option_type=0` means CALL and `option_type=1` means PUT.

The FPGA returns a result packet with:

```text
marker, price_q16, core_cycles_low, core_cycles_high, status_flags
```

`core_cycles` measures pricing-core runtime. UART wall time includes serial transfer, host scheduling, and parsing, so it is tracked separately.

## Repository Map

```text
src/                      SystemVerilog core
src/math/                 Q16.16 multiply/divide/exp/log/sqrt/inverse-CDF support
src/steps/                Sobol, GBM, accumulator, regression, LSM decision
src/top/                  single-date and multi-date top-level orchestration
fpga/                     board wrappers
constraints/              board XDC constraints
scripts/                  build, validation, diagnosis, and study scripts
baseline/cpp_fixed/       bit-exact fixed-point C++ mirror
tb/                       RTL testbenches
.user/                    private project memory and next-product planning
.cursor/                  AI/Cursor handoff rules
```

## Completed Scope

Completed in this repository:

- bit-exact C++/RTL pricing mirror,
- Sobol QMC stream with boundary guard,
- single-date and multi-date LSM,
- PUT/CALL handling for `q=0`,
- stage-by-stage numerical diagnosis,
- regression health metrics,
- American CRR financial accuracy study,
- true pipelined fixed-point multiplier,
- 100 MHz Vivado implementation on A7-100T and S7-50,
- UART benchmark path.

Out of scope for this completed thesis kernel:

- dividend yield input,
- Asian or basket payoff,
- correlation matrix input,
- portfolio CSV mode,
- Greeks and scenario PnL,
- market-data regime model,
- sentiment/event ingestion.

Those are the next product phase, documented in [`.user/FUTURE_PROJECT.md`](.user/FUTURE_PROJECT.md).

## Full Project Report

For the longer explanation of the algorithm, decisions, debugging path, accuracy methodology, and lessons learned, read [`PROJECT_REPORT.md`](PROJECT_REPORT.md).
