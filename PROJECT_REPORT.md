# Project Report: From FPGA Option Pricer To Portfolio Risk Engine

## Executive Summary

This fork starts from a completed FPGA-accelerated QMC-LSM American option pricing kernel and reframes it as the computational core of a portfolio risk engine.

The inherited kernel is already a useful artifact: it implements Sobol quasi-Monte Carlo path generation, fixed-point GBM, Longstaff-Schwartz early-exercise regression, UART host control, a bit-exact C++ mirror, financial accuracy studies, and 100 MHz routed builds for Arty A7-100T and Arty S7-50. The new work is to wrap that kernel in portfolio, scenario, and Greeks infrastructure so the acceleration applies to repeated valuation instead of a single demonstration option.

The central thesis of this fork is simple:

```text
The FPGA option pricer is most useful when the host needs to reprice many contracts many times.
```

That includes scenario sweeps, bump/revalue Greeks, path-dependent payoffs, and multi-asset products where binomial trees and PDE grids become less attractive.

## Fork Identity

Recommended identity:

- FPGA-Accelerated QMC-LSM Portfolio Risk Engine
- Hardware-Accelerated Scenario Pricing and Greeks Engine for Complex Derivatives

Avoid using "sentiment-driven options pricer" as the main identity. Event or sentiment features may become useful later, but only as inputs to scenario weighting, volatility, correlation, or jump-risk forecasts. They are not the foundation of the engineering story.

## Foundation: Completed Kernel

The inherited kernel proves five important things:

1. A Sobol/QMC LSM pricing algorithm can be implemented as synthesizable SystemVerilog with fixed-point math.
2. The C++ model and RTL can be made bit-exact by sharing the Sobol stream, LUTs, fixed-point transforms, and regression rules.
3. Multi-exercise LSM materially improves American PUT accuracy compared with the original single-exercise-date model.
4. The remaining pricing error is primarily estimator/model error, not hardware arithmetic error.
5. The hardware kernel fits and routes at 100 MHz on both the Arty A7-100T and the Spartan-7 based Arty S7-50.

## Final Kernel Results

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

## Why QMC-LSM Belongs In A Risk Engine

Longstaff-Schwartz Monte Carlo estimates continuation value by regressing future discounted cashflows against current state. It is useful when products have early exercise and simulation-friendly state evolution.

For a single vanilla American PUT, a binomial tree is a strong reference. For a portfolio risk engine, the work changes:

- Revalue every position under many market scenarios.
- Revalue positions again for delta, gamma, vega, rho, and theta bumps.
- Extend from vanilla payoffs to path-dependent and multi-asset products.
- Keep deterministic hardware and software parity so risk reports are reproducible.

This is where a hardware QMC-LSM kernel becomes persuasive. It can be reused as a repeated pricing primitive.

## Current Pricing Contract

The current kernel prices vanilla American-style options under geometric Brownian motion.

PUT behavior:

- exercise dates are every simulated step `1..M-1`,
- regression uses in-the-money paths only,
- basis is centered normalized moneyness `[1, x, x^2]`, where `x = S/K - 1`,
- singular or unstable regression falls back to mean continuation,
- beta coefficients above 4096.0 trigger fallback.

CALL behavior:

- no-dividend CALL early exercise is suppressed while `q=0`,
- the terminal fast path avoids regression bias for a product where early exercise is dominated.

Numerical contract:

- Q16.16 path values and cashflows,
- Sobol stream from `src/gen/direction.mem`,
- Sobol index 0 skipped,
- truncated `u_q16=0` guarded to one LSB before inverse-CDF,
- bit-exact C++ mirror under `baseline/cpp_fixed`.

## Product Architecture

The first product layer should be host-side. The existing UART packet and kernel validation should stay stable while the risk workflow is built around them.

```text
Portfolio CSV
    -> contract parser and validator
    -> parameter normalization
    -> pricing target selector: cpu | fpga | both
    -> C++ mirror or FPGA UART call
    -> position results
    -> portfolio aggregation
```

```text
Scenario CSV
    -> named market shocks
    -> repeated portfolio revaluation
    -> base value and scenario value
    -> scenario PnL
    -> Markdown/CSV report
```

```text
Greek request
    -> bump generator
    -> repeated contract or portfolio valuation
    -> finite-difference exposures
    -> position and portfolio Greeks
```

## Roadmap

### Phase 1: Portfolio System

Build:

- `examples/portfolio.csv`,
- contract IDs,
- `scripts/portfolio_price.py`,
- base portfolio value,
- CSV and Markdown outputs,
- `--target cpu`, then `--target fpga`, then `--target both`.

The first implementation should use the C++ mirror. That keeps product parsing separate from board availability.

### Phase 2: Scenario Sweeps

Build:

- `examples/scenarios.csv`,
- scenario naming,
- shock application,
- scenario PnL,
- position and portfolio reporting.

This is the first point where repeated pricing becomes visible to the user.

### Phase 3: Greeks

Build:

- delta,
- gamma,
- vega,
- rho,
- theta,
- bump sizing policy,
- position-level and portfolio-level exposure aggregation.

Greeks naturally multiply pricing jobs, which makes them a good place to measure whether host scheduling, UART throughput, or RTL changes matter.

### Phase 4: Payoffs Where LSM Matters More

Build:

- Asian payoff,
- running-average state,
- basket payoff,
- correlation matrix input,
- multidimensional Sobol mapping.

This is where the original FPGA option pricer becomes more than a vanilla demo.

### Phase 5: Scenario Intelligence

Build only after the scenario infrastructure exists:

- realized volatility estimator,
- correlation estimator,
- simple regime classifier,
- weighted scenario sets,
- backtest of scenario selection.

Event and sentiment features belong here only if they improve out-of-sample risk forecasts.

## What To Defer

Do not start with RTL changes unless product measurements justify them.

Deferred until measured:

- RTL path batching,
- multi-lane multi-date RTL,
- Brownian bridge,
- control variates,
- dividend-yield input,
- higher than 100 MHz fmax,
- smaller-board retargeting.

The final kernel uses only 16 RAMB36 on both A7-100T and S7-50, so BRAM pressure is not currently the reason to batch.

## Validation Policy

The product layer can grow only if the inherited kernel remains trustworthy.

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
.\scripts\run_vivado_build_arty_a7.ps1 -MultiExercise -ClockPeriodNs 10 -TimeoutSeconds 21600
.\scripts\run_vivado_build_arty_s7.ps1 -MultiExercise -ClockPeriodNs 10 -TimeoutSeconds 21600
```

## Documentation Split

- Root docs explain the fork and the inherited kernel foundation.
- `.user` tracks project memory, roadmap, validation, and product scope.
- `.ai` tracks AI/session handoff rules and working memory.

The old thesis kernel is not being discarded. It is the asset this fork builds around.
