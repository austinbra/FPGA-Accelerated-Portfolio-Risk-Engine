# QMC-LSM-to-FPGA — Roadmap

> **What's already built:** see [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md)
> **How to verify:** see [`VALIDATION.md`](VALIDATION.md)

Last updated: 2026-04-19

---

## Completed: Arty A7-100T timing at **83.333 MHz** (STA)

**Done:** `constraints/arty_a7_100.xdc` constrains `CLK100MHZ` as **12 ns** `sys_clk` (83.333 MHz). Post-route **`timing_post_route.rpt`**: WNS **+0.173 ns**, TNS **0**, **0** failing endpoints. **`utilization.rpt`**: ~**22.6k** slice LUTs, ~**27.4k** FFs. Bitstream **`vivado_build/arty_a7_100/arty_a7_qmc.bit`**.

**Learning:** Closing **100 MHz** required a pipelined **`fxMul`** variant (`FP_MUL_LATENCY=2`); that revision **broke** UART compute-mode simulation (timeout / `0xDEAD0001`). Repo is back to **`FP_MUL_LATENCY=1`** and sim price **`0x000b93cd`**. For 100 MHz without RTL risk, next attempt needs a handshake-correct multiply split.

**Not done:** **Arty A7-35T** — impl stops at **LUT over-utilization** (~24.8k logic LUTs needed vs ~20.8k available). Needs Plan B (more divider sharing) or smaller configuration.

---

## Completed: Multi-lane simulation

**Done:** `NUM_LANES=4` and `NUM_LANES=8` produce the same Q16.16 price as `NUM_LANES=1` (`0x000b93cd` with default TB params). Wrappers: `tb_top_option_pricer_uart_compute_lanes4` / `_lanes8`; run `./scripts/run_tb_top_uart_safe.ps1 -ComputeMode -NumLanes 4|8`.

**Throughput:** Lane scaling for wall time is characterized with **RTL simulation + STA-scaled cycles** (`run_virtual_a7_benchmark.ps1`). On-board lane vs fMAX sweeps are optional when hardware is available.

**Constraint:** `lat_N` must be divisible by `NUM_LANES`.

---

## Priority 1: Arty A7-100T implementation + verification — **done (STA + RTL)**

**Goal:** Bitstream + timing closure at the XDC clock target; reproducible performance numbers from RTL aligned with post-route STA.

**Done (checklist):**
1. Full build: `.\scripts\run_vivado_build_arty_a7.ps1 -TimeoutSeconds 14400`
2. `vivado_build/arty_a7_100/timing_post_route.rpt`: WNS ≥ 0 for `sys_clk` (**12 ns** → **83.333 MHz** in current `constraints/arty_a7_100.xdc`).
3. Bitstream path: `vivado_build/arty_a7_100/arty_a7_qmc.bit` (after successful impl).

**Throughput / benchmark (no board required):** `.\scripts\run_virtual_a7_benchmark.ps1` or `python src/uart_host.py --mode benchmark --target virtual --param-file …` — DUT `core_cycles` from xsim × **1/fclk** (STA target). See [`FPGA_BUILD.md`](FPGA_BUILD.md).

**Optional on hardware:** Program the A7-100T and run `uart_host.py --target fpga` the same way as in [`FPGA_BUILD.md`](FPGA_BUILD.md) when you want USB-UART confirmation on silicon.

**Arty S7-50 (legacy / smaller part):** see [`FPGA_BUILD.md`](FPGA_BUILD.md) — `scripts/run_vivado_build_arty_s7.ps1`. Pre–Plan-A impl did not fit; re-try only after confirming resource goals.

---

## Priority 2: Multi-exercise-date (full backward induction)

**Goal:** American option with M-1 exercise opportunities, not just step M-1.

**What changes:**
- Top FSM gains M-1 training passes, one per exercise date, stepping backward
- Per-step beta arrays (M-1 x 3 coefficients) need BRAM storage
- `lsm_decision` runs at each step with the relevant beta row

**Effort:** High. This is the largest remaining architectural change.

---

## Lower priority

- Multi-batch UART stability (`-Multibatch` flag)
- Lane-aware accumulator merging at higher lane counts
- Sobol dimension analysis vs pricing quality as M rises
