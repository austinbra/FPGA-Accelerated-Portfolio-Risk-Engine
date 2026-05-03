# Obsidian handoff ΓÇö paste into your vault

**Purpose:** Mirror of repo state for `Options-Pricer-vault` (or your active vault). Update the dated note in Obsidian when you merge this content.

**Vault path (per `.cursor/rules/obsidian_sync.md`):** `%USERPROFILE%\Documents\Obsidian\Options-Pricer-vault\` ΓÇö e.g. `Arty A7-100 hardware.md` or a single `QMC FPGA status.md`.

---

## 2026-04-19 ΓÇö QMC-LSM FPGA checkpoint

### Done

- **Plan A** shared divider scheduler in `regression.sv`; **`FP_DIV_LATENCY = 32`**; Stage-1 pivot extra register.
- **Arty A7-100T** full route: **`vivado_build/arty_a7_100/arty_a7_qmc.bit`**, **`timing_post_route.rpt`** WNS **+0.173 ns**, TNS **0**, **0** failing endpoints at **`sys_clk` = 12 ns** (**83.333 MHz**).
- **`utilization.rpt`:** ~**22,637** slice LUTs, ~**27,412** FFs, **100** DSP48E1.
- **Simulation:** UART compute mode restored with **`FP_MUL_LATENCY = 1`** (reverted `fxMul` split). Golden price **`0x000b93cd`** (`./scripts/run_tb_top_uart_safe.ps1 -ComputeMode`).

### Learned

- **`fxMul` DSP-output register + `FP_MUL_LATENCY=2`** closed **100 MHz** timing experimentally but **deadlocked / timed out** in sim (`0xDEAD0001`); do not ship without full FSM + UART regression on that variant.
- **Relaxed XDC clock** is a valid way to report **honest fMAX** when multiply cannot be safely pipelined yet.
- **Large `$readmemh` ROMs** still show **0 BRAM tiles** in utilization ΓÇö likely distributed ROM / inference choice; optional follow-up to force BRAM if desired.
- **XC7A35T** build path exists (`run_vivado_build_arty_a7_35.ps1`) but design **exceeds LUT budget** (~24.8k vs ~20.8k) at DRC ΓÇö needs **Plan B** (share `div_b*` + `div_mean`) or reduced lanes / scope.

### Next

1. **Benchmark write-up:** cycles ├ù **12 ns** (or counter from DUT) vs C++ baseline ΓÇö no board strictly required.
2. **Optional:** flash A7-100T, UART benchmark on COM port.
3. **If 100 MHz STA required:** redo multiply pipeline with correct **back-pressure** across all consumers (regression + GBM + host-visible latency).
4. **If 35T required:** Plan B divider merge + re-run impl.
5. **Product:** multi-exercise-date backward induction (see `ROADMAP.md`).

### Verification commands

```powershell
./scripts/run_tb_top_uart_safe.ps1 -ComputeMode
.\scripts\run_vivado_build_arty_a7.ps1 -TimeoutSeconds 14400
```

Reports: `vivado_build/arty_a7_100/timing_post_route.rpt`, `utilization.rpt`.

---

## 2026-04-30 — Financial accuracy / multi-date checkpoint

### Done

- Added C++ `fixed_baseline --exercise-mode single|multi`.
- Default remains `single` so current RTL parity is unchanged.
- Added `multiExerciseInductionRtlMirror`: Q16.16 path/cashflow storage, backward induction from `M-1` to `1`, ITM-only regression, mean fallback, and final discount/average.
- Added wide regression sums for the multi-date C++ study path. This is important: trying to reuse the current single-date RTL-style 32-bit packed regression sums caused large artificial fixed-point error at high path counts.
- Extended `scripts/accuracy_study.py --exercise-mode single|multi|both` and added side-by-side columns for `single_fpga_style`, `multi_fpga_style`, improvement bps, and multi fixed-point bps.

### Learned

- The old default RTL/C++ single-date parity is still bit-exact: `validate_numerical.py` passes with 0 Q16.16 LSB delta, and `diagnose_numerical.py --paths 64 --steps 12 --option-type 1` reports no trace mismatch.
- The main remaining financial error is not fixed-point arithmetic anymore. In the multi-date smoke at `N=4096`, average PUT fixed-point error was about `1.16` bps of spot.
- Multi-date exercise directly attacks the right problem. At `N=4096`, average PUT absolute error improved from `51.92` bps single-date to `9.98` bps multi-date.
- Regression architecture matters. Multi-date RTL should not blindly reuse 32-bit packed regression sums; it needs wide accumulators / careful scaling.

### Next

1. Run broader `accuracy_study.py --preset default --exercise-mode both --attribution`.
2. Stress `M=20`, larger path counts, high volatility, and deep ITM/OTM PUTs.
3. Inspect CALL bias and regression fallback behavior.
4. If the trend holds, start RTL multi-date architecture: BRAM-backed path/cashflow storage, per-step beta RAM, backward training FSM, and decision replay.

---

## 2026-05-02 - RTL multi-date implementation/timing checkpoint

### Done

- Implemented RTL multi-exercise-date v1 behind compile-time `MULTI_EXERCISE=1`.
- Kept v1 single-lane (`NUM_LANES=1`) and avoided full `S[path][step]` storage by storing one Q16.16 cashflow per path and regenerating deterministic path prefixes for each exercise date.
- Added direct in-process Vivado implementation for the multi-date A7-100T build so it avoids the Windows `launch_runs` / `rundef.js` WMI wrapper issue.
- Generated routed multi-date bitstream: `vivado_build/arty_a7_100_multi/arty_a7_qmc_multi.bit`.

### Verified

- Single-date guard still passes: PUT `N=64/M=12`, C++/RTL delta `0` Q16.16 LSB.
- Multi-date price parity passes:
  - PUT `N=64/M=12`: `0x0005B3AC`, `401,950` cycles.
  - PUT `N=256/M=12`: `0x00068292`, `1,606,071` cycles.
  - PUT `N=4096/M=12`: `0x0006235D`, `25,685,613` cycles, about `0.308227 s` at 83.333 MHz.
  - PUT `N=8192/M=12`: `0x0004E45D`, `51,371,559` cycles, about `0.616459 s` at 83.333 MHz.
- Multi-date A7-100T post-route timing passes: WNS `+0.180 ns`, TNS `0`, 0 failing endpoints at the 12 ns `sys_clk` constraint.
- Routed resources: `23,646` slice LUTs, `27,083` slice registers, `68` DSP48E1, `16` RAMB36 tiles.

### Learned

- Batching is not justified by current A7-100T BRAM pressure: routed BRAM use is only `16 / 135` RAMB36 tiles.
- Multi-date cycle scaling is roughly linear in path count at fixed `M=12`.
- The next reason to batch would need to come from `M=20+`, a smaller FPGA target, portfolio scheduling pressure, or host-level throughput requirements, not from the current routed A7-100T memory footprint.

### Next

1. Optional `N=4096/M=20` multi-date parity stress if wall time allows.
2. Decide whether the next project phase is host portfolio batching / CSV scenario mode, Greeks, or a path-dependent payoff.
3. Keep RTL path batching deferred until evidence proves it is needed.

---

## 2026-05-02 - Spartan-7 S7-50 thesis checkpoint

### Done

- Added `MULTI_EXERCISE` generics to `arty_s7_option_pricer_top`.
- Hardened the S7 build flow to use the same in-process Vivado path as the A7 multi-date flow.
- Added `-MultiExercise` and `-ClockPeriodNs` support to `run_vivado_build_arty_s7.ps1`.
- Added an S7 XDC clock-period override while keeping the default at 10 ns / 100 MHz.

### Verified

- S7-50 multi-date synth-only passes.
- S7-50 multi-date 100 MHz build fits and routes, but fails setup timing:
  - WNS `-1.742 ns`, TNS `-596.233 ns`, 1007 failing endpoints.
  - Routed resources: `23,681 / 32,600` LUTs, `27,438 / 65,200` registers, `68 / 120` DSP48E1, `16 / 75` RAMB36.
- S7-50 multi-date 12 ns / 83.333 MHz build passes timing:
  - WNS `+0.082 ns`, TNS `0`, 0 failing endpoints.
  - Routed resources: `23,648 / 32,600` LUTs, `27,173 / 65,200` registers, `68 / 120` DSP48E1, `16 / 75` RAMB36.
  - Bitstream: `vivado_build/arty_s7_50_multi_12ns/arty_s7_qmc_multi.bit`.

### Learned

- The old Spartan-7 LUT-overflow thesis blocker is resolved for multi-date v1.
- Spartan-7 BRAM is not the limiting resource; LUT/timing is.
- The current critical 100 MHz paths are mostly GBM multiply alignment into `u_mul2`, with long CARRY/DSP paths.
- To reach 100 MHz, the next real RTL work is a handshake-correct `fxMul`/GBM pipeline split, not batching.
