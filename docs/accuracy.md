# Financial Accuracy

Hardware parity is not the same as financial accuracy, and product usefulness is a third question.

This continued project uses three separate gates:

1. **Parity:** does RTL equal the C++ FPGA-style mirror?
2. **Kernel accuracy:** how far is the FPGA method from a high-precision financial reference?
3. **Product accuracy:** do portfolio scenarios, Greeks, and future payoff extensions preserve traceable assumptions and acceptable error?

Parity is measured in Q16.16 LSBs. Accuracy is measured in basis points.

## Reference Models

`scripts/financial_reference.py` provides:

- `american_binomial_crr(...)`: dependency-free Cox-Ross-Rubinstein American reference, `q=0`.
- `european_black_scholes(...)`: sanity check, especially for no-dividend CALLs.
- `single_exercise_tree(...)`: isolates the old single-date modeling gap.

The default study compares reference convergence at `ref_steps/2` and `ref_steps` and warns when the reference itself is unstable.

## Error Columns

Important columns from `scripts/accuracy_study.py`:

- `american_tree`: American CRR reference price.
- `single_fpga_style`: C++ mirror of the single-date RTL path.
- `multi_fpga_style`: C++ mirror of the multi-date RTL path.
- `abs_bps_spot`: `abs(fpga_style - american_tree) / S0 * 10000`.
- `abs_bps_reference`: `abs(fpga_style - american_tree) / american_tree * 10000`.
- `single_total_bps_spot`: single-date error versus American tree.
- `multi_total_bps_spot`: multi-date error versus American tree.
- `multi_vs_single_improvement_bps_spot`: positive means multi-date improved.
- `multi_fixed_point_bps_spot`: multi-date fixed-point mirror minus double Sobol LSM, in bps of spot.

When `--attribution` is enabled:

- `single_exercise_model_error`: error from exercising only at `M-1`.
- `qmc_regression_error`: Sobol path estimator and regression error.
- `fixed_point_error`: fixed-point hardware-style error.
- `total_error`: final FPGA-style price minus American reference.

## Health Metrics

Enable with `--health-metrics`.

Case-level metrics:

- `min_itm_count`, `avg_itm_count`, `max_itm_count`
- `fallback_step_count`, `fallback_step_ratio`
- `worst_exercise_step`
- `max_abs_beta0`, `max_abs_beta1`, `max_abs_beta2`
- `min_cont_est`, `max_cont_est`
- `negative_cont_est_count`
- `early_exercise_count`, `early_exercise_rate`
- `avg_exercise_step`, `min_exercise_step`, `max_exercise_step`
- `early_exercise_policy`
- `regression_basis`
- `beta_abs_cap`

Per-step rows are written to:

```text
.tmp/accuracy_*/health/health_rows.csv
```

These metrics matter because LSM can fail silently: a final price can look plausible while beta coefficients or continuation estimates are nonsense.

## Final Kernel Contract

This is the shared C++/RTL financial contract:

- PUT exercise dates: every simulated step `1..M-1`.
- CALL exercise dates: suppressed while `q=0`.
- Basis: centered normalized moneyness `[1, x, x^2]`, where `x = S/K - 1`.
- Path values: Q16.16.
- Cashflows: Q16.16.
- Discounting: one-step `disc = exp(-r*dt)` using RTL-style fixed-point math.
- Regression samples: in-the-money PUT paths only.
- Continuation target: `disc * current_cashflow[path]`.
- Accumulation: wide 64-bit sums where the RTL contract requires it.
- Singular fallback: `beta0 = mean(Y)`, `beta1 = 0`, `beta2 = 0`.
- Beta cap fallback: if `max(abs(beta)) > 4096.0`, use mean continuation.
- Cashflow update: exercise if `immediate >= continuation_estimate`.
- Final price: average of one-step discounted cashflows.

## Product Accuracy Policy

Portfolio and scenario tooling must make assumptions visible.

For each product report, include when applicable:

- pricing target: `cpu`, `fpga`, or `both`,
- path count and step count,
- option type and exercise mode,
- scenario name and shock values,
- Greek bump sizes,
- base and bumped prices,
- CPU/FPGA Q16.16 delta when `--target both` is used,
- any unsupported feature fallback.

Do not hide estimator noise behind polished reports. Scenario and Greek outputs should be auditable back to individual pricing jobs.

## Standard Accuracy Runs

Smoke:

```powershell
python scripts\accuracy_study.py --preset smoke --build-cpu --attribution
```

Default:

```powershell
python scripts\accuracy_study.py --preset default --exercise-mode both --build-cpu --attribution --health-metrics --output-dir .tmp\accuracy_default_health
```

Stress:

```powershell
python scripts\accuracy_study.py --preset smoke --paths-list 1024,4096,8192 --steps-list 12,20 --moneyness-list 0.6,0.8,1.0,1.2,1.4 --sigma-list 0.05,0.2,0.4,0.6 --option-types put,call --exercise-mode both --build-cpu --attribution --health-metrics --output-dir .tmp\accuracy_stress_health
```

Large-N focused:

```powershell
python scripts\accuracy_study.py --preset smoke --paths-list 4096,8192,16384 --steps-list 12,20 --moneyness-list 0.8,1.0,1.2 --sigma-list 0.1,0.2,0.4 --T-list 1.0 --option-types put,call --exercise-mode both --build-cpu --attribution --health-metrics --output-dir .tmp\accuracy_largeN_health
```

## What We Learned

- The original single-date engine could be bit-exact and still financially weak.
- Multi-date LSM is the correct American-option improvement path for PUTs.
- Fixed-point error is controlled relative to the dominant Sobol/LSM estimator error at useful path counts.
- Low-path outliers are expected. They do not invalidate the hardware kernel; they are estimator/regression behavior.
- Non-dividend CALLs should not use noisy early-exercise regression while `q=0`.
- Regression health metrics are required before translating new financial behavior into RTL.

## What Accuracy Does Not Claim Yet

This project does not claim:

- production market-maker bps across all options,
- dividend yield support,
- path-dependent payoff accuracy,
- multi-asset correlation support,
- portfolio-level risk accuracy,
- variance reduction beyond the existing QMC/Sobol setup.

Those belong to the next product phases and need their own references.
