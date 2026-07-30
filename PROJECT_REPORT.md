# Project Report: Continued Development of an FPGA Option Pricer

## Executive Summary

This repository is the continued development of my original 2025
FPGA-accelerated QMC-LSM option pricer. The original implementation established
an end-to-end Sobol, fixed-point GBM, Longstaff-Schwartz, RTL, and UART path.
Subsequent work corrected its financial and numerical weaknesses, added a
bit-exact C++17 model and differential validation, and replaced path
regeneration with a banked stored-path architecture.

The current artifact is a measured hardware/software co-design prototype, not
a production trading engine. Its narrow application layer is deterministic
single-contract bump/revalue: use the same Sobol paths for a base valuation and
small spot and volatility perturbations, then calculate finite-difference
delta, gamma, and vega.

The project thesis is deliberately limited:

```text
The FPGA pricer is useful as a deterministic repeated-revaluation primitive,
and as evidence that a numerically sensitive algorithm can be carried from a
C++ reference through fixed-point RTL, FPGA implementation, and measured
latency.
```

For one low-dimensional vanilla American option, a tree is usually the simpler
engineering choice. This project does not claim otherwise.

## Project Identity

The defensible identity is **FPGA QMC-LSM Early-Exercise Pricing Accelerator**.
The engineering contribution is the C++/RTL numerical contract, parallel
architecture, verification flow, routed implementation, and explicit timing
boundaries. The bump/revalue runner gives that kernel a small, concrete risk
workflow without claiming a portfolio platform that has not been built.

Avoid using "sentiment-driven options pricer" as the main identity. Event or sentiment features may become useful later, but only as inputs to scenario weighting, volatility, correlation, or jump-risk forecasts. They are not the foundation of the engineering story.

## Foundation: Completed Kernel

The continued project demonstrates five important things:

1. A Sobol/QMC LSM pricing algorithm can be implemented as synthesizable SystemVerilog with fixed-point math.
2. The C++ model and RTL can be made bit-exact by sharing the Sobol stream, LUTs, fixed-point transforms, and regression rules.
3. Multi-exercise LSM materially improves American PUT accuracy compared with the original single-exercise-date model.
4. The remaining pricing error is primarily estimator/model error, not hardware arithmetic error.
5. The hardware kernel has routed 100 MHz evidence on both boards; the A7-100T
   result was regenerated after hardening, while the S7-50 result is retained
   from the June 24, 2026 pre-hardening implementation.

## v1 Foundation Kernel Results

These are the preserved regeneration-based v1 single-lane builds. The active
deliverable is the Stored-Path v2 Multi-Lane Engine documented in the next
section.

### Timing

| Target | Part | Build | Clock | WNS | TNS | Failing endpoints |
|--------|------|-------|-------|-----|-----|-------------------|
| Arty A7-100T | XC7A100T | `vivado_build/arty_a7_100_multi_10ns` | 100 MHz | +0.153 ns | 0.000 ns | 0 |
| Arty S7-50 | XC7S50 | `vivado_build/arty_s7_50_multi_10ns` | 100 MHz | +0.113 ns | 0.000 ns | 0 |

The slack values come from post-route Vivado `timing_post_route.rpt`. A positive WNS means the design meets the requested clock. The current practical maximum clock is only proven slightly above 100 MHz; a real fmax claim would need tighter constraints such as 9.8 ns, 9.6 ns, and 9.4 ns.

### Resource Use

| Target | LUTs | Registers | DSP48E1 | RAMB36 |
|--------|------|-----------|---------|--------|
| Arty A7-100T | 23,167 / 63,400 = 36.54% | 27,873 / 126,800 = 21.98% | 80 / 240 = 33.33% | 16 / 135 = 11.85% |
| Arty S7-50 | 23,154 / 32,600 = 71.02% | 27,873 / 65,200 = 42.75% | 80 / 120 = 66.67% | 16 / 75 = 21.33% |

BRAM is low because the multi-date architecture stores one cashflow per path instead of the full `S[path][step]` grid. The design spends extra cycles regenerating deterministic Sobol/GBM path prefixes instead of storing all path states.

### Parity Snapshot

| Mode | Paths | Steps | Option | C++ Q16.16 | RTL Q16.16 | Delta | Core cycles |
|------|-------|-------|--------|------------|------------|-------|-------------|
| single-date | 64 | 12 | PUT | 263,688 | 263,688 | 0 LSB | 75,603 |
| multi-date | 64 | 12 | PUT | 373,676 | 373,676 | 0 LSB | 461,245 |
| multi-date | 256 | 12 | PUT | 426,642 | 426,642 | 0 LSB | 1,843,158 |
| multi-date | 1024 | 12 | PUT | 428,757 | 428,757 | 0 LSB | 7,370,906 |
| multi-date | 64 | 12 | CALL | 482,546 | 482,546 | 0 LSB | 37,726 |

At 100 MHz, the 1024-path, 12-step multi-date PUT case takes 73.70906 ms of FPGA core time.

## Stored-Path v2 Multi-Lane Engine

The active engine (`src/top/top_option_pricer_multi_stored.sv`) replaces the v1
regeneration controller. It stores every simulated spot once in lane-banked BRAM,
replicates the path and feature pipelines across `NUM_LANES`, and schedules
independent paths step-major. It preserves the exact N=1024/M=12 raw price
`428,757` (`0x00068AD5`) at every lane count.

### Cycle Scaling (1,024 paths x 12 steps)

| Lanes | Core cycles | Time at 100 MHz | Speedup vs 7,370,906-cycle v1 |
|------:|------------:|----------------:|------------------------------:|
| 1 | 720,474 | 7.205 ms | 10.23x |
| 2 | 411,626 | 4.116 ms | 17.91x |
| 4 | 236,362 | 2.364 ms | 31.18x |
| 8 | 121,290 | 1.213 ms | 60.77x |

### Routed Board Results

| Target / config | Clock | WNS | Utilization | Status |
|-----------------|-------|-----|-------------|--------|
| Arty A7-100T, 4 lanes | 100 MHz | +0.139 ns | 45,955 LUT / 180 DSP / 66 RAMB36 | Post-hardening route, headline deliverable |
| Arty S7-50, 1 lane | 100 MHz | +0.310 ns | 23,399 LUT / 84 DSP / 65 RAMB36 | June 24 pre-hardening route |
| Arty S7-50, 2 lanes | 95.24 MHz | +0.083 ns | 30,606 LUT / 116 DSP / 65 RAMB36 | June 24 pre-hardening route at relaxed clock (4.322 ms); fails 100 MHz by -0.180 ns |

Eight lanes is simulation-only (91,092 LUTs, 143.68% of the A7-100T) and does not
fit any evaluated board.

The S7 routes predate the valuation-time intrinsic floor. Their timing and
utilization remain historical measurements, but the bitstreams must be
regenerated before they can represent the current arithmetic contract.

The immediately preceding A7 route measured +0.144 ns WNS with 45,875 LUTs,
46,911 registers, 180 DSPs, and 66 block-RAM tiles. Those values remain a
historical measurement; the July 29, 2026 post-hardening route above is the
source for the current published claim.

### Headline Workload and Timing Boundary

The headline latency workload is the four-lane, 1,024-path by 4-step case. The
post-hardening RTL simulation completed in 72,394 cycles, or 0.72394 ms at
100 MHz. The separate 1,024-path by 12-step workload completed in 236,362
cycles, or 2.36362 ms. Neither number corrects the other; they describe
different workloads.

**RTL core latency** begins when the core accepts a complete job and ends when
`result_valid` is asserted. It includes initialization, Sobol/GBM path
generation, LSM regression and exercise decisions, and final averaging. It
excludes UART transfer, USB latency, Python execution, and host scheduling.
The regenerated four-lane implementation closes at +0.139 ns WNS with
45,955 LUTs, 46,905 registers, 180 DSPs, and 66 block-RAM tiles.

### Optimized C++ Comparison

The current tracked claim report uses a 15-repetition, single-thread MinGW
Release (`-O3 -DNDEBUG`) run of the exact 1,024x12 PUT on a 13th Gen Intel Core
i9-13905H:

| C++ timing boundary | Current 15-run mean | A7 four-lane factor (CPU / 2.36362 ms) |
|---------------------|--------------------:|-----------------------------------------:|
| Hot kernel (paths/direction persistent) | 1.870528 ms | 0.791x |
| Pricing core plus path allocation | 1.841793 ms | 0.779x |
| End-to-end plus direction-file load | 2.076906 ms | 0.879x |

An earlier 30-repetition run produced the following historical means. They are
preserved because they remain valid measurements, but they are not the values
generated by the current 15-repetition claim command:

| C++ timing boundary | Historical 30-run mean | A7 four-lane factor (CPU / 2.36362 ms) |
|---------------------|-----------------------:|-----------------------------------------:|
| Hot kernel (paths/direction persistent) | 1.285 ms | 0.54x |
| Pricing core plus path allocation | 1.336 ms | 0.57x |
| End-to-end plus direction-file load | 1.860 ms | 0.79x |

Both runs lead to the same conclusion: the routed four-lane A7 is slower than
the optimized laptop CPU at every named 1,024x12 boundary. The current 15-run
evidence puts the CPU advantage at 1.14x to 1.28x; the historical 30-run data
put it at 1.27x to 1.84x. The 31.18x figure is retained as a historical
comparison with this project's regeneration-based v1 RTL, not as a general
FPGA speedup or the headline claim. Full methodology, the complete path/date
matrix, and claim boundaries are in [`docs/performance.md`](docs/performance.md).

## Why Retain QMC-LSM

Longstaff-Schwartz Monte Carlo estimates continuation value by regressing future discounted cashflows against current state. It is useful when products have early exercise and simulation-friendly state evolution.

For a single vanilla American PUT, a binomial tree is a strong reference. The
purpose of retaining this kernel is narrower:

- Revalue the same contract under controlled spot and volatility bumps.
- Reuse common Sobol paths so price differences are deterministic.
- Keep exact hardware/software parity so numerical changes are attributable.
- Preserve a path toward products with path-dependent or multi-asset state,
  where simulation is more naturally motivated.

The implemented bump/revalue workflow demonstrates repeated use without
claiming that the present vanilla kernel beats a tree or a CPU implementation.

## Current Pricing Contract

The current kernel prices vanilla contracts under geometric Brownian motion
with exercise allowed only on the simulated date grid. It is therefore a
discrete-time QMC-LSM approximation to American exercise, not a continuous
exercise solver.

PUT behavior:

- exercise dates are every simulated step `1..M-1`,
- regression uses in-the-money paths only,
- basis is centered normalized moneyness `[1, x, x^2]`, where `x = S/K - 1`,
- singular or unstable regression falls back to mean continuation,
- beta coefficients above 4096.0 trigger fallback,
- after averaging, the returned price is floored at valuation-time intrinsic
  value.

CALL behavior:

- no-dividend CALL early exercise is suppressed while `q=0`,
- the terminal fast path avoids regression bias for a product where early
  exercise is dominated,
- the same valuation-time intrinsic-value floor is applied to the result.

Numerical contract:

- Q16.16 path values and cashflows,
- Sobol stream from `src/gen/direction.mem`,
- Sobol index 0 skipped,
- truncated `u_q16=0` guarded to one LSB before inverse-CDF,
- bit-exact C++ mirror under `baseline/cpp_fixed`.

## Implemented Application Layer

The smallest useful host layer submits five deterministic jobs for one
contract: base, spot up, spot down, volatility up, and volatility down. It
reuses the same Sobol stream for every job so the finite differences use common
random numbers.

```text
contract plus bump policy
    -> base and four bumped jobs
    -> target: C++, FPGA, or exact-parity comparison
    -> price, delta, gamma, and vega
    -> CSV and JSON evidence with core and transport timing
```

The runner keeps one serial connection open for an FPGA batch. It reports the
hardware core counter separately from host-observed transport time. Under the
combined target it requires exact raw Q16.16 C++/RTL parity before calculating
Greeks.

## Near-Term Scope

This hardening pass is limited to:

1. enforce the hardware workload and Q16.16 input contract at the host;
2. align CPU and programmed-bitstream exercise modes;
3. decode the actual four-word UART response and explicit RTL errors;
4. apply the valuation-time intrinsic-value floor in C++ and RTL;
5. reproduce C++/RTL parity, cycles, post-route timing, and utilization in one
   compact tracked claim report; and
6. provide the deterministic single-contract bump/revalue runner.

It intentionally excludes portfolio ingestion, PCIe or AXI transport, RTL
request queues, Asian and basket payoffs, broad API work, and ASIC
implementation.

## What To Defer

Do not start with RTL changes unless product measurements justify them.

Stored-path, banked, multi-lane multi-date RTL is already implemented (see the
Stored-Path v2 Multi-Lane Engine section above). The remaining items are deferred
until product measurements justify them:

- RTL path batching beyond the 1,024-path by 50-date stored capacity,
- Brownian bridge,
- control variates,
- dividend-yield input,
- higher than 100 MHz fmax,
- further smaller-board retargeting.

The v1 foundation kernel uses only 16 RAMB36 on both A7-100T and S7-50. The v2
stored-path engine trades that for 65-66 RAMB36 to keep every path resident, which
is what removes the v1 regeneration penalty.

## Validation Policy

The application layer can grow only while the pricing kernel remains
trustworthy.

Keep these gates green:

```powershell
python scripts\validate_numerical.py --exercise-mode single --paths 64 --steps 12 --option-type 1 --build-cpu
python scripts\validate_numerical.py --exercise-mode multi --paths 64 --steps 12 --option-type 1 --build-cpu
python scripts\validate_numerical.py --exercise-mode multi --paths 256 --steps 12 --option-type 1
python scripts\diagnose_numerical.py --paths 64 --steps 12 --option-type 1 --exercise-mode multi
git diff --check
```

For RTL changes, rerun the relevant Vivado implementation flow:

```powershell
.\scripts\run_vivado_build_arty_a7.ps1 -MultiExercise -NumLanes 4 -ClockPeriodNs 10 -TimeoutSeconds 21600
.\scripts\run_vivado_build_arty_s7.ps1 -MultiExercise -NumLanes 1 -ClockPeriodNs 10 -TimeoutSeconds 21600
```

## Public Documentation

- Root docs explain the continued project and its measured kernel foundation.
- `docs/` contains the public accuracy, build, performance, and validation notes.
- `results/claims/` contains compact, reproducible evidence for published claims.

The original kernel is the starting point of this same project. Its weaknesses,
corrections, and architectural evolution are preserved here.
