# Obsidian Handoff

Copy this into the local project vault when you want the external notes to match the repo.

## 2026-05-03 - Fork Reframed As Portfolio Risk Engine

### Completed

- Reframed the repository from a completed FPGA option-pricer thesis artifact into a forked portfolio/scenario/Greeks risk-engine project.
- Root `README.md` now leads with the new product identity and treats the FPGA QMC-LSM option pricer as the acceleration foundation.
- Rewrote `PROJECT_REPORT.md` around the fork scope: repeated pricing, scenario sweeps, Greeks, and future path-dependent or multi-asset products.
- Renamed `.cursor` to `.ai` for repo-local AI/session memory.
- Updated `.user` and `.ai` documentation so future work starts from portfolio CSVs, scenario sweeps, and bump/revalue Greeks.

### Kernel Foundation Preserved

- Multi-date RTL supports American PUT backward induction at exercise dates `1..M-1`.
- Non-dividend CALLs use the terminal fast path while `q=0`.
- C++ `fixed_baseline --fpga-style --exercise-mode multi` remains the parity oracle.
- RTL/C++ parity gates pass with 0 Q16.16 LSB delta for single-date PUT and multi-date PUT/CALL smoke cases.
- Sobol stream starts at index 1 and remaps truncated `u_q16=0` to one LSB before inverse-CDF.
- Multi-date RTL stores one Q16.16 cashflow per path in BRAM and regenerates deterministic path prefixes instead of storing `S[path][step]`.

### Final Hardware Results

Arty A7-100T:

- 100 MHz / 10 ns routed build passes.
- WNS `+0.153 ns`, TNS `0`, 0 failing endpoints.
- LUTs `23,167 / 63,400 = 36.54%`.
- Registers `27,873 / 126,800 = 21.98%`.
- DSP48E1 `80 / 240 = 33.33%`.
- RAMB36 `16 / 135 = 11.85%`.
- Bitstream: `vivado_build/arty_a7_100_multi_10ns/arty_a7_qmc_multi.bit`.

Arty S7-50:

- 100 MHz / 10 ns routed build passes.
- WNS `+0.113 ns`, TNS `0`, 0 failing endpoints.
- LUTs `23,154 / 32,600 = 71.02%`.
- Registers `27,873 / 65,200 = 42.75%`.
- DSP48E1 `80 / 120 = 66.67%`.
- RAMB36 `16 / 75 = 21.33%`.
- Bitstream: `vivado_build/arty_s7_50_multi_10ns/arty_s7_qmc_multi.bit`.

### Product Direction

Start the bigger product story:

1. Portfolio CSV input/output.
2. Contract IDs and portfolio aggregation.
3. Scenario sweeps and scenario PnL.
4. Greeks through bump/revalue.
5. Asian payoff.
6. Basket payoff and correlation input.
7. Vol/correlation estimator and regime-weighted scenarios.
8. Event/sentiment only if it improves out-of-sample risk forecasts.

Use names like:

- Hardware-Accelerated Scenario Pricing and Greeks Engine for Complex Derivatives.
- FPGA-Accelerated QMC-LSM Portfolio Risk Engine for Path-Dependent Early-Exercise Derivatives.

Avoid:

- FPGA sentiment-driven options pricer.

### Validation Commands To Keep

```powershell
python scripts\validate_numerical.py --exercise-mode single --paths 64 --steps 12 --option-type 1 --build-cpu
python scripts\validate_numerical.py --exercise-mode multi --paths 64 --steps 12 --option-type 1 --build-cpu
python scripts\validate_numerical.py --exercise-mode multi --paths 256 --steps 12 --option-type 1
python scripts\diagnose_numerical.py --paths 64 --steps 12 --option-type 1 --exercise-mode multi
.\scripts\run_vivado_build_arty_a7.ps1 -MultiExercise -ClockPeriodNs 10 -TimeoutSeconds 21600
.\scripts\run_vivado_build_arty_s7.ps1 -MultiExercise -ClockPeriodNs 10 -TimeoutSeconds 21600
```

## 2026-05-03 - Cleanup Pass

### Removed

- Deleted generated workspace artifacts: Vivado/XSIM outputs, logs, caches, old build trees, and empty legacy directories.
- Removed root-level wrapper scripts now superseded by `scripts\...` entry points.
- Removed duplicate root `cleanup_artifacts.ps1`; kept `scripts\cleanup_artifacts.ps1`.
- Removed failed/unused A7-35 build flow.
- Removed one-off debug helpers: `baseline/cpp_fixed/test_itm.cpp`, `src/gen_dim.cpp`, `src/max_X4.py`.
- Removed large Joe-Kuo source direction file after keeping the generated `src/gen/direction.mem` used by the active kernel.
- Removed local `.user/ROADMAP_PRIVATE.md` scratch.

### Kept

- Active A7-100T and S7-50 flows.
- Active C++ mirror, validation scripts, Vivado scripts, RTL, generated LUT/memory files needed by the kernel, and testbenches.

### Verification

```powershell
git diff --check
```
