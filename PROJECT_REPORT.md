# Project Report: FPGA-Accelerated QMC-LSM American Option Pricer

## Executive Summary

This project built a complete FPGA pricing kernel for American-style option pricing using Longstaff-Schwartz Monte Carlo (LSM), Sobol quasi-Monte Carlo (QMC), fixed-point arithmetic, and UART-based host control. The final thesis build supports both the original single-exercise-date flow and a full multi-exercise-date LSM flow. The multi-date build closes timing at 100 MHz on both Arty A7-100T and Arty S7-50, matches the bit-exact C++ mirror in RTL simulation, and includes tools to measure financial accuracy against a high-precision American binomial reference.

The core result is not "Black-Scholes with noise." The project proves a deterministic hardware LSM pipeline that can be extended to products where trees become unattractive: path-dependent payoffs, basket options, correlated assets, scenario sweeps, and portfolio Greeks.

## What The Project Proves

The completed thesis kernel proves five things:

1. A Sobol/QMC LSM pricing algorithm can be implemented as synthesizable SystemVerilog with fixed-point math.
2. The C++ model and RTL can be made bit-exact by sharing the Sobol stream, LUTs, fixed-point transforms, and regression rules.
3. Multi-exercise LSM materially improves American PUT accuracy compared with the original single-exercise-date model.
4. The remaining pricing error is primarily financial estimator/model error, not hardware arithmetic error.
5. The hardware kernel fits and routes at 100 MHz on both the Arty A7-100T and the Spartan-7 based Arty S7-50.

## Completed Hardware Results

### Timing

| Target | Part | Build | Clock | WNS | TNS | Failing endpoints |
|--------|------|-------|-------|-----|-----|-------------------|
| Arty A7-100T | XC7A100T | `vivado_build/arty_a7_100_multi_10ns` | 100 MHz | +0.153 ns | 0.000 ns | 0 |
| Arty S7-50 | XC7S50 | `vivado_build/arty_s7_50_multi_10ns` | 100 MHz | +0.113 ns | 0.000 ns | 0 |

The slack values come from post-route Vivado `timing_post_route.rpt`. A positive WNS means the design meets the requested clock. The current practical maximum clock is just above 100 MHz, because the 10 ns builds have roughly 0.1 to 0.15 ns of setup margin. A real fmax sweep would use tighter constraints such as 9.8 ns, 9.6 ns, and 9.4 ns.

### Resource Use

| Target | LUTs | Registers | DSP48E1 | RAMB36 |
|--------|------|-----------|---------|--------|
| Arty A7-100T | 23,167 / 63,400 = 36.54% | 27,873 / 126,800 = 21.98% | 80 / 240 = 33.33% | 16 / 135 = 11.85% |
| Arty S7-50 | 23,154 / 32,600 = 71.02% | 27,873 / 65,200 = 42.75% | 80 / 120 = 66.67% | 16 / 75 = 21.33% |

BRAM is low because the multi-date architecture stores only one cashflow per path instead of the full `S[path][step]` grid. For `MAX_PATHS=16384`, one 32-bit cashflow per path is small enough to fit comfortably in BRAM. The design deliberately spends extra compute cycles regenerating deterministic Sobol/GBM path prefixes instead of storing all path states.

## Algorithm Background

### Why Longstaff-Schwartz?

American options can be exercised before maturity. A closed-form Black-Scholes price exists for European vanilla options, but not for general American options. Longstaff-Schwartz estimates the value of continuing the option by regressing future discounted cashflows against basis functions of the current state.

At each exercise date:

1. Simulate many paths.
2. Identify in-the-money paths.
3. Regress discounted future cashflow against current state.
4. Exercise if immediate payoff is greater than estimated continuation value.
5. Continue backward until time zero.

For this project, the multi-date PUT basis is:

```text
x = S / K - 1
continuation(S) = beta0 + beta1*x + beta2*x^2
```

The centered basis is better conditioned than raw `[1, S/K, (S/K)^2]` because most vanilla option paths cluster around `S/K ~= 1`.

### Why Sobol QMC?

Monte Carlo needs random samples. Sobol QMC instead uses a deterministic low-discrepancy sequence. The goal is to cover the unit interval more evenly than pseudo-random samples, which often improves convergence for smooth integrals.

Sobol generation in this project:

- uses direction numbers from `src/gen/direction.mem`,
- applies Gray-code XOR recurrence,
- starts at index 1 instead of index 0,
- truncates `sobol_out[31:16]` to Q16.16 for inverse-CDF input,
- maps a truncated zero to one LSB.

Sobol index 0 is skipped because it is a boundary point. The one-LSB guard is important because the inverse normal transform contains `ln(u)`. If `u=0`, `ln(0)` is undefined and would drive the pipeline toward extreme values, division hazards, and invalid regression data. The guard keeps the transform in the open interval while preserving the quantized hardware stream.

### Why Inverse CDF?

GBM path generation needs normally distributed shocks `z`. Sobol gives uniform samples `u` in `[0,1)`. The inverse CDF maps:

```text
u -> z = Phi^-1(u)
```

The RTL uses:

- fold around 0.5 with a sign flag,
- LUT-based natural log,
- fixed-point square root,
- Zelen-Severo rational approximation,
- event-alignment FIFOs to keep sign and data synchronized.

### Why GBM?

The stock process is geometric Brownian motion:

```text
S_next = S * exp((r - 0.5*sigma^2)*dt + sigma*sqrt(dt)*z)
```

The RTL precomputes:

- `dt`,
- `drift_const`,
- `vol_sqrt_dt`,
- one-step discount `disc`,
- total discount when needed.

The GBM module then streams:

```text
z -> vol_sqrt_dt*z -> add drift -> exp LUT -> S*exp_result
```

## Hardware Architecture

### Single-Date Mode

The original engine exercises only at step `M-1`. It exists as the default compatibility path and remains bit-exact with the single-date C++ mirror.

Single-date mode is useful for:

- original thesis continuity,
- simple regression bring-up,
- proving two-pass streaming path replay,
- guarding existing UART behavior.

### Multi-Date Mode

The final thesis feature is `MULTI_EXERCISE=1`.

Multi-date mode:

- supports `NUM_LANES=1` in v1,
- prices PUTs with exercise at every simulated step `1..M-1`,
- suppresses no-dividend CALL early exercise while `q=0`,
- stores terminal and updated cashflows in BRAM,
- regenerates deterministic paths per backward exercise date,
- trains regression on in-the-money paths only,
- updates each path cashflow in place,
- final-averages discounted cashflows.

The core memory decision is:

```text
Do not store S[path][step].
Store cashflow[path].
Regenerate S_t deterministically when needed.
```

This trades cycles for memory. That is the right trade for the target boards: BRAM use is only 16 RAMB36 on both A7-100T and S7-50.

## UART System

The UART path makes the FPGA usable from a host script.

Input packet fields:

```text
paths
steps
S0
K
r
sigma
T
option_type
```

All numeric financial fields are Q16.16. `option_type=0` is CALL and `option_type=1` is PUT.

Output packet fields:

```text
marker
price_q16
core_cycles_low
core_cycles_high
status_flags
```

The host converts `core_cycles` into hardware compute time:

```text
hardware_seconds = core_cycles / fpga_fclk_hz
```

This is separate from UART round-trip time. UART includes serial transfer, Python overhead, OS scheduling, and parsing. The pricing core timer is the right number for comparing the hardware kernel against CPU compute.

## C++ Mirror And Parity

The C++ baseline under `baseline/cpp_fixed/` has two purposes:

1. **Hardware parity oracle:** `--fpga-style --exercise-mode single|multi`.
2. **Higher-level financial comparison:** `--full-lsm`.

The parity oracle mirrors:

- RTL Sobol stream from `direction.mem`,
- Sobol index skip-zero policy,
- Q16.16 truncation,
- inverse-CDF approximation,
- exp/log/sqrt LUT behavior,
- fixed-point GBM,
- centered LSM basis,
- regression fallback,
- final averaging.

This separation matters. A high-precision financial model tells you whether the method is accurate. A bit-exact mirror tells you whether hardware equals the intended method.

## Numerical Diagnosis

The project started with final price mismatches. Final-price-only debugging was not enough, so the diagnosis flow became stage-by-stage.

`scripts/diagnose_numerical.py` runs C++ and xsim with trace tags and compares raw Q16.16 values:

```text
[INIT] constants
[PATH] Sobol u, inverse-CDF z, GBM S
[ACC-IN] regression samples
[ACC-SUM] accumulated sums
[BETA] regression coefficients
[LSM] exercise decisions
[PV] discounted cashflows
[FINAL] average price
```

This identifies the first material divergence instead of guessing from the final option price. It was used to separate:

- Sobol stream differences,
- inverse-CDF approximation differences,
- fixed-point LUT behavior,
- path generation alignment,
- regression accumulation,
- beta solve and fallback,
- final averaging truncation.

## Accuracy Measurement

### References

Financial accuracy is measured by `scripts/accuracy_study.py` using `scripts/financial_reference.py`.

References:

- American Cox-Ross-Rubinstein binomial tree, default high step count.
- European Black-Scholes for no-dividend CALL sanity checks.
- Single-exercise tree to isolate the old modeling gap.

### Error Units

Errors are reported as:

```text
absolute_error = model_price - reference_price
bps_of_spot = absolute_error / S0 * 10000
bps_of_reference = absolute_error / reference_price * 10000
```

For market-making style reasoning, bps are more useful than percentage error because small absolute option-price differences can still matter economically.

### Attribution

The study splits total error into:

- **single-exercise model error:** only allowing exercise at `M-1`,
- **QMC/regression error:** path estimator and regression behavior,
- **fixed-point error:** bit-exact hardware-style result minus double Sobol LSM,
- **total error:** hardware-style result minus American reference.

This showed the important conclusion: after C++/RTL parity was fixed, the dominant issue was not Verilog arithmetic. The largest improvement came from full multi-date LSM.

### Regression Health

Health metrics prevent blind trust in regression:

- ITM path count per exercise date,
- fallback count and ratio,
- max beta magnitude,
- min/max continuation estimate,
- negative continuation count,
- early exercise count and rate,
- worst exercise step,
- average exercise boundary.

These metrics exposed unstable CALL exercise behavior under `q=0`, which led to the no-dividend CALL fast path. They also justified centered moneyness and beta-cap fallback for PUT regression stability.

## Key Problems Solved

### Boundary Sobol Values

Problem: Sobol can generate boundary values, and RTL truncation can create `u_q16=0`. Inverse-CDF cannot accept zero because `ln(0)` is undefined.

Fix:

```text
if sobol_out[31:16] == 0:
    u_q16 = 1
else:
    u_q16 = sobol_out[31:16]
```

This keeps the stream deterministic, quantized, and inside the valid open interval.

### C++ Was Not A Valid Parity Oracle

Problem: The original C++ and RTL did not consume the same Sobol stream or fixed-point math.

Fix: C++ now reads `src/gen/direction.mem`, mirrors Gray-code Sobol generation, truncates exactly like RTL, uses the same guard, and mirrors fixed-point math stage by stage.

### Single-Date LSM Was The Wrong Financial Target

Problem: Exercise only at `M-1` is not a full American model. It can match RTL while still being financially weak.

Fix: Add C++ and RTL multi-exercise LSM. PUTs now exercise at every simulated step `1..M-1`.

### Regression Instability

Problem: Low ITM counts or poorly conditioned basis functions can generate extreme beta coefficients.

Fix:

- regress only ITM PUT paths,
- use centered basis `[1, S/K - 1, (S/K - 1)^2]`,
- fallback to mean continuation for singular regression,
- cap beta magnitude at 4096.0 Q16.16.

### Spartan-7 Resource Pressure

Problem: Earlier builds overused LUTs because too many divider IP instances were instantiated.

Fix: Share divider resources where appropriate and avoid full path storage. The final S7-50 build uses 71.02% LUTs and 21.33% BRAM.

### 100 MHz Timing

Problem: The old `fxMul` latency setting delayed an already-computed combinational multiply result. It did not split the critical path.

Fix:

```text
old: S, exp -> multiply -> round/shift -> first register
new: S, exp -> raw product register -> round/shift register -> output
```

After that, the final averaging divider became the new critical path. Splitting divider quotient update from `result_price` writeback closed the remaining 100 MHz timing.

## Performance Measurement

### Core Cycles

The RTL exposes a cycle counter for the pricing core. Example measured parity cases:

| Mode | Paths | Steps | Option | Core cycles | 100 MHz core time |
|------|-------|-------|--------|-------------|-------------------|
| single-date | 64 | 12 | PUT | 75,603 | 0.75603 ms |
| multi-date | 64 | 12 | PUT | 461,245 | 4.61245 ms |
| multi-date | 256 | 12 | PUT | 1,843,158 | 18.43158 ms |
| multi-date | 1024 | 12 | PUT | 7,370,906 | 73.70906 ms |
| multi-date | 64 | 12 | CALL | 37,726 | 0.37726 ms |

PUT multi-date is slower because it performs backward induction. CALL is fast because no-dividend early exercise is suppressed.

### CPU Baseline Time

The C++ baseline prints wall-clock time:

```text
Elapsed Time: ... seconds
```

This number is machine-dependent and includes software data structure and mirror overhead. Use it for local comparison, not as an immutable hardware claim. The FPGA metric is `core_cycles / fclk`.

### Virtual Hardware Time

`scripts/run_virtual_a7_benchmark.ps1` runs xsim and scales the DUT cycle counter by a chosen clock:

```powershell
.\scripts\run_virtual_a7_benchmark.ps1 -ParamFile baseline\cpp_fixed\params_example.txt -FclkHz 100000000
```

This is the right no-board measurement for the core. It is not a physical USB-UART measurement.

## How To Reproduce

### Syntax And Parity

```powershell
python -m py_compile scripts\validate_numerical.py scripts\diagnose_numerical.py scripts\accuracy_study.py scripts\financial_reference.py scripts\vivado_build_runner.py
.\scripts\run_xelab_smoke.ps1 -XvlogTimeoutSeconds 600 -XelabTimeoutSeconds 600 -NoCleanup
python scripts\validate_numerical.py --exercise-mode single --paths 64 --steps 12 --option-type 1 --build-cpu
python scripts\validate_numerical.py --exercise-mode multi --paths 64 --steps 12 --option-type 1 --build-cpu
python scripts\validate_numerical.py --exercise-mode multi --paths 256 --steps 12 --option-type 1
python scripts\diagnose_numerical.py --paths 64 --steps 12 --option-type 1 --exercise-mode multi
```

### Vivado Implementation

```powershell
.\scripts\run_vivado_build_arty_a7.ps1 -MultiExercise -ClockPeriodNs 10 -TimeoutSeconds 21600
.\scripts\run_vivado_build_arty_s7.ps1 -MultiExercise -ClockPeriodNs 10 -TimeoutSeconds 21600
```

### Financial Accuracy

```powershell
python scripts\accuracy_study.py --preset smoke --build-cpu --attribution
python scripts\accuracy_study.py --preset default --exercise-mode both --build-cpu --attribution --health-metrics --output-dir .tmp\accuracy_default_health
```

### Hardware UART

```powershell
.\scripts\program_arty_a7.ps1 -Bit vivado_build\arty_a7_100_multi_10ns\arty_a7_qmc_multi.bit
python src\uart_host.py --mode benchmark --target both --param-file baseline\cpp_fixed\params_example.txt --port COM4 --fpga-fclk-hz 100000000 --build-cpu
```

## Lessons Learned

1. Bit-exact parity is a different problem from financial accuracy.
2. A final price mismatch is too coarse; stage-by-stage raw Q16.16 traces find the first real divergence.
3. Q16.16 is workable, but regression inputs must be normalized.
4. Sobol boundary handling is not optional when the next stage computes `ln(u)`.
5. Divider count dominates LUT pressure faster than BRAM in this design.
6. Full path storage is unnecessary when deterministic path regeneration is possible.
7. Increasing a latency parameter does not fix timing unless registers split the actual critical path.
8. No-dividend CALL early exercise should be suppressed; otherwise LSM regression can invent exercise bias.
9. Health metrics are essential before implementing complex numerical algorithms in RTL.
10. The best next use case is not another vanilla option; it is portfolio/scenario/risk infrastructure and path-dependent payoffs.

## Where This Project Ends

This repository is complete as a hardware-accelerated QMC-LSM American option pricing kernel.

Completed scope:

- Sobol QMC and inverse-CDF pipeline,
- fixed-point GBM path generation,
- single-date and multi-date LSM,
- C++/RTL bit-exact mirror,
- financial accuracy study,
- UART control and benchmarking,
- 100 MHz A7-100T and S7-50 bitstreams,
- documentation and validation scripts.

The next project begins when the kernel becomes a portfolio risk system:

- portfolio CSV input/output,
- contract IDs and batch aggregation,
- scenario PnL,
- delta/gamma/vega/rho/theta,
- Asian payoff,
- basket payoff,
- correlation input,
- scenario weighting and market regime logic.

That roadmap lives in `.user/FUTURE_PROJECT.md` and is intentionally not presented as completed root-scope thesis work.
