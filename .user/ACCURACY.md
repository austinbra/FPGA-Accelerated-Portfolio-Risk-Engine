# QMC-LSM-to-FPGA - Financial Accuracy

This page is separate from C++/RTL bit parity. Parity answers whether the
software hardware proxy equals RTL. Accuracy answers whether the bit-exact
method is close enough to a high-precision financial reference.

## Quick runs

```powershell
# Small bps report
python scripts/accuracy_study.py --preset smoke --build-cpu --attribution

# Larger grid
python scripts/accuracy_study.py --preset default --build-cpu --attribution

# Path-count sweep for estimator vs fixed-point attribution
python scripts/accuracy_study.py --preset smoke --paths-list 64,256,1024,4096 --build-cpu --attribution --output-dir .tmp/accuracy_path_sweep

# Compare current single-date RTL proxy against the multi-date C++/RTL mirror
python scripts/accuracy_study.py --preset smoke --paths-list 256,1024,4096 --exercise-mode both --build-cpu --attribution --output-dir .tmp/accuracy_multi

# Default accuracy gate with regression health metrics
python scripts/accuracy_study.py --preset default --exercise-mode both --build-cpu --attribution --health-metrics --output-dir .tmp/accuracy_default_health

# Stress accuracy gate
python scripts/accuracy_study.py --preset smoke --paths-list 1024,4096,8192 --steps-list 12,20 --moneyness-list 0.6,0.8,1.0,1.2,1.4 --sigma-list 0.05,0.2,0.4,0.6 --option-types put,call --exercise-mode both --build-cpu --attribution --health-metrics --output-dir .tmp/accuracy_stress_health

# Stress gate after no-dividend CALL exercise suppression
python scripts/accuracy_study.py --preset smoke --paths-list 1024,4096,8192 --steps-list 12,20 --moneyness-list 0.6,0.8,1.0,1.2,1.4 --sigma-list 0.05,0.2,0.4,0.6 --option-types put,call --exercise-mode both --attribution --health-metrics --output-dir .tmp/accuracy_stress_policy_health

# Final default gate after centered/capped multi-date contract
python scripts/accuracy_study.py --preset default --exercise-mode both --build-cpu --attribution --health-metrics --output-dir .tmp/accuracy_default_centered_cap_health
```

Outputs are written to `.tmp/accuracy/`:

- `accuracy_results.csv`
- `accuracy_summary.md`
- `health/health_rows.csv` when `--health-metrics` is enabled

## How to read the report

- `american_tree`: high-precision in-repo Cox-Ross-Rubinstein American reference.
- `fpga_style`: selected C++ FPGA-style mirror. In `--exercise-mode both`, this is the multi-date price.
- `single_fpga_style`: current RTL-shaped single-exercise-date C++ mirror.
- `multi_fpga_style`: C++ multi-exercise-date fixed-point mirror. It stores Q16.16 paths/cashflows and mirrors the `MULTI_EXERCISE=1` RTL path: centered PUT basis, RTL regression, beta cap, and no-dividend CALL fast path.
- `abs_bps_spot`: `abs(fpga_style - american_tree) / S0 * 10000`.
- `abs_bps_reference`: `abs(fpga_style - american_tree) / american_tree * 10000`.
- `ref_convergence_bps_spot`: reference stability check comparing `ref_steps/2` vs `ref_steps`.
- `multi_vs_single_improvement_bps_spot`: reduction in absolute bps error when switching from single-date to multi-date. Positive is better.

When `--attribution` is enabled:

- `single_exercise_model_error`: effect of allowing early exercise only at `M-1`.
- `qmc_regression_error`: remaining double-precision Sobol/LSM estimator error.
- `fixed_point_error`: difference between bit-exact FPGA-style and double Sobol/LSM.
- `total_error`: FPGA-style price minus American tree reference.
- `float_multi_lsm_sobol`: double-precision multi-date LSM on the same Sobol stream.
- `multi_fixed_point_bps_spot`: multi-date fixed-point-style price minus double multi-date Sobol LSM, in bps of spot.
- `float_terminal_sobol`: same Sobol stream in double precision, terminal payoff only.
- `terminal_sobol_error_vs_bs`: Sobol path-generation sanity check against Black-Scholes European price.
- `lsm_minus_terminal_sobol`: incremental effect of the single-exercise LSM policy versus terminal-only pricing.

For non-dividend CALLs, `american_tree`, `single_exercise_tree`, and
`european_black_scholes` should be effectively the same. If those CALL cases
show large `qmc_regression_error` while `terminal_sobol_error_vs_bs` is small,
the issue is regression/exercise-policy bias, not the fixed-point RTL mirror.

## Health metrics

`--health-metrics` adds regression diagnostics for multi-date cases. These are
the early warning system before RTL multi-date work:

- `min_itm_count`, `avg_itm_count`, `max_itm_count`: number of paths used in each per-date regression.
- `fallback_step_count`, `fallback_step_ratio`: how often the regression used the mean-continuation fallback instead of a solved quadratic fit.
- `worst_exercise_step`: exercise step with the highest early-exercise count.
- `max_abs_beta0`, `max_abs_beta1`, `max_abs_beta2`: largest absolute regression coefficients seen across exercise dates.
- `min_cont_est`, `max_cont_est`: continuation-estimate range.
- `negative_cont_est_count`: count of negative continuation estimates.
- `early_exercise_count`, `early_exercise_rate`: how often the LSM policy exercised before maturity.
- `avg_exercise_step`, `min_exercise_step`, `max_exercise_step`: timing of early exercise decisions.
- `early_exercise_policy`: `lsm` for PUTs, `suppressed_non_dividend_call` for CALLs while `q=0`.
- `regression_basis`: current multi-date basis contract.
- `beta_abs_cap`: absolute beta threshold that triggers mean-continuation fallback.

The per-step CSV at `health/health_rows.csv` includes one row per case and
exercise date:

```text
case_id, option, paths, steps, K, S0, moneyness, sigma, T, r,
exercise_step, itm_count, fallback_used,
beta0, beta1, beta2,
min_cont_est, max_cont_est,
early_exercise_count, avg_exercise_boundary
```

Implementation note: the health metrics are collected from the double-precision
Sobol multi-date path, not from RTL. Fixed-point impact is still measured by
`multi_fixed_point_bps_spot`.

## Multi-date C++/RTL contract

This is the algorithm contract shared by `fixed_baseline --exercise-mode multi`
and RTL `MULTI_EXERCISE=1`:

- PUT exercise dates: every simulated step `1..M-1`.
- CALL exercise dates: suppressed while `q=0`; the model has no dividend-yield input, and non-dividend American CALL early exercise is financially dominated.
- Basis: centered normalized moneyness `[1, x, x^2]`, where `x = S/K - 1`.
- Path format: Q16.16 `S[t]`.
- Cashflow format: Q16.16.
- Discounting: one-step `disc = exp(-r * dt)` using the RTL-style discount path.
- Regression input: PUT ITM paths only.
- Continuation target: `disc * current_cashflow[i]`.
- Accumulation width: 64-bit sums.
- Regression matrix: 64-bit accumulated sums saturated into Q16.16 matrix entries; the RTL Gaussian-elimination solver normalizes pivot rows internally.
- Singular/unstable fallback: `beta0 = mean(Y)`, `beta1 = beta2 = 0`.
- Beta stability guard: if `max(abs(beta)) > 4096`, use the mean-continuation fallback.
- Cashflow update: exercise if `immediate >= continuation_estimate`.
- Final price: average of `disc * cashflow[i]`.
- Fixed-point comparison: `multi_fpga_style - float_multi_lsm_sobol`.

## Current limitations

- Dividend yield is fixed at `q=0`; RTL has no dividend-yield input yet.
- Default RTL is single-exercise-date. Multi-date RTL exists behind `MULTI_EXERCISE=1`, supports `NUM_LANES=1` in v1, and still needs large-N/timing/resource signoff.
- The first study reports bps; it does not enforce a pass/fail threshold.

## Historical pre-RTL health gate

Commands run:

```powershell
python scripts/accuracy_study.py --preset default --exercise-mode both --build-cpu --attribution --output-dir .tmp/accuracy_default_both
python scripts/accuracy_study.py --preset default --exercise-mode both --build-cpu --attribution --health-metrics --output-dir .tmp/accuracy_default_health
python scripts/accuracy_study.py --preset smoke --paths-list 1024,4096,8192 --steps-list 12,20 --moneyness-list 0.6,0.8,1.0,1.2,1.4 --sigma-list 0.05,0.2,0.4,0.6 --option-types put,call --exercise-mode both --build-cpu --attribution --health-metrics --output-dir .tmp/accuracy_stress_health
python scripts/accuracy_study.py --preset smoke --paths-list 4096,8192,16384 --steps-list 12,20 --moneyness-list 0.8,1.0,1.2 --sigma-list 0.1,0.2,0.4 --T-list 1.0 --option-types put,call --exercise-mode both --build-cpu --attribution --health-metrics --output-dir .tmp/accuracy_largeN_health
python scripts/accuracy_study.py --preset smoke --paths-list 1024,4096,8192 --steps-list 12,20 --moneyness-list 0.6,0.8,1.0,1.2,1.4 --sigma-list 0.05,0.2,0.4,0.6 --option-types put,call --exercise-mode both --attribution --health-metrics --output-dir .tmp/accuracy_stress_policy_health
python scripts/accuracy_study.py --preset smoke --paths-list 1024,4096,8192 --steps-list 12,20 --moneyness-list 0.6,0.8,1.0,1.2,1.4 --sigma-list 0.05,0.2,0.4,0.6 --option-types put,call --exercise-mode both --attribution --health-metrics --output-dir .tmp/accuracy_stress_centered_cap_health
python scripts/accuracy_study.py --preset smoke --paths-list 4096,8192,16384 --steps-list 12,20 --moneyness-list 0.8,1.0,1.2 --sigma-list 0.1,0.2,0.4 --T-list 1.0 --option-types put,call --exercise-mode both --attribution --health-metrics --output-dir .tmp/accuracy_largeN_centered_cap_health
python scripts/accuracy_study.py --preset default --exercise-mode both --build-cpu --attribution --health-metrics --output-dir .tmp/accuracy_default_centered_cap_health
```

These results motivated the RTL multi-date v1 implementation. Because the C++
multi-date mirror now uses the RTL regression solver for bit parity, rerun the
default/stress accuracy grids before using these numbers as final production
bps evidence.

Results:

- Final default grid after the centered/capped contract: multi-date improves average PUT error, but the low-N fixed-point gate is still not clean enough for unconditional RTL. PUT average error improved from `171.98` to `84.20` bps at `N=64`, from `84.27` to `61.01` bps at `N=256`, and from `67.11` to `40.02` bps at `N=1024`. PUT fixed-point error was `9.70`, `5.34`, and `3.04` bps average at `N=64`, `256`, and `1024`; max PUT fixed-point error was `81.29`, `48.04`, and `20.43` bps.
- Final default CALL sanity: no-dividend CALL early exercise is suppressed, so CALL early-exercise rate is `0`, fallback ratio is `0`, and beta max is `0`. CALL average fixed-point error is `1.18`, `1.34`, and `1.39` bps at `N=64`, `256`, and `1024`. Large remaining low-N CALL total errors are terminal Sobol sampling error in high-volatility/long-maturity cases, not regression exercise behavior.
- Broad stress grid: PUT scaling is strong. Average PUT multi-date error dropped from `50.10` bps at `N=1024` to `20.57` bps at `N=4096` and `14.55` bps at `N=8192`. PUT fixed-point error dropped from `2.98` to `1.39` to `0.82` bps.
- Before the CALL policy fix, broad stress CALLs were not clean. CALL average multi-date error got worse than single-date at `N=4096` and `N=8192` in high-volatility/deep-moneyness cases, and CALL fixed-point error reached `21` to `39` bps average in that broad stress set.
- After suppressing no-dividend CALL early exercise, broad stress CALLs are materially healthier. Average CALL multi-date error is `51.18`, `10.41`, and `4.38` bps at `N=1024`, `4096`, and `8192`; average CALL fixed-point error is `1.39`, `1.46`, and `2.01` bps. CALL early-exercise rate is exactly `0`.
- After adding centered moneyness plus beta-cap fallback, broad stress PUT average error is essentially unchanged but regression health is bounded. Average PUT multi-date error is `50.01`, `20.16`, and `14.65` bps at `N=1024`, `4096`, and `8192`; average PUT fixed-point error is `2.77`, `1.50`, and `0.75` bps. Max PUT beta is bounded under the `4096` cap.
- Final focused large-N grid is healthier. Average PUT multi-date error is `14.13`, `10.74`, and `10.93` bps at `N=4096`, `8192`, and `16384`. Average PUT fixed-point error is `1.51`, `0.54`, and `0.78` bps. Average CALL multi-date error is `10.29`, `4.46`, and `2.26` bps with zero early exercise.
- Regression health: average fallback ratios stayed below the `25%` threshold after adding cap fallback. Large total errors that remain are mostly high-volatility/deep-moneyness QMC/model error, not runaway beta coefficients.

Gate result: the C++ contract was strong enough to build RTL multi-date v1, and
trace parity now passes through `N=64/M=12`. Production signoff is still not the
same thing as parity: the strict low-N PUT fixed-point thresholds remain
documented, while `N >= 8192` has sub-1 bp average PUT fixed-point error in the
large-N/focused stress runs and sane CALL behavior. Next decision: harden the
new RTL path for large-N cycle/resource/timing evidence, then decide whether
variance reduction is worth adding for lower path-count or high-stress bps.
