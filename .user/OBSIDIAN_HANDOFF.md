# Obsidian Handoff

Copy this into the local project vault when you want the external notes to match the repo.

## 2026-06-24 - Stored-Path Multi-Lane Engine

- Replaced the active regeneration-based multi-date controller with
  `top_mc_option_pricer_multi_stored` while retaining v1 as a source-level
  historical reference.
- Stores each of the 1,024 x 50 maximum Q16.16 spots once in lane-banked BRAM;
  cashflow banks and feature workers are also lane-local, so lanes read and
  write concurrently without a shared-memory port bottleneck.
- Generates paths step-major and FIFO-aligns the current spot through the
  inverse-CDF pipeline, allowing independent path samples to overlap in flight.
- Fixed two streaming bugs exposed by interleaving: duplicate divider launches
  in `fxInvCDF_ZS` and overflow backpressure for the inverse-CDF negate FIFO.
- Added true 1/2/4/8-lane multi-date wrappers, simulation selection, and Vivado
  generic/build-directory support.
- The N=1,024/M=12 American PUT remains bit-exact against C++ and v1 at raw
  Q16.16 `428,757` (`0x00068AD5`) for every lane count.
- Core cycles are 720,474 / 411,626 / 236,362 / 121,290 at 1 / 2 / 4 / 8 lanes.
  At 100 MHz these are 7.205 / 4.116 / 2.364 / 1.213 ms.
- Four lanes reduces the v1 7,370,906-cycle compute window by 31.18x while
  preserving exact output. It does NOT beat the CPU: the routed four-lane A7
  kernel (2.364 ms) is 1.27x to 1.84x slower than the optimized i9-13905H C++
  mirror, whose means are 1.285 ms hot-kernel, 1.336 ms with path allocation,
  and 1.860 ms with direction-file loading (15 Google Benchmark repetitions).
  The strongest defensible claim is the 31.18x architectural improvement over
  the engine's own v1 RTL, not a CPU win. UART is excluded from kernel timings.
- A7-100T four-lane implementation routes at 100 MHz with WNS `+0.144 ns`,
  TNS `0`, and zero failing endpoints, using 45,875 LUTs, 46,911 registers,
  180 DSPs, and 66 RAMB36. Eight lanes is simulation-only because its 91,092
  LUTs exceed the device's 63,400 LUT capacity.
- S7-50 routes one lane at 100 MHz (WNS `+0.310 ns`, 23,399 LUTs, 28,967
  registers, 84 DSPs, 65 RAMB36). The S7-50 two-lane configuration fits
  physically (30,606 LUTs, 34,855 registers, 116 DSPs, 65 RAMB36) but does not
  close at 100 MHz, so it is published at its honest closing clock of 95.24 MHz
  (10.5 ns) with WNS `+0.083 ns`, where the 1,024x12 window is 4.322 ms. Its
  bitstream is `vivado_build/arty_s7_50_multi_lanes2_10p5ns/arty_s7_qmc_multi.bit`.
- The stored-path v2 capacity is deliberately 1,024 paths by 50 dates. Workloads
  above that bound require BRAM-sized batching; they no longer silently use the
  old 16,384-path regeneration capacity.

The detailed evidence, exact commands, CPU benchmark boundary, and fit caveats
are recorded in `.user/VALIDATION.md`.

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
