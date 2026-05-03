# QMC-LSM-to-FPGA — Implementation Status

> **Where we are:** All pipeline modules complete and fully synthesizable. Default single-date PUT C++/RTL numerical parity is bit-exact through the diagnosis ladder (`N=4/M=4`, `N=8/M=12`, `N=64/M=12`) using the production Sobol QMC stream and RTL fixed-point mirror. Multi-lane (`NUM_LANES` 1/2/4/8) was previously verified bit-identical in simulation for the default single-date engine. RTL multi-exercise-date v1 now exists as a compile-time selectable path (`MULTI_EXERCISE=1`) with `NUM_LANES=1`, synchronous cashflow BRAM, deterministic path regeneration, centered PUT basis, RTL regression mirror, beta-cap fallback, and no-dividend CALL terminal fast path. Multi-date RTL trace parity passes PUT `N=4/M=4`, PUT `N=8/M=12`, PUT `N=64/M=12`, and CALL `N=8/M=12`; non-debug price parity passes through PUT `N=8192/M=12`. A7-100T multi-date synth-only and full implementation complete, infer the cashflow memory into BRAM, generate a routed bitstream, and meet the current **83.333 MHz** timing constraint. **Arty S7-50 / Spartan-7 XC7S50 also fits, routes, generates a multi-date bitstream, and meets timing at 83.333 MHz / 12 ns; it does not meet 100 MHz without more timing work.** **Arty A7-35T** does **not** fit (LUT logic over the part budget). Primary performance story remains RTL + STA-scaled cycles (`run_virtual_a7_benchmark.ps1` / `--target virtual`).

Last updated: 2026-05-02

---

## What's implemented

| # | Feature | Status |
|---|---------|--------|
| 1 | Sobol QMC sequence generator (Gray-coded, deterministic, corrected Joe-Kuo direction recurrence) | Done |
| 2 | InverseCDF pipeline (Zelen-Severo rational approx, fully pipelined) | Done |
| 3 | GBM streaming pipeline (MUL -> EXP -> MUL, ~5 cycles, pre-computed constants) | Done |
| 4 | Accumulator (online Q16.16, 8 running 64-bit sums, O(1) memory) | Done |
| 5 | Regression solver (3x4 Gaussian elimination, pivot fallback) | Done |
| 6 | LSM decision (exercise vs continue, PUT/CALL runtime flag) | Done |
| 7 | Two-pass LSMC top FSM (training -> decision, fully pipelined step overlap) | Done |
| 8 | UART I/O (8-word param RX, 5-word result TX with status flags) | Done |
| 9 | Antithetic variates (paired z/-z paths, 2x effective N at no cost) | Done |
| 10 | PUT/CALL runtime flag (UART word 7 bit 0) | Done |
| 11 | Error reporting (timeout + singular-regression flags in result packet) | Done |
| 12 | Synthesizable **fxlnLUT** (2-stage BRAM + `$readmemh`, `fxExpLUT`-style handshake; `ln_lut_4096.mem` left-bin Q16.16; `scripts/gen_ln_lut_4096.py`) | Done |
| 13 | Synthesizable **fxSqrt** (restoring digit-by-digit `sqrt(a<<QFRAC)`, 24 `COMP` cycles + `IDLE`/`DONE`; `FP_SQRT_LATENCY=24`; no `$sqrt`) | Done |
| 14 | Precision centralization (all constants in `fpga_cfg_pkg.sv`, elaboration assertions) | Done |
| 15 | Multi-lane scheduling - `NUM_LANES > 1` (D5) | Done |
| 16 | Host: benchmark mode (CPU vs FPGA price + timing) | Done |
| 17 | Host: live mode (Yahoo Finance params) | Done |
| 18 | Host: convergence sweep (`--mode sweep`) | Done |
| 19 | Bit-exact C++ FPGA-style mirror (RTL Sobol `direction.mem`, skip-zero guard, LUT/div/sqrt/inv-CDF/GBM/regression/final average) | Done |
| 20 | C++ multi-exercise-date fixed-point mirror (`--exercise-mode multi`, Q16.16 paths/cashflows, RTL regression mirror, centered basis, beta cap, CALL fast path) | Done |
| 21 | RTL multi-exercise-date v1 (`MULTI_EXERCISE=1`, `NUM_LANES=1`, synchronous cashflow BRAM, deterministic path regeneration, PUT backward induction, CALL terminal fast path) | Production hardening passed for A7-100T: price parity through PUT `N=8192/M=12`, synth-only passed, full implementation passed timing, and `arty_a7_qmc_multi.bit` generated |
| 22 | Arty S7-50 / Spartan-7 XC7S50 multi-date implementation (`MULTI_EXERCISE=1`) | Fits and routes; 100 MHz misses timing by WNS `-1.742 ns`; 12 ns / 83.333 MHz passes with WNS `+0.082 ns` and `arty_s7_qmc_multi.bit` generated |

---

## Current validated price

| Config | Q16.16 hex | Float approx | vs C++ baseline |
|--------|-----------|--------------|----------------|
| Default PUT, `N=64`, `M=12`, `NUM_LANES=1` | `0x00040608` | approx 4.02356 | bit-exact C++/RTL trace parity |
| Multi-date PUT, `N=64`, `M=12`, `NUM_LANES=1` | `0x0005b3ac` | approx 5.70184 | bit-exact C++/RTL trace parity in `MULTI_EXERCISE=1` mode |
| Multi-date PUT, `N=4096`, `M=12`, `NUM_LANES=1` | `0x0006235d` | approx 6.13814 | bit-exact C++/RTL price parity; `25,685,613` core cycles |
| Multi-date PUT, `N=8192`, `M=12`, `NUM_LANES=1` | `0x0004e45d` | approx 4.89204 | bit-exact C++/RTL price parity; `51,371,559` core cycles |
| Diagnostic PUT, `N=8`, `M=12`, `NUM_LANES=1` | trace-only | trace-only | bit-exact C++/RTL trace parity |
| Diagnostic PUT, `N=4`, `M=4`, `NUM_LANES=1` | trace-only | trace-only | bit-exact C++/RTL trace parity |

Parameters used for the default price table: N=64 paths, M=12 steps, S0=K=100, r=0.05, sigma=0.2, T=1.0, PUT. The production Sobol contract is RTL `direction.mem` generated from Joe-Kuo directions, Sobol index starts at 1, and `sobol_out[31:16] == 0` is remapped to `u_q16 = 1` before inverse-CDF. The C++ comparison mode defaults to the current RTL's single exercise date at `M-1`; pass `--exercise-mode multi` to match the new `MULTI_EXERCISE=1` RTL path. `--full-lsm` remains a higher-level CPU model, not the hardware parity oracle.

## Financial accuracy checkpoint

The historical C++-only pre-RTL accuracy gate included default, broad stress,
and focused large-N grids with regression health metrics. These results justified
building RTL multi-date v1. Because the C++ `--exercise-mode multi` mirror now
uses the RTL regression solver for parity, rerun the default/stress grids before
treating these exact bps as final production evidence:

```powershell
python scripts/accuracy_study.py --preset default --exercise-mode both --build-cpu --attribution --health-metrics --output-dir .tmp/accuracy_default_health
python scripts/accuracy_study.py --preset smoke --paths-list 1024,4096,8192 --steps-list 12,20 --moneyness-list 0.6,0.8,1.0,1.2,1.4 --sigma-list 0.05,0.2,0.4,0.6 --option-types put,call --exercise-mode both --build-cpu --attribution --health-metrics --output-dir .tmp/accuracy_stress_health
python scripts/accuracy_study.py --preset smoke --paths-list 4096,8192,16384 --steps-list 12,20 --moneyness-list 0.8,1.0,1.2 --sigma-list 0.1,0.2,0.4 --T-list 1.0 --option-types put,call --exercise-mode both --build-cpu --attribution --health-metrics --output-dir .tmp/accuracy_largeN_health
python scripts/accuracy_study.py --preset smoke --paths-list 1024,4096,8192 --steps-list 12,20 --moneyness-list 0.6,0.8,1.0,1.2,1.4 --sigma-list 0.05,0.2,0.4,0.6 --option-types put,call --exercise-mode both --attribution --health-metrics --output-dir .tmp/accuracy_stress_policy_health
python scripts/accuracy_study.py --preset smoke --paths-list 1024,4096,8192 --steps-list 12,20 --moneyness-list 0.6,0.8,1.0,1.2,1.4 --sigma-list 0.05,0.2,0.4,0.6 --option-types put,call --exercise-mode both --attribution --health-metrics --output-dir .tmp/accuracy_stress_centered_cap_health
python scripts/accuracy_study.py --preset smoke --paths-list 4096,8192,16384 --steps-list 12,20 --moneyness-list 0.8,1.0,1.2 --sigma-list 0.1,0.2,0.4 --T-list 1.0 --option-types put,call --exercise-mode both --attribution --health-metrics --output-dir .tmp/accuracy_largeN_centered_cap_health
python scripts/accuracy_study.py --preset default --exercise-mode both --build-cpu --attribution --health-metrics --output-dir .tmp/accuracy_default_centered_cap_health
```

Key result: PUT accuracy improves materially with multi-date LSM. In the broad
stress grid, average PUT multi-date error dropped from `50.10` bps at `N=1024`
to `20.57` bps at `N=4096` and `14.55` bps at `N=8192`, while PUT fixed-point
error dropped from `2.98` to `1.39` to `0.82` bps. The focused large-N grid is
also healthy: average PUT multi-date error is about `10` to `14` bps for
`N=4096..16384`.

CALL stabilization result: because the project currently has `q=0`, multi-date
CALL mode now suppresses early exercise and prices through the same Sobol/fixed
point terminal-payoff path. In the broad stress rerun, CALL early-exercise rate
is `0`, beta max is `0`, and average CALL fixed-point error is `1.39`, `1.46`,
and `2.01` bps for `N=1024`, `4096`, and `8192`.

PUT stabilization result: centered moneyness plus beta-cap fallback bounds the
regression. In the final broad stress rerun, average PUT error is `50.01`,
`20.16`, and `14.65` bps at `N=1024`, `4096`, and `8192`, while average PUT
fixed-point error is `2.77`, `1.50`, and `0.75` bps. In the focused large-N run,
average PUT error is `14.13`, `10.74`, and `10.93` bps at `N=4096`, `8192`, and
`16384`, with average PUT fixed-point error `1.51`, `0.54`, and `0.78` bps. PUT
beta magnitude now stays under the `4096` cap.

RTL multi-date v1 has now been implemented despite the earlier conservative
go/no-go caution, and the A7-100T production-hardening gate now passes. The
implemented architecture intentionally stores only one cashflow per path and
regenerates deterministic paths per exercise date, avoiding full
`S[path][step]` storage. Trace parity is proven through `N=64/M=12`; non-debug
price parity is proven through `N=8192/M=12`.

Multi-date synth-only A7-100T resource checkpoint (2026-05-02):
- Slice LUTs: `25,154 / 63,400` (`39.68%`)
- Slice registers: `37,880 / 126,800` (`29.87%`)
- DSP48E1: `68 / 240` (`28.33%`)
- Block RAM: `16 / 135` RAMB36 tiles (`11.85%`)

Multi-date full implementation A7-100T checkpoint (2026-05-02):
- Timing: WNS `+0.180 ns`, TNS `0`, 0 failing endpoints at the 12 ns `sys_clk` constraint
- Route status: fully routed, 0 nets with routing errors
- Slice LUTs: `23,646 / 63,400` (`37.30%`)
- Slice registers: `27,083 / 126,800` (`21.36%`)
- DSP48E1: `68 / 240` (`28.33%`)
- Block RAM: `16 / 135` RAMB36 tiles (`11.85%`)
- Bitstream: `vivado_build/arty_a7_100_multi/arty_a7_qmc_multi.bit`

Multi-date full implementation Arty S7-50 checkpoint (2026-05-02):
- 100 MHz / 10 ns build: fits and routes, but fails setup timing with WNS `-1.742 ns`, TNS `-596.233 ns`, and 1007 failing endpoints
- 100 MHz routed resources: `23,681 / 32,600` slice LUTs (`72.64%`), `27,438 / 65,200` slice registers (`42.08%`), `68 / 120` DSP48E1 (`56.67%`), and `16 / 75` RAMB36 tiles (`21.33%`)
- 12 ns / 83.333 MHz build: timing passes with WNS `+0.082 ns`, TNS `0`, and 0 failing endpoints
- 12 ns routed resources: `23,648 / 32,600` slice LUTs (`72.54%`), `27,173 / 65,200` slice registers (`41.68%`), `68 / 120` DSP48E1 (`56.67%`), and `16 / 75` RAMB36 tiles (`21.33%`)
- Bitstream: `vivado_build/arty_s7_50_multi_12ns/arty_s7_qmc_multi.bit`

The cashflow memory now infers as BRAM, and full implementation meets timing
with modest BRAM use on both A7-100T and S7-50 at 12 ns. This is evidence
against adding path batching solely for BRAM pressure at the current
`MAX_PATHS=16384`. The next optional evidence is `M=20` simulation spot checks;
batching should wait until a higher `M`, smaller FPGA, or larger portfolio flow
proves the need.

---

## Timing (A7-100T post-route) — **MET at constrained 83.333 MHz (2026-04-19)**

**Active constraint:** `constraints/arty_a7_100.xdc` defines `sys_clk` with **period 12.000 ns** (83.333 MHz). The board crystal is still 100 MHz; for on-chip operation at a different frequency you would use an MMCM — here the XDC documents the timing target Vivado closes to (cycle count × period still valid for wall-time estimates).

| Milestone | WNS | TNS | Failing EPs | Notes |
|-----------|-----|-----|-------------|--------|
| Plan A + `FP_DIV_LATENCY=32` + Stage-1 pivot pipe | (historical) | — | — | Stepped path before multiply tuning |
| At **100 MHz** with pipelined pivot, **`FP_MUL_LATENCY=1`** (current `fxMul`) | **−1.648 ns** | −410 ns | 705 | Critical path through `fxMul` / GBM-style multiply chain |
| **`fxMul` split + `FP_MUL_LATENCY=2`** | **+0.178 ns @ 100 MHz** | 0 | 0 | **Reverted:** UART compute-mode sim hit timeout / `0xDEAD0001` (handshake + extra cycle); restored `fxMul` + `FP_MUL_LATENCY=1` for correct functional closure |
| **Current gold: `FP_MUL_LATENCY=1` + 12 ns `sys_clk`** | **+0.173 ns** | 0.000 | 0 | `timing_post_route.rpt` 2026-04-19; all constraints met |

**Post-route utilization (same build, `utilization.rpt`):**
- Slice LUTs **22,637 / 63,400 (35.71%)** (LUT as logic 22,504)
- Slice FFs **27,412 / 126,800 (21.62%)**
- DSP48E1 ≈ **100 / 240** (see report for exact %)
- **Block RAM:** tool still reports **0** tile BRAM for large `$readmemh` ROMs — investigate inference / style if BRAM packing is desired

Bitstream: `vivado_build/arty_a7_100/arty_a7_qmc.bit` (routed, timing-clean **at 83.333 MHz**).

### Arty A7-35T (xc7a35ti)

Full implementation **does not fit**: DRC **`UTLZ-1`** before place — **LUT as logic** required (~24.8k) **>** available (~20.8k) for that speed grade. **Plan B** (share `div_b*` + `div_mean` with the existing shared solver divider), **reduce `NUM_LANES` / scope**, or stay on **A7-100T** / S7-75 class parts.

## What's next

| Priority | Work | Effort |
|----------|------|--------|
| High | **Arty A7-100T:** STA + bitstream at **83.333 MHz**; throughput via `run_virtual_a7_benchmark.ps1` / `uart_host.py --target virtual` (cycles × STA fclk). | — |
| Medium | **Optional USB-UART on hardware:** same host flow as [`FPGA_BUILD.md`](FPGA_BUILD.md) when validating on a physical Arty. | Low |
| Medium | **If 35T is a hard target:** Plan B shared dividers for beta/mean path, or shrink design. | Medium |
| Medium | **If 100 MHz STA is required** without relaxing XDC: re-implement `fxMul`/GBM pipelining with a **proven** sim/UART handshake; S7-50 currently misses 100 MHz by WNS `-1.742 ns`. | Medium |
| High | Optional multi-date stress simulations: `N=4096/M=20` and portfolio-style repeated pricing if wall time allows. | Medium |
| Medium | Add path batching only if `M=20`/larger `N`, timing, or a smaller FPGA target proves cashflow-BRAM/regeneration pressure requires it. Current A7-100T routed BRAM use is modest. | Medium |
| Medium | Financial accuracy refinements: Brownian bridge / variance-reduction study if lower path counts or high-volatility stress rows need stricter bps. | Medium |
| Low | ROM → BRAM inference audit (`ln`/exp LUT `.mem` paths). | Low |
| Low | Multi-batch UART regression (`-Multibatch`) stability. | Low |

Full details and rationale: [`ROADMAP.md`](ROADMAP.md)

---

## How to build and test

```powershell
# 1. Compile all RTL
./scripts/run_xvlog_src.ps1

# 2. Elaborate (9 module snapshots)
./scripts/run_xelab_smoke.ps1

# 3. Simulate - smoke (timeout path)
./scripts/run_tb_top_uart_safe.ps1

# 4. Simulate - full pricing run (NUM_LANES=1)
./scripts/run_tb_top_uart_safe.ps1 -ComputeMode

# 5. Simulate - multi-lane parity (2 / 4 / 8 lanes)
./scripts/run_tb_top_uart_safe.ps1 -ComputeMode -NumLanes 2
./scripts/run_tb_top_uart_safe.ps1 -ComputeMode -NumLanes 4
./scripts/run_tb_top_uart_safe.ps1 -ComputeMode -NumLanes 8

# 6. Numerical validation (FPGA sim vs C++ baseline)
python scripts/validate_numerical.py

# 7. Arty A7-100T place/route + bitstream (primary FPGA target today)
.\scripts\run_vivado_build_arty_a7.ps1 -TimeoutSeconds 14400

# 8. Arty A7-35T experiment (currently fails LUT DRC — see Timing section)
.\scripts\run_vivado_build_arty_a7_35.ps1 -TimeoutSeconds 14400

# 9. Arty S7-50 multi-date bitstream at 12 ns / 83.333 MHz
.\scripts\run_vivado_build_arty_s7.ps1 -MultiExercise -ClockPeriodNs 12 -TimeoutSeconds 21600
```

Full validation procedure and gate criteria: [`VALIDATION.md`](VALIDATION.md). **FPGA implementation:** [`FPGA_BUILD.md`](FPGA_BUILD.md).

---

## Resource budget

### Post-route measured, Arty A7-100T, Plan A + 83.333 MHz constraint (2026-04-19)

`vivado_build/arty_a7_100/utilization.rpt` after `route_design`:

| Resource | Used | A7-100T | S7-50 equivalent | Fits A7-100 | Fits A7-35 | Fits S7-50 |
|----------|------|---------|------------------|-------------|------------|------------|
| **LUT as Logic** | **22,504** | 63,400 (35.5%) | 32,600 (69.2%) | Yes | **No (~20.8k avail.)** | **Yes** |
| Slice Registers | 27,412 | 126,800 (21.6%) | — | Yes | TBD | Yes |
| DSP48E1 | 100 | 240 (41.7%) | 120 (83%) | Yes | Risky | Tight |
| Block RAM | 0 | 135 (0%) | — | Yes | — | Yes |
| `fxDiv_core` instances | 7 (was 16) | — | — | — | — | — |

**Plan A savings** (measured vs. pre-Plan-A S7-50 impl DRC):
- LUT as Logic: 37,141 → ~22.5k (latest routed A7-100) = **~−14.6k LUTs (−39%)**
- CARRY4 dropped materially vs. 16-divider build (see routed utilization distribution in Vivado report)
- `fxDiv_core`: 16 → 7 (shared 10 solver divs into 1; back-sub 4 + mean 1 + inv-CDF 1 + util 1 still discrete)

### Current S7-50 multi-date v1 (2026-05-02)

The current multi-date design now fits and routes on XC7S50. At the board's
default 10 ns constraint it produces a bitstream but misses timing; at the same
12 ns / 83.333 MHz thesis target used for A7-100T, it passes timing.

| Resource | 12 ns routed use | S7-50 budget | Usage |
|----------|------------------|--------------|-------|
| Slice LUTs | 23,648 | 32,600 | 72.54% |
| Slice Registers | 27,173 | 65,200 | 41.68% |
| DSP48E1 | 68 | 120 | 56.67% |
| Block RAM | 16 RAMB36 | 75 RAMB36 | 21.33% |

Timing:
- 10 ns / 100 MHz: WNS `-1.742 ns`, TNS `-596.233 ns`, 1007 failing endpoints
- 12 ns / 83.333 MHz: WNS `+0.082 ns`, TNS `0`, 0 failing endpoints

### Pre-Plan-A baseline (2026-04-17, S7-50, do-not-fit regression)

`impl_1` DRC `UTLZ-1` before `place_design`:
- LUT as Logic 37,141 / 32,600 (113.9% — overfit)
- CARRY4 8,344 / 8,150 (102.4% — overfit)
- 16 × `div_gen` v5.1 IPs, one per divide site. Post-synth cell count was misleading because `fxDiv_core` was a blackbox.

---

## Known limitations

Historical note: the old Spartan-7 XC7S50 over-utilization is resolved for multi-date v1 at 12 ns. The current design routes at 72.54% LUT and passes 12 ns timing; it still does not meet 100 MHz without additional timing work.

- **Design over-utilizes Spartan-7 XC7S50** (2026-04-17): LUT logic at 113.9% and CARRY4 at 102.4% of the part. `impl_1` DRC stops the flow before placement. Root cause: 16 × `div_gen` v5.1 IPs. Path forward: larger part or divider time-sharing in `regression.sv`. See **Resource budget** section.
- **InverseCDF integration:** negate FIFO push is **`v1 && ln_ready`** (one push per fold→ln handshake). **`ln_raw` + `$signed(ln_raw)`** bridges the unsigned `fxlnLUT.result` port into signed math for `fxMul` / `fxSqrt`.
- **Synthesis glue:** `rv_skid_arr_gate` uses **signed** `s_data`/`m_data`; `accumulator` skid arrays are signed to match (fixes Vivado **Synth 8-659** vs `regression`).
- Default RTL remains single-exercise-date. Multi-exercise RTL is available only when compiled with `MULTI_EXERCISE=1`, supports `NUM_LANES=1` in v1, and has A7-100T plus S7-50 timing/resource signoff at 12 ns.
- Lane divisibility: `lat_N` must be divisible by `NUM_LANES`. No tail-batch handling yet.
- Q16.16 range: max representable value is about 32767. Stock prices above about $30K would overflow.
- Sobol quality: degrades above about 20-30 dimensions. Keep M <= 20 in practice.
- **Timing vs clock:** Routed timing is clean at **83.333 MHz** per XDC; **not** closed at **100 MHz** with current `FP_MUL_LATENCY=1` RTL (WNS ≈ −1.65 ns at 10 ns period in that configuration).
- **Verification:** RTL simulation + Vivado STA are the primary gates; virtual benchmark gives cycle-accurate wall time at the STA clock without requiring a board.
