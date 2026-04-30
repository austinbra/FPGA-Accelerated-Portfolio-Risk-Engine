# QMC-LSM-to-FPGA — Implementation Status

> **Where we are:** All pipeline modules complete and fully synthesizable. Default PUT C++/RTL numerical parity is bit-exact through the diagnosis ladder (`N=4/M=4`, `N=8/M=12`, `N=64/M=12`) using the production Sobol QMC stream and RTL fixed-point mirror. Multi-lane (`NUM_LANES` 1/2/4/8) was previously verified bit-identical in simulation. **Arty A7-100T** place/route meets timing at the **83.333 MHz** constraint (12 ns `sys_clk` in XDC). **Arty A7-35T** does **not** fit (LUT logic over the part budget). Primary performance story: RTL + STA-scaled cycles (`run_virtual_a7_benchmark.ps1` / `--target virtual`). Next: Plan B or fewer lanes for 35T, or re-pipeline multiply if you must close **100 MHz** again.

Last updated: 2026-04-28

---

## What's implemented

| # | Feature | Status |
|---|---------|--------|
| 1 | Sobol QMC sequence generator (Gray-coded, deterministic) | Done |
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

---

## Current validated price

| Config | Q16.16 hex | Float approx | vs C++ baseline |
|--------|-----------|--------------|----------------|
| Default PUT, `N=64`, `M=12`, `NUM_LANES=1` | `0x0006a7a2` | approx 6.65482 | bit-exact C++/RTL trace parity |
| Diagnostic PUT, `N=8`, `M=12`, `NUM_LANES=1` | trace-only | trace-only | bit-exact C++/RTL trace parity |
| Diagnostic PUT, `N=4`, `M=4`, `NUM_LANES=1` | trace-only | trace-only | bit-exact C++/RTL trace parity |

Parameters used for the default price table: N=64 paths, M=12 steps, S0=K=100, r=0.05, sigma=0.2, T=1.0, PUT. The production Sobol contract is RTL `direction.mem`, Sobol index starts at 1, and `sobol_out[31:16] == 0` is remapped to `u_q16 = 1` before inverse-CDF. The C++ comparison mode defaults to the current RTL's single exercise date at `M-1`; `--full-lsm` remains a higher-level CPU model, not the hardware parity oracle.

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
| Medium | **If 100 MHz STA is required** without relaxing XDC: re-implement `fxMul` pipelining with a **proven** sim/UART handshake (avoid the deadlocked variant). | Medium |
| Medium | Multi-exercise-date expansion (full backward induction, multiple regression passes). | High |
| Medium | Financial accuracy study against high-precision references/control variates after bit-exact hardware parity. | Medium |
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

# 9. Arty S7-50 synthesis / bitstream (hardware prep)
# See FPGA_BUILD.md — e.g. synth-only: set VIVADO_SYNTH_ONLY=1 then run_vivado_build_arty_s7.ps1 -SynthOnly
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

### Pre-Plan-A baseline (2026-04-17, S7-50, do-not-fit regression)

`impl_1` DRC `UTLZ-1` before `place_design`:
- LUT as Logic 37,141 / 32,600 (113.9% — overfit)
- CARRY4 8,344 / 8,150 (102.4% — overfit)
- 16 × `div_gen` v5.1 IPs, one per divide site. Post-synth cell count was misleading because `fxDiv_core` was a blackbox.

---

## Known limitations

- **Design over-utilizes Spartan-7 XC7S50** (2026-04-17): LUT logic at 113.9% and CARRY4 at 102.4% of the part. `impl_1` DRC stops the flow before placement. Root cause: 16 × `div_gen` v5.1 IPs. Path forward: larger part or divider time-sharing in `regression.sv`. See **Resource budget** section.
- **InverseCDF integration:** negate FIFO push is **`v1 && ln_ready`** (one push per fold→ln handshake). **`ln_raw` + `$signed(ln_raw)`** bridges the unsigned `fxlnLUT.result` port into signed math for `fxMul` / `fxSqrt`.
- **Synthesis glue:** `rv_skid_arr_gate` uses **signed** `s_data`/`m_data`; `accumulator` skid arrays are signed to match (fixes Vivado **Synth 8-659** vs `regression`).
- Single exercise date: checks exercise at step M-1 only. Full backward induction (M-1 passes) is future work.
- Lane divisibility: `lat_N` must be divisible by `NUM_LANES`. No tail-batch handling yet.
- Q16.16 range: max representable value is about 32767. Stock prices above about $30K would overflow.
- Sobol quality: degrades above about 20-30 dimensions. Keep M <= 20 in practice.
- **Timing vs clock:** Routed timing is clean at **83.333 MHz** per XDC; **not** closed at **100 MHz** with current `FP_MUL_LATENCY=1` RTL (WNS ≈ −1.65 ns at 10 ns period in that configuration).
- **Verification:** RTL simulation + Vivado STA are the primary gates; virtual benchmark gives cycle-accurate wall time at the STA clock without requiring a board.
