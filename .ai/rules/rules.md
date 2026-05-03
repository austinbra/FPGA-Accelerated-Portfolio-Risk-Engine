---
description: Permanent project identity, architecture, design rules, and file map for the FPGA QMC-LSM portfolio risk engine.
globs: ["**/*.sv", "**/*.py", "**/*.ps1", "**/*.tcl", "**/*.md"]
alwaysApply: true
---

# FPGA QMC-LSM Portfolio Risk Engine Rules

## Identity

Current project: hardware-accelerated portfolio/scenario pricing and Greeks engine.

Foundation: completed FPGA-accelerated QMC-LSM American option pricing kernel.

Preferred product identity:

- Hardware-Accelerated Scenario Pricing and Greeks Engine for Complex Derivatives
- FPGA-Accelerated QMC-LSM Portfolio Risk Engine for Path-Dependent Early-Exercise Derivatives
- FPGA QMC-LSM Portfolio Risk Engine

Avoid "sentiment-driven options pricer" as the primary identity.

## Product Architecture Target

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

Build host-side portfolio and scenario infrastructure before changing RTL.

## Kernel Architecture

```text
UART params
  -> init constants
  -> Sobol QMC
  -> inverse CDF
  -> GBM path generation
  -> cashflow RAM
  -> backward LSM regression/decision
  -> final discounted average
  -> UART result packet
```

Single-date mode remains as the historical default compatibility path.

Multi-date mode:

- compile-time `MULTI_EXERCISE=1`,
- `NUM_LANES=1` in v1,
- PUT exercise dates `1..M-1`,
- CALL terminal fast path while `q=0`,
- one Q16.16 cashflow per path in BRAM,
- deterministic path regeneration per exercise date,
- centered basis `[1, S/K - 1, (S/K - 1)^2]`,
- singular/unstable regression fallback to mean continuation,
- beta cap fallback at 4096.0.

## Final Hardware Results

A7-100T:

- 100 MHz / 10 ns route passes.
- WNS `+0.153 ns`, TNS `0`, 0 failing endpoints.
- 23,167 LUTs, 27,873 registers, 80 DSP48E1, 16 RAMB36.

S7-50:

- 100 MHz / 10 ns route passes.
- WNS `+0.113 ns`, TNS `0`, 0 failing endpoints.
- 23,154 LUTs, 27,873 registers, 80 DSP48E1, 16 RAMB36.

Current max is only proven slightly above 100 MHz. Do not claim 110+ MHz unless a tighter Vivado sweep passes.

## Fixed-Point Format

Q16.16:

- 32-bit signed,
- 16 integer bits,
- 16 fractional bits,
- one LSB = 1 / 65536,
- range about `[-32768, 32767.99998]`.

Use `src/fpga_cfg_pkg.sv` constants. Do not hand-write fragile fixed-point constants.

## Sobol Contract

Production stream:

- read `src/gen/direction.mem`,
- use Gray-code XOR generation,
- start at Sobol index 1,
- truncate `sobol_out[31:16]`,
- if truncated value is zero, feed `u_q16 = 1`.

Never let inverse-CDF receive `u=0`.

## Numerical Parity Contract

C++ parity oracle:

```powershell
baseline\cpp_fixed\fixed_baseline.exe --fpga-style --exercise-mode single|multi --direction-file src\gen\direction.mem --lut-dir src\gen
```

RTL parity script:

```powershell
python scripts\validate_numerical.py --exercise-mode multi --paths 64 --steps 12 --option-type 1 --build-cpu
```

Diagnosis:

```powershell
python scripts\diagnose_numerical.py --paths 64 --steps 12 --option-type 1 --exercise-mode multi
```

Fix first raw trace mismatch, not final price symptoms.

## Product Implementation Principles

1. Start with `--target cpu` using the C++ mirror.
2. Add `--target fpga` only after CSV parsing and reporting are stable.
3. Preserve contract IDs through every output.
4. Record scenario names, bump sizes, paths, steps, and target in reports.
5. Keep CPU/FPGA deltas visible when `--target both` is used.
6. Do not hide estimator noise behind polished portfolio summaries.
7. Do not change UART packet format unless the product phase deliberately versions it.

## Mandatory Verification Behavior

For documentation-only changes:

```powershell
git diff --check
```

For Python/script changes:

```powershell
python -m py_compile scripts\validate_numerical.py scripts\diagnose_numerical.py scripts\accuracy_study.py scripts\financial_reference.py scripts\vivado_build_runner.py
```

For product scripts, also compile and run the relevant product smoke command once those scripts exist.

For RTL changes:

```powershell
.\scripts\run_xelab_smoke.ps1 -XvlogTimeoutSeconds 600 -XelabTimeoutSeconds 600 -NoCleanup
python scripts\validate_numerical.py --exercise-mode single --paths 64 --steps 12 --option-type 1 --build-cpu
python scripts\validate_numerical.py --exercise-mode multi --paths 64 --steps 12 --option-type 1 --build-cpu
python scripts\diagnose_numerical.py --paths 64 --steps 12 --option-type 1 --exercise-mode multi
```

For timing/resource changes:

```powershell
.\scripts\run_vivado_build_arty_a7.ps1 -MultiExercise -ClockPeriodNs 10 -TimeoutSeconds 21600
.\scripts\run_vivado_build_arty_s7.ps1 -MultiExercise -ClockPeriodNs 10 -TimeoutSeconds 21600
```

## Design Principles

1. Preserve ready/valid correctness.
2. Hold outputs stable under backpressure.
3. Use event-alignment FIFOs for side-channel data.
4. Normalize regression inputs.
5. Prefer stage-by-stage diagnosis over final-price guessing.
6. Treat C++/RTL parity, financial accuracy, and product accuracy separately.
7. Do not add RTL batching without measured BRAM/cycle/product pressure.
8. Do not add variance reduction unless it reduces a measured path-count bottleneck.
9. Do not claim physical silicon timing from xsim wall time; use `core_cycles / fclk`.
10. Keep root docs product-facing; keep detailed roadmap and validation in `.user`.

## File Map

```text
src/fpga_cfg_pkg.sv                 global fixed-point config
src/math/fxMul.sv                   true pipelined fixed-point multiplier
src/math/fxDiv.sv                   divider wrapper
src/math/fxExpLUT.sv                exp LUT
src/math/fxLnLUT.sv                 natural log LUT
src/math/fxSqrt.sv                  restoring sqrt
src/math/fxInvCDF_ZS.sv             inverse-CDF approximation
src/steps/sobol.sv                  Sobol generator
src/steps/GBM.sv                    GBM path step
src/steps/accumulator.sv            regression sufficient statistics
src/steps/regression.sv             3x4 Gaussian solver
src/steps/lsm_decision.sv           exercise/continue logic
src/top/top_option_pricer.sv        single-date top
src/top/top_option_pricer_multi.sv  multi-date top
fpga/                               board wrappers
constraints/                        XDC files
scripts/                            validation/build/study/product scripts
baseline/cpp_fixed/                 bit-exact C++ mirror
.user/                              project memory and product plan
.ai/                                AI/session memory
```

## Next Product Direction

Start from `.user/ROADMAP.md`.

First product tasks:

1. portfolio CSV runner,
2. scenario sweep runner,
3. portfolio aggregation,
4. Greeks via bump/revalue,
5. Asian payoff,
6. basket/correlation support.
