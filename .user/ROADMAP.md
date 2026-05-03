# Roadmap

Last updated: 2026-05-03

## Project Boundary

This fork is no longer just the completed FPGA QMC-LSM thesis kernel. The completed kernel is the acceleration foundation.

Current project:

```text
Hardware-accelerated scenario pricing and Greeks engine
```

Foundation:

```text
FPGA-accelerated QMC-LSM American option pricing core
```

The product layer should grow around the kernel while preserving the kernel validation gates.

## Phase 1: Portfolio Pricing

Goal: one command prices a portfolio and outputs position prices plus portfolio value.

Build:

- `examples/portfolio.csv`,
- portfolio CSV schema,
- contract IDs,
- parameter loader,
- result aggregation,
- Markdown and CSV outputs,
- target selector: `cpu`, `fpga`, `both`.

Initial deliverable:

```powershell
python scripts\portfolio_price.py --portfolio examples\portfolio.csv --output-dir .tmp\portfolio_smoke --target cpu
```

Why this is first:

- It makes the original pricer useful beyond one option.
- It can start with the C++ mirror and does not require a board.
- It exposes real scheduling and throughput needs before RTL changes.

## Phase 2: Scenario Sweeps

Goal: produce base value, scenario value, and scenario PnL.

Build:

- `examples/scenarios.csv`,
- named shocks,
- spot/vol/rate/time perturbations,
- scenario-level result tables,
- portfolio-level PnL report.

Initial deliverable:

```powershell
python scripts\scenario_sweep.py --portfolio examples\portfolio.csv --scenarios examples\scenarios.csv --output-dir .tmp\scenario_smoke --target cpu
```

## Phase 3: Greeks

Goal: portfolio-level Greeks and exposures.

Build:

- delta,
- gamma,
- vega,
- rho,
- theta,
- bump/revalue engine,
- position-level exposures,
- portfolio-level aggregation.

Why after portfolio mode:

- Greeks are naturally repeated pricing jobs.
- The host can batch bumped contracts before RTL changes.
- This gives the project an immediate risk workflow: price, scenario, exposure.

## Phase 4: Path-Dependent Payoffs

Goal: use QMC-LSM where it has a stronger niche than vanilla options.

Build:

- Asian payoff,
- running-average state,
- payoff selector in C++ mirror,
- validation reference for Asian cases,
- RTL extension only after the C++ product contract is stable.

## Phase 5: Multi-Asset Products

Goal: basket pricing and correlation-aware scenarios.

Build:

- basket payoff,
- correlation matrix input,
- multi-dimensional Sobol mapping,
- product-level validation cases.

Brownian bridge belongs here only if convergence studies show it earns its complexity.

## Phase 6: Scenario Intelligence

Goal: market regime selects or weights scenarios.

Build:

- realized vol estimator,
- correlation estimator,
- simple regime classifier,
- weighted scenario sets,
- backtest of scenario selection.

Event/sentiment inputs are optional and must prove they improve volatility, correlation, jump-risk, or scenario forecast quality.

## Deferred Kernel Work

Do not prioritize these until the product phase exposes a real need:

- RTL path batching,
- multi-lane multi-date RTL,
- variance reduction,
- Brownian bridge,
- control variates,
- dividend-yield input,
- higher than 100 MHz fmax.

When to revisit:

- portfolio/scenario latency is too high,
- `M=20+` or larger path counts create cycle pressure,
- a smaller FPGA target becomes mandatory,
- BRAM rises materially above the current 16 RAMB36 design,
- accuracy studies show estimator error dominates at unacceptable path counts.

## Naming

Use one of these for the product:

- Hardware-Accelerated Scenario Pricing and Greeks Engine for Complex Derivatives
- FPGA-Accelerated QMC-LSM Portfolio Risk Engine for Path-Dependent Early-Exercise Derivatives
- FPGA QMC-LSM Portfolio Risk Engine

Avoid:

- FPGA sentiment-driven options pricer

That name undersells the kernel and overstates the least-proven future feature.

## First Product Tasks

1. Add portfolio CSV schema and examples.
2. Add host-side batch runner.
3. Output position prices and portfolio total.
4. Add scenario sweep config.
5. Add scenario PnL.
6. Add bump/revalue Greeks.
7. Profile repeated CPU and UART jobs.
8. Decide whether batching belongs in host scheduling or RTL.

## Keep These Gates Forever

Before accepting product changes:

```powershell
python scripts\validate_numerical.py --exercise-mode single --paths 64 --steps 12 --option-type 1 --build-cpu
python scripts\validate_numerical.py --exercise-mode multi --paths 64 --steps 12 --option-type 1 --build-cpu
python scripts\diagnose_numerical.py --paths 64 --steps 12 --option-type 1 --exercise-mode multi
git diff --check
```

For RTL changes, also rerun the appropriate Vivado implementation flow.
