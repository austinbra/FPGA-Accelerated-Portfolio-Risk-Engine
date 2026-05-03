# QMC-LSM-to-FPGA — Validation

> How to verify the design before merging RTL or host changes.

---

## Quick-run checklist

Default validation parameters are ATM PUT (`option_type=1`) so the early-exercise branch is exercised. The CPU reference runs in FPGA-style single-exercise mode to match the current RTL. Use `opt=0` / `option_type=0` explicitly when you want the historical non-dividend CALL smoke case.

```powershell
# 1. Compile all RTL
./scripts/run_xvlog_src.ps1

# 2. Elaboration smoke
./scripts/run_xelab_smoke.ps1

# 3. UART TB - timeout path
./scripts/run_tb_top_uart_safe.ps1

# 4. UART TB - full pricing run, single lane
./scripts/run_tb_top_uart_safe.ps1 -ComputeMode

# 5. Numerical gate - FPGA sim vs C++ baseline
python scripts/validate_numerical.py

# 6. Financial accuracy study - bps vs American reference
python scripts/accuracy_study.py --preset smoke --build-cpu --attribution

# Optional path-count sweep - estimator vs fixed-point attribution
python scripts/accuracy_study.py --preset smoke --paths-list 64,256,1024,4096 --build-cpu --attribution --output-dir .tmp/accuracy_path_sweep

# Optional multi-exercise-date study - C++ hardware proxy plus RTL spot parity
python scripts/accuracy_study.py --preset smoke --paths-list 256,1024,4096 --exercise-mode both --build-cpu --attribution --output-dir .tmp/accuracy_multi

# Optional pre-RTL health/stress gate
python scripts/accuracy_study.py --preset smoke --paths-list 1024,4096,8192 --steps-list 12,20 --moneyness-list 0.6,0.8,1.0,1.2,1.4 --sigma-list 0.05,0.2,0.4,0.6 --option-types put,call --exercise-mode both --attribution --health-metrics --output-dir .tmp/accuracy_stress_policy_health

# Optional stabilized-contract health/stress gate
python scripts/accuracy_study.py --preset smoke --paths-list 4096,8192,16384 --steps-list 12,20 --moneyness-list 0.8,1.0,1.2 --sigma-list 0.1,0.2,0.4 --T-list 1.0 --option-types put,call --exercise-mode both --attribution --health-metrics --output-dir .tmp/accuracy_largeN_centered_cap_health

# Optional final default gate for RTL go/no-go
python scripts/accuracy_study.py --preset default --exercise-mode both --build-cpu --attribution --health-metrics --output-dir .tmp/accuracy_default_centered_cap_health

# 7. Numerical diagnosis - first raw C++/RTL divergence
python scripts/diagnose_numerical.py --paths 4 --steps 4 --option-type 1
python scripts/diagnose_numerical.py --paths 8 --steps 12 --option-type 1
python scripts/diagnose_numerical.py --paths 64 --steps 12 --option-type 1

# 8. Experimental multi-exercise RTL v1 gate (NUM_LANES=1 only)
python scripts/diagnose_numerical.py --paths 4 --steps 4 --option-type 1 --exercise-mode multi
python scripts/diagnose_numerical.py --paths 8 --steps 12 --option-type 1 --exercise-mode multi
python scripts/diagnose_numerical.py --paths 64 --steps 12 --option-type 1 --exercise-mode multi
python scripts/diagnose_numerical.py --paths 8 --steps 12 --option-type 0 --exercise-mode multi

# Multi-exercise UART smoke
./scripts/run_tb_top_uart_safe.ps1 -MultiExercise -TestPlusargs "paths=64,steps=12,S0=6553600,K=6553600,r=3277,sigma=13107,T=65536,opt=1"

# Parameterized multi-exercise price parity
python scripts/validate_numerical.py --exercise-mode multi --paths 64 --steps 12 --option-type 1 --build-cpu --output-csv .tmp/rtl_price_parity.csv
python scripts/validate_numerical.py --exercise-mode multi --paths 256 --steps 12 --option-type 1 --output-csv .tmp/rtl_price_parity.csv
python scripts/validate_numerical.py --exercise-mode multi --paths 4096 --steps 12 --option-type 1 --xsim-timeout-seconds 3600 --output-csv .tmp/rtl_price_parity.csv

# Multi-exercise A7-100T synth-only resource gate
.\scripts\run_vivado_build_arty_a7.ps1 -SynthOnly -MultiExercise -TimeoutSeconds 14400

# Multi-exercise A7-100T full implementation/timing gate
.\scripts\run_vivado_build_arty_a7.ps1 -MultiExercise -TimeoutSeconds 21600

# Multi-exercise Arty S7-50 implementation/timing gates
.\scripts\run_vivado_build_arty_s7.ps1 -MultiExercise -TimeoutSeconds 21600
.\scripts\run_vivado_build_arty_s7.ps1 -MultiExercise -ClockPeriodNs 12 -TimeoutSeconds 21600
```

Optional cleanup:

```powershell
./scripts/cleanup_artifacts.ps1 -IncludeSimDirs
```

---

## Multi-lane checks

```powershell
# Two-lane parity
./scripts/run_tb_top_uart_safe.ps1 -ComputeMode -NumLanes 2

# Higher-lane spot checks
./scripts/run_tb_top_uart_safe.ps1 -ComputeMode -NumLanes 3
./scripts/run_tb_top_uart_safe.ps1 -ComputeMode -NumLanes 4
./scripts/run_tb_top_uart_safe.ps1 -ComputeMode -NumLanes 8
```

**Constraint:** `lat_N` must be divisible by `NUM_LANES`.

---

## Gate criteria

| Gate | Criterion | Status |
|------|-----------|--------|
| RTL compile | 0 errors from `xvlog` | Passing |
| Elaboration | 0 errors from `xelab` | Passing |
| Numerical | Historical CALL price within 1% of C++ baseline | Passing |
| Numerical | Default PUT price vs C++ FPGA-style baseline | Passing: bit-exact trace parity for `N=4/M=4`, `N=8/M=12`, and `N=64/M=12` |
| Financial accuracy | Bps report vs in-repo American CRR reference | Run `scripts/accuracy_study.py`; no pass/fail threshold yet |
| Multi-date C++ study | Multi-date C++ mirror improves PUT bps before RTL rewrite | Historical gate justified RTL v1; rerun after RTL-regression mirror lock before publishing final bps |
| Multi-date CALL policy | Non-dividend CALL early exercise must be suppressed while `q=0` | Passing in C++ policy sweep and RTL CALL trace parity: early exercise is skipped while `q=0` |
| Multi-date PUT regression | Centered basis plus beta-cap fallback bounds regression coefficients | Passing in RTL trace parity through `N=64/M=12`; rerun default/stress accuracy grids for final production bps |
| Multi-date RTL v1 | Compile-time `MULTI_EXERCISE=1`, `NUM_LANES=1`, cashflow RAM + deterministic path regeneration | Passing trace parity vs C++ fixed-point mirror for PUT `N=4/M=4`, PUT `N=8/M=12`, PUT `N=64/M=12`, and CALL `N=8/M=12` |
| Multi-date price parity | Parameterized C++/RTL price gate, non-debug | Passing PUT `N=64/M=12`, PUT `N=256/M=12`, PUT `N=1024/M=12`, PUT `N=4096/M=12`, PUT `N=8192/M=12`, and CALL `N=64/M=12`, all `0` Q16.16 LSB delta |
| Multi-date synth-only | A7-100T `MULTI_EXERCISE=1` separate build directory | Passing synth-only; `utilization_synth.rpt` generated in `vivado_build/arty_a7_100_multi` |
| Multi-date full implementation | A7-100T `MULTI_EXERCISE=1` place/route and bitstream | Passing post-route timing at 83.333 MHz: WNS `+0.180 ns`, TNS `0`, 0 failing endpoints; bitstream generated at `vivado_build/arty_a7_100_multi/arty_a7_qmc_multi.bit` |
| Multi-date S7-50 implementation | Spartan-7 XC7S50 place/route and bitstream | Fits and routes. At 100 MHz: WNS `-1.742 ns`, TNS `-596.233 ns`, 1007 failing endpoints. At 83.333 MHz / 12 ns: passing WNS `+0.082 ns`, TNS `0`, 0 failing endpoints; bitstream generated at `vivado_build/arty_s7_50_multi_12ns/arty_s7_qmc_multi.bit` |
| Multi-lane parity | `NUM_LANES=2` bit-identical to `NUM_LANES=1` | Passing |
| Multi-lane parity | `NUM_LANES=4` bit-identical to `NUM_LANES=1` | Passing |
| Multi-lane parity | `NUM_LANES=8` bit-identical to `NUM_LANES=1` | Passing |
| FPGA (optional hardware) | On-board UART price check vs simulation | Out of scope for default CI |

---

## Elaboration note

Smoke elaboration uses `src/sim/fxDiv_core_stub.sv` in place of the Xilinx `fxDiv_core` IP. The stub completes division in 1 simulation cycle while the real IP is deeper. The top-level FSM includes a `drain_cnt` cooldown guard to tolerate this in simulation.

---

## Numerical parity contract

Production validation uses Sobol QMC from `src/gen/direction.mem`, starts at Sobol index 1, and guards the lower boundary after RTL truncation (`sobol_out[31:16] == 0` feeds `u_q16 = 1`). The C++ `--fpga-style` baseline mirrors this stream and the RTL fixed-point LUT/division/sqrt/inverse-CDF/GBM/regression/final-average stages. `--full-lsm` remains a higher-level CPU model, not the hardware parity oracle.

The C++ binary also supports `--exercise-mode multi` for the multi-exercise-date fixed-point mirror. PUTs use LSM at every step `1..M-1` with centered basis `[1, S/K-1, (S/K-1)^2]`, the RTL regression mirror, and beta-cap fallback at `4096`; CALLs suppress early exercise while `q=0` and use a terminal-payoff fast path. RTL multi-date v1 is compile-time selectable with `MULTI_EXERCISE=1`, supports `NUM_LANES=1`, stores one Q16.16 cashflow per path, and regenerates deterministic Sobol paths per exercise date rather than storing the full `S[path][step]` grid.

Latest default PUT gate: C++ `0x00040608`, RTL sim `0x00040608`, Q16.16 delta `0` LSB.

Latest multi-date PUT production-hardening gates: `N=4096/M=12`, C++ `0x0006235D`, RTL sim `0x0006235D`, Q16.16 delta `0` LSB, `25,685,613` core cycles, about `0.308227 s` at the current `83.333 MHz` STA clock target; `N=8192/M=12`, C++ `0x0004E45D`, RTL sim `0x0004E45D`, Q16.16 delta `0` LSB, `51,371,559` core cycles, about `0.616459 s`.

Multi-date A7-100T implementation gate: passing. The multi-date build uses direct in-process `synth_design`, `opt_design`, `place_design`, `phys_opt_design`, `route_design`, and `write_bitstream` to avoid Vivado's Windows `rundef.js` WMI wrapper issue. Post-route timing is clean at the current 12 ns constraint: WNS `+0.180 ns`, TNS `0`, 0 failing endpoints, and fully routed nets. Routed resources: `23,646` slice LUTs (`37.30%`), `27,083` slice registers (`21.36%`), `68` DSP48E1 (`28.33%`), and `16` RAMB36 tiles (`11.85%`). Bitstream: `vivado_build/arty_a7_100_multi/arty_a7_qmc_multi.bit`.

Multi-date Spartan-7 S7-50 gate: passing for the relaxed 12 ns thesis target, not for 100 MHz. The 100 MHz route fits and produces a bitstream but fails setup timing with WNS `-1.742 ns`, TNS `-596.233 ns`, and 1007 failing endpoints. The 12 ns build passes with WNS `+0.082 ns`, TNS `0`, 0 failing endpoints, and fully routed nets. Routed 12 ns resources: `23,648` slice LUTs (`72.54%`), `27,173` slice registers (`41.68%`), `68` DSP48E1 (`56.67%`), and `16` RAMB36 tiles (`21.33%`). Bitstream: `vivado_build/arty_s7_50_multi_12ns/arty_s7_qmc_multi.bit`.

---

## Financial accuracy gate

Run `python scripts/accuracy_study.py --preset smoke --build-cpu --attribution`
to generate `.tmp/accuracy/accuracy_results.csv` and
`.tmp/accuracy/accuracy_summary.md`. This compares the bit-exact C++ FPGA-style
hardware proxy against an in-repo Cox-Ross-Rubinstein American option reference
and reports errors in bps. Details: `.user/ACCURACY.md`.

---

## Toolchain prerequisite

Vivado with `xvlog`, `xelab`, and `xsim` on `PATH`. C++ baseline requires `g++` with C++17.
