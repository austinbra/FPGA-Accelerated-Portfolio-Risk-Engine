---
description: Session handoff state. Rewritten at end of each session. Read this FIRST to know where to pick up.
globs: ["**/*"]
alwaysApply: true
---

# Primer: Current Session State

Last updated: 2026-05-03

## Current Project

This fork is now the FPGA QMC-LSM portfolio risk engine project.

The original FPGA-accelerated American option pricer is the completed kernel foundation. The next work is product infrastructure around repeated pricing:

1. Portfolio CSV input/output.
2. Contract IDs and aggregation.
3. Scenario sweeps.
4. Greeks through bump/revalue.
5. Asian payoff.
6. Basket payoff and correlation input.

## Completed Kernel Foundation

Final state:

- Multi-date RTL v1 behind `MULTI_EXERCISE=1`.
- `NUM_LANES=1` for multi-date v1.
- PUT exercises at every simulated step `1..M-1`.
- CALL suppresses early exercise while `q=0`.
- C++ `fixed_baseline --fpga-style --exercise-mode multi` is the parity oracle.
- Sobol stream uses `src/gen/direction.mem`, starts at index 1, and guards truncated `u_q16=0` to one LSB.
- A7-100T and S7-50 multi-date builds both route at 100 MHz.

## Final Measured Hardware Results

A7-100T:

- WNS `+0.153 ns`, TNS `0`, 0 failing endpoints at 10 ns.
- Resources: 23,167 LUTs, 27,873 registers, 80 DSP48E1, 16 RAMB36.
- Bitstream: `vivado_build/arty_a7_100_multi_10ns/arty_a7_qmc_multi.bit`.

S7-50:

- WNS `+0.113 ns`, TNS `0`, 0 failing endpoints at 10 ns.
- Resources: 23,154 LUTs, 27,873 registers, 80 DSP48E1, 16 RAMB36.
- Bitstream: `vivado_build/arty_s7_50_multi_10ns/arty_s7_qmc_multi.bit`.

## Public Docs

Root docs describe the fork and kernel foundation:

- `README.md`
- `PROJECT_REPORT.md`

Do not rewrite root docs into a narrow vanilla-option thesis report. Keep the product direction visible.

## Internal Memory

Use:

- `.user/IMPLEMENTATION_STATUS.md` for current foundation and planned product status.
- `.user/VALIDATION.md` for gates.
- `.user/FPGA_BUILD.md` for Vivado/hardware flows.
- `.user/ACCURACY.md` for bps methodology and product accuracy policy.
- `.user/FUTURE_PROJECT.md` for the product story.
- `.user/ROADMAP.md` for next tasks.

## Next Work

Start with host-side tooling:

```powershell
python scripts\portfolio_price.py --portfolio examples\portfolio.csv --output-dir .tmp\portfolio_smoke --target cpu
```

Then add:

- `--target fpga`,
- `--target both`,
- scenario sweeps,
- Greeks.

Do not prioritize variance reduction, path batching, or higher fmax until product measurements show a concrete need.

## Keep These Gates Green

```powershell
python scripts\validate_numerical.py --exercise-mode single --paths 64 --steps 12 --option-type 1 --build-cpu
python scripts\validate_numerical.py --exercise-mode multi --paths 64 --steps 12 --option-type 1 --build-cpu
python scripts\diagnose_numerical.py --paths 64 --steps 12 --option-type 1 --exercise-mode multi
git diff --check
```

For RTL changes, also rerun the relevant Vivado implementation flow.
