# FPGA QMC-LSM Early-Exercise Pricing Accelerator

This repository continues my original 2025 FPGA option-pricer project. The
first implementation established an end-to-end Sobol, fixed-point GBM,
Longstaff-Schwartz, RTL, and UART pipeline. Continued development corrected
financial and numerical weaknesses in that implementation and replaced its
regeneration-based execution with a four-lane stored-path architecture. The v1
results remain in this repository as a regression baseline and as evidence of
the design's evolution.

The current artifact is a measured hardware/software co-design prototype, not
a claim of production trading performance. Its central result is a numerically
sensitive pricing kernel carried from a C++17 reference through fixed-point RTL,
differential validation, FPGA implementation, timing closure, and honest
end-to-end measurement.

The implemented application layer is deterministic single-contract
bump-and-revalue, not a broad portfolio platform:

```text
Base and bumped contract parameters
    -> five-job host scheduler with one persistent FPGA session
    -> C++ reference or existing FPGA kernel
    -> prices, finite-difference Greeks, status, and latency measurements
```

## Where The Project Fits

A tree remains the better engineering choice for pricing one low-dimensional
vanilla American option. The credible use of this kernel is as a repeated
revaluation primitive for pre-trade what-if analysis, scenario experiments, or
bump-and-revalue Greeks. Reusing the same Sobol sequence for base and bumped
jobs also provides common random numbers, which can reduce noise in price
differences.

For a low-latency trading firm, the present kernel is most directly evidence of
hardware/software co-design: fixed-point range decisions, stall-safe streaming
RTL, parallel architecture, bit-exact reference modeling, synthesis, timing
closure, and measurement discipline. It is not presented as an order-execution
or market-data-path component. A production integration would require a
streaming PCIe or Ethernet transport, request batching, telemetry, and a
product-specific latency and accuracy study; the current UART link is a control
and validation interface.

## Implemented Boundary

Implemented today:

- one pricing request at a time,
- vanilla GBM dynamics in signed Q16.16 arithmetic,
- multi-date PUT exercise at simulated dates `1..M-1`,
- a terminal-only fast path for no-dividend CALLs,
- a valuation-time intrinsic-value floor for PUT and CALL results,
- at most 1,024 paths and 50 dates in the active stored-path RTL,
- bit-exact C++/RTL validation and routed FPGA measurements,
- a five-job common-random-number bump/revalue runner, and
- a persistent four-word UART session with explicit error decoding.

Not implemented today:

- portfolio ingestion or aggregation,
- path-dependent or multi-asset payoffs,
- calibration or live market-data integration,
- PCIe/AXI transport or production request batching.

## Current Foundation

The pricing kernel and narrow bump/revalue workflow are complete within the
boundary above.

| Capability | Status |
|------------|--------|
| Sobol QMC path stream from `src/gen/direction.mem` | Complete |
| Q16.16 fixed-point GBM path generation | Complete |
| Single-date compatibility mode | Complete |
| Multi-date LSM PUT backward induction | Complete |
| No-dividend CALL terminal fast path while `q=0` | Complete |
| Bit-exact C++/RTL mirror | Complete |
| RTL UART parameter/result packet | Complete |
| Host CPU/FPGA comparison path | Complete; timing boundaries remain separate |
| Financial accuracy study versus American CRR reference | Complete |
| Regression health metrics | Complete |
| Routed implementation evidence | Current post-hardening A7 route; June 2026 pre-hardening S7 routes retained as historical evidence |
| Single-contract bump/revalue runner | Complete |
| Persistent UART batch session | Complete |
| Portfolio CSV runner | Optional later work |
| Asian payoff | Optional advanced extension |
| Basket/correlation support | Optional advanced extension |

## FPGA Kernel Result

The current post-hardening stored-path RTL is timing-clean at 100 MHz on the
four-lane A7-100T. The S7-50 rows preserve June 24, 2026 pre-hardening route
evidence: one lane met 100 MHz, while a denser two-lane build closed at
95.24 MHz. Those S7 bitstreams predate the valuation-time intrinsic floor and
must be regenerated before being used as current C++/RTL parity artifacts.

| Target | Part | Clock | WNS | TNS | Failing endpoints | Bitstream |
|--------|------|-------|-----|-----|-------------------|-----------|
| Arty A7-100T, 4 lanes | XC7A100T | 100 MHz / 10 ns | +0.139 ns | 0.000 ns | 0 | `vivado_build/arty_a7_100_multi_lanes4_10ns/arty_a7_qmc_multi.bit` |
| Arty S7-50, 1 lane | XC7S50 | 100 MHz / 10 ns | +0.310 ns | 0.000 ns | 0 | `vivado_build/arty_s7_50_multi_lanes1_10ns/arty_s7_qmc_multi.bit` |
| Arty S7-50, 2 lanes | XC7S50 | 95.24 MHz / 10.5 ns | +0.083 ns | 0.000 ns | 0 | `vivado_build/arty_s7_50_multi_lanes2_10p5ns/arty_s7_qmc_multi.bit` |

The S7-50 two-lane configuration does not close at 100 MHz (it misses by
-0.180 ns), so it is published at its honest 95.24 MHz closing clock rather than
claimed at 100 MHz. Its timing and utilization values remain valid historical
measurements of the pre-hardening RTL.

Post-route utilization:

| Target | LUTs | Registers | DSP48E1 | RAMB36 |
|--------|------|-----------|---------|--------|
| Arty A7-100T, 4 lanes | 45,955 / 63,400 = 72.48% | 46,905 / 126,800 = 36.99% | 180 / 240 = 75.00% | 66 / 135 = 48.89% |
| Arty S7-50, 1 lane | 23,399 / 32,600 = 71.78% | 28,967 / 65,200 = 44.43% | 84 / 120 = 70.00% | 65 / 75 = 86.67% |
| Arty S7-50, 2 lanes | 30,606 / 32,600 = 93.88% | 34,855 / 65,200 = 53.46% | 116 / 120 = 96.67% | 65 / 75 = 86.67% |

For historical comparison, the immediately preceding A7 route measured
+0.144 ns WNS, 45,875 LUTs, 46,911 registers, 180 DSPs, and 66 block-RAM
tiles. The A7 rows above use the regenerated July 29, 2026 post-hardening
build; the S7 rows remain the labeled June pre-hardening measurements.

FPGA compute time is measured from the RTL `core_cycles` counter divided by the implemented clock frequency. UART round-trip time is tracked separately by the host scripts because serial transfer and host scheduling are not pricing-core work.

The headline latency workload is 1,024 paths by 4 steps. Four-lane RTL simulation
completes it in 72,394 cycles, or 0.72394 ms at the routed 100 MHz clock. **RTL
core latency** begins when the core accepts a complete job and ends at
`result_valid`; it includes initialization, Sobol/GBM generation, regression,
exercise decisions, and averaging, while excluding UART, USB, Python, and host
scheduling.

The separate 1,024-path by 12-step workload completes in 236,362 cycles, or
2.36362 ms. The two latency values describe different workloads. CPU results
are reported under three named boundaries—hot kernel, pricing core, and
end-to-end—in [the tracked claim report](results/claims/claim_evidence.md).
Boundary-specific ratios are retained there, but this project makes no generic
FPGA-versus-CPU speedup claim.

The 31.18x reduction from the 7,370,906-cycle regeneration-based v1 engine to
the 236,362-cycle four-lane stored-path engine is preserved below as a
historical within-project architecture comparison, not as the headline claim.

## Pricing Contract

The current kernel prices discrete-date early-exercise contracts under
geometric Brownian motion:

- PUT: Longstaff-Schwartz backward induction at simulated dates `1..M-1`.
- CALL: no-dividend terminal fast path while `q=0`.
- Final boundary: `max(discounted estimate, intrinsic value at S0)` for PUT
  and CALL.
- Numeric format: signed Q16.16.
- Production random stream: Sobol QMC from `src/gen/direction.mem`, starting at Sobol index 1.
- Regression basis for PUT continuation: `[1, S/K - 1, (S/K - 1)^2]`.
- Regression fallback: singular or unstable solves fall back to mean continuation; beta coefficients above the Q16.16 cap of 4096.0 also trigger fallback.

Exercise is available only on the simulated grid plus valuation time, so the
precise description is a discrete-time QMC-LSM approximation to American
exercise. Focused deep-in-the-money PUT and CALL tests verify the valuation-time
intrinsic floor in both C++ and four-lane RTL.

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
[`docs/performance.md`](docs/performance.md) for the complete path/date matrix, optimized C++
comparison, accuracy evidence, and claim boundaries.

## Implemented Bump/Revalue Workflow

`scripts/bump_revalue.py` submits base, spot-up, spot-down, volatility-up,
and volatility-down jobs. Every scenario restarts at Sobol index 1, providing
common random numbers. It calculates central-difference delta, gamma, and vega
and writes CSV plus JSON with parameters, raw and decoded prices, exercise
mode, status, CPU timing, FPGA core cycles/time, and transport time.

The `both` target requires exact raw Q16.16 parity for every scenario before
calculating Greeks, and the FPGA targets reuse one serial connection for the
complete batch. These Greeks demonstrate a deterministic numerical workflow;
they are not presented as calibrated, production-quality risk estimates.

## Remaining Hardware Gate

The new bitstream, RTL simulations, C++ workflow, and mocked UART protocol tests
are complete. A physical board was not attached during this pass, so the
30-run transport p50/p95/p99 capture and physical scenario parity remain
explicitly pending. The exact command is included below; no percentile is
claimed until it is run against the programmed four-lane image.

Portfolio ingestion, PCIe, RTL request queues, Asian options, and basket
correlation remain possible future directions, but they are explicitly outside
this hardening pass.

## Build And Run

### Build the C++ mirror

```powershell
cd baseline/cpp_fixed
g++ -std=c++17 -O3 -DNDEBUG main.cpp pricing.cpp linalg.cpp rtl_math.cpp sobol_wrapper.cpp utils.cpp -o fixed_baseline
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
.\scripts\run_tb_top_uart_safe.ps1 -MultiExercise -NumLanes 4 -TestPlusargs "paths=1024,steps=4,S0=6553600,K=6553600,r=3277,sigma=13107,T=65536,opt=1,expected_price=391343"
.\scripts\run_tb_top_uart_safe.ps1 -IntrinsicCase put
.\scripts\run_tb_top_uart_safe.ps1 -IntrinsicCase call
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
.\scripts\run_vivado_build_arty_a7.ps1 -MultiExercise -NumLanes 4 -ClockPeriodNs 10 -TimeoutSeconds 21600
.\scripts\run_vivado_build_arty_s7.ps1 -MultiExercise -NumLanes 1 -ClockPeriodNs 10 -TimeoutSeconds 21600
```

### Reproduce the tracked claim

```powershell
python scripts\reproduce_claims.py --cpp-mode run --xsim-mode run --benchmark-mode run --vivado-mode run --require-complete
```

This clean-clone command rebuilds the optimized C++ oracle, runs both canonical
four-lane simulations, runs all three Release CPU benchmark boundaries for 15
repetitions, reroutes the four-lane A7 design at 10 ns, and writes compact JSON,
CSV, and Markdown under `results/claims`. Raw build trees, checkpoints,
bitstreams, and verbose logs remain ignored.

### Program and benchmark hardware

```powershell
.\scripts\program_arty_a7.ps1 -Bit vivado_build\arty_a7_100_multi_lanes4_10ns\arty_a7_qmc_multi.bit
python src\uart_host.py --mode benchmark --target both --param-file baseline\cpp_fixed\params_latency_1024x4.txt --exercise-mode multi --num-lanes 4 --port COM4 --fpga-fclk-hz 100000000 --build-cpu
python src\uart_host.py --mode benchmark --target fpga --param-file baseline\cpp_fixed\params_latency_1024x4.txt --exercise-mode multi --num-lanes 4 --port COM4 --fpga-fclk-hz 100000000 --fpga-repetitions 30
python scripts\bump_revalue.py --target both --param-file baseline\cpp_fixed\params_monthly_1024x12.txt --exercise-mode multi --num-lanes 4 --port COM4 --output-prefix .tmp\bump_revalue\board
```

For the active four-lane bitstream, the parameter file must use at most 1,024
paths, at most 50 steps, and a path count divisible by four. The host validates
that envelope, finite and positive contract inputs, Q16.16 representability,
lane count, and the exercise-mode assertion before opening the serial port.
The 30-run command must return one identical raw price and cycle count before
its transport percentiles are retained.

### Run the CPU bump/revalue workflow

```powershell
python scripts\bump_revalue.py --target cpu --param-file baseline\cpp_fixed\params_monthly_1024x12.txt --exercise-mode multi --output-prefix .tmp\bump_revalue\cpu
```

## Repository Map

```text
src/                      SystemVerilog core and UART host path
src/math/                 Q16.16 multiply/divide/exp/log/sqrt/inverse-CDF support
src/steps/                Sobol, GBM, accumulator, regression, LSM decision
src/top/                  single-date and multi-date top-level orchestration
fpga/                     board wrappers
constraints/              board XDC constraints
scripts/                  build, validation, evidence, UART, and bump/revalue tools
baseline/cpp_fixed/       bit-exact fixed-point C++ mirror
tb/                       RTL testbenches
results/claims/           compact tracked claim evidence
docs/                     accuracy, build, performance, and validation notes
```

## Documentation Map

- [`PROJECT_REPORT.md`](PROJECT_REPORT.md): longer explanation of the original kernel and possible extensions.
- [`docs/accuracy.md`](docs/accuracy.md): financial accuracy methodology.
- [`docs/fpga-build.md`](docs/fpga-build.md): FPGA build and timing-closure workflow.
- [`docs/performance.md`](docs/performance.md): benchmark matrix and claim boundaries.
- [`docs/validation.md`](docs/validation.md): validation gates for the C++ and RTL implementations.
- [`results/claims/claim_evidence.md`](results/claims/claim_evidence.md): reproduced claim evidence and provenance.

## Project Boundary

This is continued development of my own original option-pricer project. The
implemented result is the accelerator, its cross-layer verification flow, and
the narrow bump/revalue workflow. Portfolio-scale orchestration and additional
payoffs remain possible future work rather than claims about the current artifact.

Do not market the current artifact as a production or ultra-low-latency trading
engine. Its defensible relevance is the engineering process and the measured
kernel: algorithm selection, numerical diagnosis, fixed-point C++/RTL parity,
parallel RTL, backpressure, timing closure, and precise latency boundaries.
