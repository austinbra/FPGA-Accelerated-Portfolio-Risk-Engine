# Roadmap

Last updated: 2026-05-03

## Project Boundary

The original FPGA QMC-LSM thesis kernel is complete.

Do not keep expanding the root README as if this repo still needs one more kernel milestone. The kernel now has:

- multi-date RTL,
- C++/RTL parity,
- accuracy tooling,
- regression health metrics,
- UART host flow,
- A7-100T and S7-50 100 MHz implementation results.

The next roadmap is the bigger product story. Continue from this repo, fork, or branch, but keep the boundary clear:

```text
Completed kernel:
    FPGA-accelerated QMC-LSM American option pricing core

Next product:
    Hardware-accelerated scenario pricing and Greeks engine
```

## Recommended Next Branch

```powershell
git switch -c portfolio-risk-engine
```

or fork the repository and keep this repo/tag as the thesis artifact.

## Phase B: Make It A System

Goal: one command prices a portfolio and outputs book value plus scenario PnL.

Build:

- portfolio CSV input,
- contract IDs,
- parameter loader,
- result aggregation,
- scenario sweep runner,
- CSV/Markdown report output,
- host-side batching over the existing UART kernel.

Why this is next:

- It makes the project useful beyond one option.
- It does not require risky RTL changes first.
- It uses the kernel as-is and exposes bottlenecks honestly.
- It clarifies whether path batching is actually needed.

Initial deliverable:

```powershell
python scripts\portfolio_price.py --input portfolio.csv --scenarios scenarios.csv --output-dir .tmp\portfolio_run
```

## Phase C: Make It Useful For Risk

Goal: portfolio-level Greeks and exposures.

Build:

- delta,
- gamma,
- vega,
- rho,
- theta,
- position-level exposures,
- portfolio-level aggregation,
- bump/revalue engine,
- scenario PnL report.

Why after portfolio mode:

- Greeks are naturally repeated pricing jobs.
- The host can batch bumped contracts before RTL changes.
- This gives an immediate desk-style story: price, risk, and scenario PnL.

## Phase D: Give QMC-LSM Its Real Niche

Goal: path-dependent and multi-asset products where QMC-LSM is more defensible than trees.

Build:

- Asian payoff,
- running-average state,
- basket payoff,
- correlation matrix input,
- multi-dimensional Sobol mapping,
- Brownian bridge only if convergence demands it.

Why after risk:

- This is where LSM/QMC becomes commercially interesting.
- Trees explode with path dependence and multiple assets.
- FPGA acceleration becomes easier to justify.

## Phase E: Scenario Intelligence

Goal: market regime selects or weights scenarios.

Build:

- realized vol estimator,
- correlation estimator,
- simple regime classifier,
- weighted scenario sets,
- backtest of scenario selection.

Why later:

- It needs portfolio/scenario infrastructure first.
- It should improve risk reports, not distract from the pricing kernel.

## Phase F: Event/Sentiment Only If Useful

Goal: use events only when they improve measurable forecasts.

Build:

- headline ingestion,
- dedup hashing,
- event classification,
- sentiment score,
- out-of-sample forecast test against vol/correlation/jump-risk targets.

Rule:

If event features do not improve prediction, remove them.

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

Use one of these for the next product:

- Hardware-Accelerated Scenario Pricing and Greeks Engine for Complex Derivatives
- FPGA-Accelerated QMC-LSM Portfolio Risk Engine for Path-Dependent Early-Exercise Derivatives

Avoid:

- FPGA sentiment-driven options pricer

That name undersells the kernel and overstates the least-proven future feature.

## First Product Tasks

1. Freeze a thesis tag or fork point.
2. Add a portfolio CSV schema.
3. Add host-side batch runner.
4. Add scenario sweep config.
5. Output position prices and portfolio total.
6. Add bump/revalue Greeks.
7. Profile repeated UART jobs.
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
