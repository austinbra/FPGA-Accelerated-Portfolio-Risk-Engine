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

For roadmap features, C++ should favor readable double-precision references
that use the CPU's floating-point arithmetic naturally. The existing
fixed-point mirror remains the raw-price oracle for implemented RTL, but a new
financial reference does not need to reproduce FPGA precision or serve as an
optimized CPU performance competitor.

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

## Roadmap Accuracy Gates

### Regression range

Using 64-bit accumulators does not guarantee a stable solve if each sufficient
statistic is later narrowed or saturated independently into Q16.16. That can
change the relative scale of the normal-equation matrix and right-hand side.
Before increasing path count or basis size, compare normalized coordinates,
common block scaling, block-floating representation, and a wider fixed-point
solver. Report saturation, conditioning, fallback, and coefficient magnitude.

### QMC uncertainty

A single deterministic Sobol stream is reproducible but does not provide an
ordinary sampling error estimate. Add independent digitally scrambled Sobol
replicas and report variation across replicas. Evaluate Brownian-bridge or PCA
dimension ordering before assuming that more paths alone improve convergence.

### Exercise-policy bias

Fitting and valuing an exercise policy on the same paths can bias an LSM result.
Test held-out paths or cross-fitting and report policy-fit and valuation samples
separately. Stability must be checked across path counts, exercise grids,
bases, scrambles, and fallback behavior.

### New-product references

- European vanilla modes require a high-precision analytic reference.
- European arithmetic Asians require a converged PDE or double-precision
  MC/QMC reference; geometric Asians provide a useful analytic control.
- A simple Bermudan arithmetic Asian should be checked against a two-state PDE
  and a readable double-precision LSM implementation using spot and average.
- Each added stochastic state, such as volatility, rates, or another asset,
  needs its own convergence surface and a justified sparse regression basis.

## Scenario and Greek Accuracy Policy

A future risk report should retain enough information to reproduce every
number:

- contract and scenario IDs;
- original parameters and exact shock definition;
- base and bumped raw prices;
- bump sizes and finite-difference formula;
- path count, date count, option type, and exercise mode;
- common-random-number seed/index policy;
- implementation (`fpga`, `fixed_mirror`, `float_reference`, or paired);
- FPGA/fixed-mirror raw delta when exact parity is intended;
- FPGA/high-precision financial error when model accuracy is intended;
- regression health and fallback status;
- unsupported-feature or fallback markers.

Common random numbers reduce variance in a price difference, but they do not
eliminate bias, make a poor bump size correct, or avoid recomputing a complete
job. The hardware roadmap should replay normal increments and share compatible
path work across strikes, payoffs, and shocks. Greeks should be checked over
multiple bump sizes and, where valid, against analytic, pathwise, adjoint, or
other independent derivatives. Gamma requires particular care because noise
and exercise-boundary changes are amplified by a second difference.

Portfolio totals can hide individual failures. Aggregate only after every job
has a success status and traceable diagnostics.

## Lessons

- Single-date and multi-date models can be bit-exact yet have very different
  American-option accuracy.
- No-dividend CALLs should avoid noisy early-exercise regression.
- Fixed-point error is often smaller than QMC/regression error, but this must be
  measured over the intended surface.
- Wide accumulation does not prevent error caused by a narrow, independently
  saturated regression boundary.
- Deterministic Sobol reproducibility is not an uncertainty estimate.
- Common random numbers do not by themselves reuse computation.
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
- randomized-QMC error estimates or cross-fit LSM valuation;
- computational reuse across bumped requests;
- queued mixed-product or multi-context execution;
- variance reduction beyond the current deterministic Sobol/common-random-
  number setup;

Each new payoff or risk feature needs an independent reference and a clearly
stated supported domain before it belongs in the hardware kernel.
