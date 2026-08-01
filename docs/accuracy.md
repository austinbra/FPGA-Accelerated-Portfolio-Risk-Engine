# Financial Accuracy and Numerical Validation

Hardware parity, financial accuracy, and product usefulness are different
questions. This project keeps them separate:

1. **Arithmetic parity:** does RTL produce the same raw Q16.16 value as the C++
   FPGA-style mirror?
2. **Model accuracy:** how far is that shared method from an independent
   high-precision financial reference?
3. **Risk-product accuracy:** do scenarios, finite-difference Greeks, and future
   portfolio aggregates preserve assumptions and control estimator noise?

A bit-exact wrong model is still wrong. A financially reasonable model can also
be implemented incorrectly in hardware. Both gates are required.

## Relationship to the Divider Correction

The July 2026 RTL divider defect invalidated hardware results that depended on
the wrong vendor output slice and one-cycle stub. It did not alter the C++
financial model or the independent CRR/Black-Scholes references.

After the fix, the generated-divider RTL again matches the C++ mirror exactly:

| Workload | C++ raw | RTL raw | Delta |
|---|---:|---:|---:|
| 1,024 paths x 4 steps, multi PUT | 391,343 | 391,343 | 0 LSB |
| 1,024 paths x 12 steps, multi PUT | 428,757 | 428,757 | 0 LSB |

That restores arithmetic parity. The accuracy study below remains the separate
financial gate.

## Reference Models

`scripts/financial_reference.py` provides:

- `american_binomial_crr(...)`: dependency-free Cox-Ross-Rubinstein American
  reference with `q=0`;
- `european_black_scholes(...)`: European sanity check, especially for
  no-dividend CALLs;
- `single_exercise_tree(...)`: isolates the modeling gap from permitting only
  one early-exercise date.

The study evaluates the reference with `ref_steps/2` and `ref_steps`. A warning
is raised when the reference itself has not converged enough for the requested
tolerance.

## Shared C++/RTL Contract

The active multi-date contract is:

- PUT exercise dates: simulated steps `1..M-1`;
- CALL exercise: terminal-only while dividend yield is fixed at zero;
- Sobol sequence begins at index 1;
- path values and cashflows: signed Q16.16;
- basis: `[1, x, x^2]`, where `x = S/K - 1`;
- regression samples: in-the-money PUT paths;
- continuation target: one-step discounted current cashflow;
- wide sums: 64-bit where specified by the RTL contract;
- singular fallback: mean continuation (`beta1 = beta2 = 0`);
- beta-cap fallback: mean continuation if any absolute beta exceeds 4096.0;
- exercise rule: exercise when immediate payoff is at least continuation;
- final boundary: maximum of discounted estimate and intrinsic value at `S0`.

Because exercise exists on a finite grid, the precise description is a
discrete-date QMC-LSM approximation to American exercise, not continuous-time
American exercise.

## Error Units

Parity is measured in Q16.16 least-significant bits.

Financial error is commonly reported as basis points of spot:

```text
error_bp_spot = (fpga_style_price - reference_price) / S0 * 10,000
```

Absolute basis points of reference are also useful when comparing across very
different option prices:

```text
abs_error_bp_reference = abs(error) / reference_price * 10,000
```

The generated claim evidence records `-11.8765` bp of spot for the single
canonical 1,024 x 4 multi-date PUT comparison. That is one data point, not an
accuracy guarantee over a product surface.

## Attribution Columns

With `--attribution`, `scripts/accuracy_study.py` separates:

- `single_exercise_model_error`: loss from the historical one-exercise-date
  approximation;
- `qmc_regression_error`: Sobol sampling and LSM regression error;
- `fixed_point_error`: fixed-point mirror minus double-precision Sobol LSM;
- `total_error`: final FPGA-style price minus the independent reference.

Useful table columns include:

- `american_tree`;
- `single_fpga_style`;
- `multi_fpga_style`;
- `single_total_bps_spot`;
- `multi_total_bps_spot`;
- `multi_vs_single_improvement_bps_spot`;
- `multi_fixed_point_bps_spot`.

This decomposition prevents fixed-point RTL from being blamed for an error
that is actually caused by too few paths, a coarse exercise grid, or unstable
regression.

## Regression Health Metrics

Enable `--health-metrics` to capture:

- minimum, average, and maximum in-the-money path count;
- fallback count and fallback ratio;
- worst exercise step;
- maximum absolute beta coefficients;
- minimum and maximum continuation estimate;
- negative continuation-estimate count;
- early-exercise count and rate;
- average/minimum/maximum exercise step;
- active early-exercise policy, basis, and beta cap.

Per-step rows are written to:

```text
.tmp/accuracy_*/health/health_rows.csv
```

These diagnostics matter because LSM can produce a plausible final price while
individual regressions are underdetermined or unstable.

## Standard Studies

### Smoke

```powershell
python scripts\accuracy_study.py --preset smoke --build-cpu --attribution
```

### Default with health metrics

```powershell
python scripts\accuracy_study.py `
  --preset default `
  --exercise-mode both `
  --build-cpu `
  --attribution `
  --health-metrics `
  --output-dir .tmp\accuracy_default_health
```

### Stress grid

```powershell
python scripts\accuracy_study.py `
  --preset smoke `
  --paths-list 1024,4096,8192 `
  --steps-list 12,20 `
  --moneyness-list 0.6,0.8,1.0,1.2,1.4 `
  --sigma-list 0.05,0.2,0.4,0.6 `
  --option-types put,call `
  --exercise-mode both `
  --build-cpu `
  --attribution `
  --health-metrics `
  --output-dir .tmp\accuracy_stress_health
```

The board core supports at most 1,024 paths and 50 steps. Larger-path C++
studies are still valuable for understanding convergence, but they are not
current FPGA requests.

## Scenario and Greek Accuracy Policy

A future risk report should retain enough information to reproduce every
number:

- contract and scenario IDs;
- original parameters and exact shock definition;
- base and bumped raw prices;
- bump sizes and finite-difference formula;
- path count, date count, option type, and exercise mode;
- common-random-number seed/index policy;
- target (`cpu`, `fpga`, or `both`);
- CPU/FPGA raw delta for every `both` job;
- regression health and fallback status;
- unsupported-feature or fallback markers.

Common random numbers reduce variance in a price difference, but they do not
eliminate bias or make a poor bump size correct. Greeks should be checked over
multiple bump sizes and, for European cases, against analytic derivatives.

Portfolio totals can hide individual failures. Aggregate only after every job
has a success status and traceable diagnostics.

## Lessons

- Single-date and multi-date models can be bit-exact yet have very different
  American-option accuracy.
- No-dividend CALLs should avoid noisy early-exercise regression.
- Fixed-point error is often smaller than QMC/regression error, but this must be
  measured over the intended surface.
- Low-path outliers are estimator behavior, not automatically an RTL defect.
- Vendor-IP arithmetic contracts need focused tests before full-model claims.
- Scenario and Greek outputs need job-level audit trails, not only polished
  aggregate tables.

## Current Non-Claims

This project does not yet claim:

- production-wide basis-point accuracy;
- dividend-yield support;
- path-dependent or multi-asset accuracy;
- calibrated volatility surfaces;
- portfolio-level risk accuracy;
- variance reduction beyond the current deterministic Sobol/common-random-
  number setup;

Each new payoff or risk feature needs an independent reference and a clearly
stated supported domain before it belongs in the hardware kernel.
