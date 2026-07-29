# FPGA QMC-LSM Portfolio Risk Engine

This is inherited from my own 2025 implementation and turns an FPGA-accelerated American option pricer into a broader hardware-accelerated portfolio risk project.

This includes a completed QMC-LSM pricing kernel with bit-exact C++/RTL parity, UART control, Sobol quasi-Monte Carlo paths, fixed-point Longstaff-Schwartz regression, and 100 MHz Vivado builds for Arty A7-100T and Arty S7-50. This fork uses that kernel where it is strongest: repeated pricing, scenario sweeps, Greeks, and eventually path-dependent or multi-asset derivatives where tree methods become less attractive.

The new project goal is:

```text
Portfolio and scenario inputs
    -> host-side contract and bump scheduler
    -> FPGA QMC-LSM pricing kernel
    -> prices, Greeks, scenario PnL, and aggregated risk reports
```

## Why This Fork Exists

The original project proved the hardware kernel. This fork asks where that kernel is useful.

A single vanilla American option is not the strongest product story because a binomial tree can already handle it well. The stronger use case is repeated valuation:

- many contracts in a portfolio,
- many market scenarios,
- bumped revaluations for Greeks,
- early-exercise products,
- path-dependent payoffs such as Asian options,
- multi-asset payoffs such as baskets with correlation.

The FPGA kernel gives the project a deterministic, measurable acceleration target. The host software around it turns that target into a useful risk workflow.

## Current Foundation

The inherited kernel is complete and should remain the regression baseline while the product layer grows.

| Capability | Status |
|------------|--------|
| Sobol QMC path stream from `src/gen/direction.mem` | Complete |
| Q16.16 fixed-point GBM path generation | Complete |
| Single-date compatibility mode | Complete |
| Multi-date LSM PUT backward induction | Complete |
| No-dividend CALL terminal fast path while `q=0` | Complete |
| Bit-exact C++/RTL mirror | Complete |
| UART parameter/result packet | Complete |
| Financial accuracy study versus American CRR reference | Complete |
| Regression health metrics | Complete |
| A7-100T and S7-50 100 MHz routed builds | Complete |
| Portfolio CSV runner | Planned |
| Scenario sweep runner | Planned |
| Greeks bump/revalue engine | Planned |
| Asian payoff | Planned |
| Basket/correlation support | Planned |

## FPGA Kernel Result

The active stored-path multi-date RTL is timing-clean at 100 MHz on both
supported boards. The larger A7-100T fits four lanes; the S7-50 timing-clean
100 MHz bitstream uses one lane, and a denser two-lane S7-50 bitstream closes at
95.24 MHz.

| Target | Part | Clock | WNS | TNS | Failing endpoints | Bitstream |
|--------|------|-------|-----|-----|-------------------|-----------|
| Arty A7-100T, 4 lanes | XC7A100T | 100 MHz / 10 ns | +0.144 ns | 0.000 ns | 0 | `vivado_build/arty_a7_100_multi_lanes4_10ns/arty_a7_qmc_multi.bit` |
| Arty S7-50, 1 lane | XC7S50 | 100 MHz / 10 ns | +0.310 ns | 0.000 ns | 0 | `vivado_build/arty_s7_50_multi_lanes1_10ns/arty_s7_qmc_multi.bit` |
| Arty S7-50, 2 lanes | XC7S50 | 95.24 MHz / 10.5 ns | +0.083 ns | 0.000 ns | 0 | `vivado_build/arty_s7_50_multi_lanes2_10p5ns/arty_s7_qmc_multi.bit` |

The S7-50 two-lane configuration does not close at 100 MHz (it misses by
-0.180 ns), so it is published at its honest 95.24 MHz closing clock rather than
claimed at 100 MHz.

Post-route utilization:

| Target | LUTs | Registers | DSP48E1 | RAMB36 |
|--------|------|-----------|---------|--------|
| Arty A7-100T, 4 lanes | 45,875 / 63,400 = 72.36% | 46,911 / 126,800 = 37.00% | 180 / 240 = 75.00% | 66 / 135 = 48.89% |
| Arty S7-50, 1 lane | 23,399 / 32,600 = 71.78% | 28,967 / 65,200 = 44.43% | 84 / 120 = 70.00% | 65 / 75 = 86.67% |
| Arty S7-50, 2 lanes | 30,606 / 32,600 = 93.88% | 34,855 / 65,200 = 53.46% | 116 / 120 = 96.67% | 65 / 75 = 86.67% |

FPGA compute time is measured from the RTL `core_cycles` counter divided by the implemented clock frequency. UART round-trip time is tracked separately by the host scripts because serial transfer and host scheduling are not pricing-core work.

## Pricing Contract

The current kernel prices vanilla American-style options under geometric Brownian motion:

- PUT: multi-exercise Longstaff-Schwartz backward induction at simulated dates `1..M-1`.
- CALL: no-dividend terminal fast path while `q=0`.
- Numeric format: signed Q16.16.
- Production random stream: Sobol QMC from `src/gen/direction.mem`, starting at Sobol index 1.
- Regression basis for PUT continuation: `[1, S/K - 1, (S/K - 1)^2]`.
- Regression fallback: singular or unstable solves fall back to mean continuation; beta coefficients above the Q16.16 cap of 4096.0 also trigger fallback.

Legacy regeneration-based v1 parity snapshot:

| Case | C++ Q16.16 | RTL Q16.16 | Delta | Core cycles |
|------|------------|------------|-------|-------------|
| Single-date PUT, N=64, M=12 | 263,688 | 263,688 | 0 LSB | 75,603 |
| Multi-date PUT, N=64, M=12 | 373,676 | 373,676 | 0 LSB | 461,245 |
| Multi-date PUT, N=256, M=12 | 426,642 | 426,642 | 0 LSB | 1,843,158 |
| Multi-date PUT, N=1024, M=12 | 428,757 | 428,757 | 0 LSB | 7,370,906 |
| Multi-date CALL, N=64, M=12 | 482,546 | 482,546 | 0 LSB | 37,726 |

The active stored-path v2 engine preserves the same N=1024/M=12 raw price
(`428,757`, `0x00068AD5`) while reducing the compute window to 720,474,
411,626, 236,362, and 121,290 cycles for 1, 2, 4, and 8 lanes respectively.
The routed four-lane A7-100T finishes in 2.364 ms, a 31.18x cycle reduction
from v1, and sustains 5.199 million path-date evaluations/s. Eight lanes
simulates in 1.213 ms but does not fit the A7-100T. See
`.user/PERFORMANCE_MATRIX.md` for the complete path/date matrix, optimized C++
comparison, accuracy evidence, and claim boundaries.

## Product Architecture

The fork should add host-side product infrastructure before changing RTL.

```text
examples/portfolio.csv
    -> scripts/portfolio_price.py
    -> contract normalization and validation
    -> target selector: cpu | fpga | both
    -> existing C++ mirror or UART FPGA path
    -> position prices and portfolio value

examples/scenarios.csv
    -> scripts/scenario_sweep.py
    -> market bumps and named shocks
    -> repeated pricing jobs
    -> scenario PnL report

Greek bump engine
    -> delta, gamma, vega, rho, theta bumps
    -> repeated pricing jobs
    -> position and portfolio exposures
```

Defer variance reduction, Brownian bridge, and higher-fmax work until measurements from the product layer show a real bottleneck. Stored-path, banked, multi-lane multi-date RTL is implemented.

## Roadmap

1. Add portfolio CSV schema and examples.
2. Add `scripts/portfolio_price.py` using the existing C++ mirror first.
3. Add `--target fpga` and `--target both` through `src/uart_host.py`.
4. Add scenario sweep input and scenario PnL output.
5. Add bump/revalue Greeks.
6. Add Markdown and CSV risk reports.
7. Add Asian payoff support.
8. Add basket payoff and correlation input.
9. Add market regime or event features only if they improve measured risk forecasts.

The internal planning docs live in [`.user`](.user/README.md). The AI/session memory lives in [`.ai`](.ai/README.md).

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

### Run parity gates

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
```

### Build Vivado bitstreams

```powershell
.\scripts\run_vivado_build_arty_a7.ps1 -MultiExercise -ClockPeriodNs 10 -TimeoutSeconds 21600
.\scripts\run_vivado_build_arty_s7.ps1 -MultiExercise -ClockPeriodNs 10 -TimeoutSeconds 21600
```

### Program and benchmark hardware

```powershell
.\scripts\program_arty_a7.ps1 -Bit vivado_build\arty_a7_100_multi_10ns\arty_a7_qmc_multi.bit
python src\uart_host.py --mode benchmark --target fpga --param-file baseline\cpp_fixed\params_example.txt --port COM4 --fpga-fclk-hz 100000000
```

Use `--target both` to run the C++ mirror and FPGA UART path together.

## Repository Map

```text
src/                      SystemVerilog core and UART host path
src/math/                 Q16.16 multiply/divide/exp/log/sqrt/inverse-CDF support
src/steps/                Sobol, GBM, accumulator, regression, LSM decision
src/top/                  single-date and multi-date top-level orchestration
fpga/                     board wrappers
constraints/              board XDC constraints
scripts/                  build, validation, diagnosis, accuracy, and future product scripts
baseline/cpp_fixed/       bit-exact fixed-point C++ mirror
tb/                       RTL testbenches
.user/                    project memory, roadmap, validation, and product scope
.ai/                      AI/session memory and operating rules
```

## Documentation Map

- [`.user/PORTFOLIO_RISK_ENGINE_LAB_MANUAL.md`](.user/PORTFOLIO_RISK_ENGINE_LAB_MANUAL.md): extensive learning-first implementation plan, exercises, validation gates, and interview preparation.
- [`PROJECT_REPORT.md`](PROJECT_REPORT.md): longer explanation of the fork scope and inherited kernel.
- [`.user/IMPLEMENTATION_STATUS.md`](.user/IMPLEMENTATION_STATUS.md): current implementation state.
- [`.user/ROADMAP.md`](.user/ROADMAP.md): product roadmap.
- [`.user/FUTURE_PROJECT.md`](.user/FUTURE_PROJECT.md): larger product story and naming guidance.
- [`.user/VALIDATION.md`](.user/VALIDATION.md): gates to keep the kernel trustworthy.
- [`.user/ACCURACY.md`](.user/ACCURACY.md): financial accuracy methodology.

## Project Boundary

The inherited option pricer is a foundation, not the final product of this fork. Preserve its validation gates, then build the portfolio risk layer around it.

Do not market the project as a sentiment-driven options pricer. Sentiment or event data can be added later only if it measurably improves volatility, correlation, jump-risk, or scenario selection.
