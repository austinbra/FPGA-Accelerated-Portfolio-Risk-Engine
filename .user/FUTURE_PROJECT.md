# Product Scope

This file describes the bigger project this fork is now pursuing.

The completed FPGA QMC-LSM American option pricing kernel is the foundation. The fork should turn that kernel into a portfolio scenario pricing and Greeks engine.

## Recommended Identity

Use:

- Hardware-Accelerated Scenario Pricing and Greeks Engine for Complex Derivatives
- FPGA-Accelerated QMC-LSM Portfolio Risk Engine for Path-Dependent Early-Exercise Derivatives
- FPGA QMC-LSM Portfolio Risk Engine

Avoid:

- FPGA sentiment-driven options pricer

The sentiment framing is too narrow and too speculative. The stronger story is hardware acceleration for repeated pricing, risk, scenarios, and complex payoffs.

## Final Architecture Target

```text
Portfolio CSV
    -> contract parameter loader
    -> scenario generator
    -> Greek bump generator
    -> FPGA QMC-LSM pricing kernel
    -> price / Greeks / scenario PnL
    -> portfolio aggregation
    -> risk report
```

Later:

```text
Market data
    -> vol/correlation estimator
    -> regime model
    -> scenario weights
    -> portfolio scenario pricing
```

## Phase A: Kernel Foundation

Already done:

- multi-exercise RTL,
- C++/RTL parity,
- accuracy versus CRR,
- regression health metrics,
- A7-100T and S7-50 100 MHz implementation.

Preserve:

- validation gates,
- Q16.16/Sobol contract,
- no-dividend CALL terminal fast path while `q=0`,
- UART packet compatibility until product work deliberately versions it.

## Phase B: Make It A System

Build:

- batch portfolio mode,
- contract IDs,
- result aggregation,
- CSV input/output,
- scenario sweeps.

Deliverable:

- one command prices a portfolio and outputs book value plus scenario PnL.

Suggested files:

```text
scripts/portfolio_price.py
scripts/scenario_sweep.py
examples/portfolio.csv
examples/scenarios.csv
.user/PORTFOLIO_PRODUCT.md
```

Start with the C++ mirror, then add `--target fpga` and `--target both`.

## Phase C: Make It Useful For Risk

Build:

- delta,
- gamma,
- vega,
- rho,
- theta,
- position-level exposures,
- portfolio-level exposures.

Deliverable:

- portfolio risk report with base price, bumped prices, Greeks, and scenario PnL.

## Phase D: Give QMC-LSM A Real Reason To Exist

Build:

- Asian payoff,
- basket payoff,
- correlation input.

Deliverable:

- path-dependent and multi-asset early-exercise pricing where trees are less attractive.

Why this matters:

- A vanilla American PUT can be handled by a tree.
- Asian/basket/early-exercise combinations are where simulation and hardware acceleration become more persuasive.

## Phase E: Scenario Intelligence

Build:

- vol estimator,
- correlation estimator,
- simple regime classifier,
- scenario weighting.

Deliverable:

- market regime selects or weights scenario sets.

## Phase F: Event/Sentiment Only If Useful

Build:

- headline/event ingestion,
- dedup hashing,
- event classification,
- sentiment score,
- out-of-sample forecast test.

Deliverable:

- event features improve vol, correlation, or jump-risk scenario prediction.

Rule:

- if sentiment does not improve prediction, remove it from the product story.

## Variance Reduction Recommendation

Do not implement variance reduction just because it sounds advanced.

Add it when one of these is true:

- portfolio/scenario latency is blocked by path count,
- `N=2048` or `N=4096` must behave like `N=8192+`,
- high-volatility stress rows require lower estimator noise,
- Greeks multiply pricing jobs enough that per-price path count must drop.

Order when needed:

1. Control variate using host-supplied European Black-Scholes price.
2. Confirm antithetic handling in the active multi-date/product path.
3. Brownian bridge Sobol ordering.

## Batching Recommendation

Original motivation was BRAM overflow. The final kernel uses only 16 RAMB36 on S7-50 and A7-100T, so BRAM does not justify RTL path batching today.

Batching may still be valuable later, but for different reasons:

- portfolio scheduling,
- UART throughput,
- repeated scenario jobs,
- larger `M`,
- smaller FPGA target,
- multi-asset state storage.

Start with host-side portfolio batching before changing RTL.

## First Concrete Next Step

Create a portfolio CSV runner that calls the existing C++ mirror and, later, the FPGA UART path using the same parameter format.

Target command:

```powershell
python scripts\portfolio_price.py --portfolio examples\portfolio.csv --output-dir .tmp\portfolio_smoke --target cpu
```

Then add:

```powershell
--target fpga
--target both
--scenarios examples\scenarios.csv
--greeks delta,gamma,vega,rho,theta
```

Keep the existing kernel validation gates green throughout.
