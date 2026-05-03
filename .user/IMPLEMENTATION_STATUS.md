# Implementation Status

Last updated: 2026-05-03

## Current State

This fork has a complete FPGA QMC-LSM option pricing kernel and a planned portfolio-risk product layer.

Implemented foundation:

- bit-exact C++/RTL parity for the default single-date engine,
- compile-time multi-exercise RTL mode,
- C++ multi-date mirror,
- stage-by-stage diagnosis tooling,
- financial accuracy studies versus an in-repo American CRR reference,
- regression health metrics,
- UART host flow,
- 100 MHz routed bitstreams for Arty A7-100T and Arty S7-50.

Not implemented yet:

- portfolio CSV input/output,
- scenario sweep runner,
- Greeks bump/revalue engine,
- path-dependent payoff mode,
- basket payoff and correlation input,
- risk report generation.

Root docs should be read as the fork's product-facing artifact. `.user` and `.ai` guide the next phase.

## Kernel Foundation Result

| Target | Part | Clock | Timing | Utilization summary | Bitstream |
|--------|------|-------|--------|---------------------|-----------|
| Arty A7-100T | XC7A100T | 100 MHz / 10 ns | WNS `+0.153 ns`, TNS `0`, 0 failing endpoints | 23,167 LUTs, 27,873 regs, 80 DSP, 16 RAMB36 | `vivado_build/arty_a7_100_multi_10ns/arty_a7_qmc_multi.bit` |
| Arty S7-50 | XC7S50 | 100 MHz / 10 ns | WNS `+0.113 ns`, TNS `0`, 0 failing endpoints | 23,154 LUTs, 27,873 regs, 80 DSP, 16 RAMB36 | `vivado_build/arty_s7_50_multi_10ns/arty_s7_qmc_multi.bit` |

Resource percentages:

| Target | LUT | Register | DSP | BRAM |
|--------|-----|----------|-----|------|
| A7-100T | 36.54% | 21.98% | 33.33% | 11.85% |
| S7-50 | 71.02% | 42.75% | 66.67% | 21.33% |

The actual post-route timing margin implies the design is a clean 100 MHz design, not a proven 110+ MHz design. The next tighter-clock characterization would sweep 9.8 ns, 9.6 ns, and 9.4 ns.

## Price Parity Snapshot

| Case | C++ Q16.16 | RTL Q16.16 | Delta | Core cycles |
|------|------------|------------|-------|-------------|
| Single-date PUT, N=64, M=12 | 263,688 | 263,688 | 0 LSB | 75,603 |
| Multi-date PUT, N=64, M=12 | 373,676 | 373,676 | 0 LSB | 461,245 |
| Multi-date PUT, N=256, M=12 | 426,642 | 426,642 | 0 LSB | 1,843,158 |
| Multi-date PUT, N=1024, M=12 | 428,757 | 428,757 | 0 LSB | 7,370,906 |
| Multi-date CALL, N=64, M=12 | 482,546 | 482,546 | 0 LSB | 37,726 |

At 100 MHz, the core-only multi-date PUT times above are 4.612 ms, 18.432 ms, and 73.709 ms for N=64, 256, and 1024 respectively.

## What Is Implemented

| Area | Status |
|------|--------|
| Sobol QMC generator from `direction.mem` | Complete |
| Sobol skip-index-0 and one-LSB open-interval guard | Complete |
| Inverse normal CDF using fixed-point log/sqrt/Zelen-Severo | Complete |
| GBM path generation | Complete |
| Q16.16 fixed-point math | Complete |
| True pipelined `fxMul` with `FP_MUL_LATENCY=2` | Complete |
| Regression accumulator and Gaussian solve | Complete |
| Mean fallback and beta-cap fallback | Complete |
| Single-date LSM | Complete |
| Multi-date LSM RTL v1 | Complete |
| No-dividend CALL terminal fast path | Complete |
| UART parameter/result packet | Complete |
| C++ FPGA-style mirror | Complete |
| Diagnosis script | Complete |
| Accuracy study script | Complete |
| Vivado A7/S7 build flows | Complete |
| Portfolio CSV runner | Planned |
| Scenario sweep runner | Planned |
| Greeks bump/revalue engine | Planned |
| Asian payoff | Planned |
| Basket/correlation support | Planned |

## Design Decisions To Preserve

- Treat the existing kernel as the stable foundation.
- Keep `.user/FUTURE_PROJECT.md` and `.user/ROADMAP.md` as the product scope source of truth.
- Default single-date behavior remains available for historical parity, but the product foundation is multi-date.
- Multi-date v1 is intentionally `NUM_LANES=1`.
- Do not add path batching just because it was once an original idea. Current BRAM use is low; batching should be driven by portfolio scheduling, larger `M`, larger path counts, UART throughput, or a smaller board target.
- Do not add variance reduction by default. Add it only if it reduces path count enough to matter for portfolio/scenario latency.
- Do not call the product "sentiment-driven options pricer." The stronger identity is a hardware-accelerated scenario pricing and Greeks engine for complex derivatives.

## Main Problems Solved

### C++/RTL Parity

The original software baseline was not a valid oracle because it did not mirror the exact Sobol stream and fixed-point math. The final C++ mirror reads the same direction file, uses the same Sobol index policy, mirrors Q16.16 truncation, and compares raw trace stages against RTL.

### Sobol Boundary Values

`u=0` is invalid for inverse-CDF because the transform requires `ln(u)`. The production stream starts at index 1 and remaps truncated `u_q16=0` to one LSB. This prevents zero-boundary failures while keeping the stream deterministic and quantized.

### Single-Date Modeling Error

The original engine only exercised at `M-1`. Accuracy studies showed this was the wrong financial bottleneck. Multi-date backward induction directly improved American PUT behavior.

### Regression Instability

The multi-date PUT solver now uses centered moneyness and beta-cap fallback. No-dividend CALL early exercise is suppressed while `q=0`.

### Spartan-7 Fit And 100 MHz Timing

The S7-50 version fits after divider/resource discipline and cashflow-only storage. The final 100 MHz timing fix was a real multiplier pipeline plus a registered final-divider writeback.

## Validation Commands

Use these as the kernel sanity set:

```powershell
python -m py_compile scripts\validate_numerical.py scripts\diagnose_numerical.py scripts\accuracy_study.py scripts\financial_reference.py scripts\vivado_build_runner.py
.\scripts\run_xelab_smoke.ps1 -XvlogTimeoutSeconds 600 -XelabTimeoutSeconds 600 -NoCleanup
python scripts\validate_numerical.py --exercise-mode single --paths 64 --steps 12 --option-type 1 --build-cpu
python scripts\validate_numerical.py --exercise-mode multi --paths 64 --steps 12 --option-type 1 --build-cpu
python scripts\validate_numerical.py --exercise-mode multi --paths 256 --steps 12 --option-type 1
python scripts\diagnose_numerical.py --paths 64 --steps 12 --option-type 1 --exercise-mode multi
.\scripts\run_vivado_build_arty_a7.ps1 -MultiExercise -ClockPeriodNs 10 -TimeoutSeconds 21600
.\scripts\run_vivado_build_arty_s7.ps1 -MultiExercise -ClockPeriodNs 10 -TimeoutSeconds 21600
```

## What Comes Next

Recommended implementation order:

1. Portfolio CSV input/output and contract IDs.
2. Batch portfolio pricing with aggregation.
3. Scenario sweeps and scenario PnL.
4. Greeks: delta, gamma, vega, rho, theta.
5. Asian payoff.
6. Basket payoff and correlation input.
7. Vol/correlation estimator and regime-weighted scenarios.
8. Event/sentiment features only if they improve out-of-sample vol, correlation, or jump-risk forecasting.
