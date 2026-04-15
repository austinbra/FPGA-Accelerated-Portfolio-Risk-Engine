# QMC-LSM-to-FPGA — Roadmap

> **What's already built:** see [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md)
> **How to verify:** see [`VALIDATION.md`](VALIDATION.md)

Last updated: 2026-04-15

---

## Completed: Priority 1 — Higher lane counts (simulation)

**Done:** `NUM_LANES=4` and `NUM_LANES=8` produce the same Q16.16 price as `NUM_LANES=1` (`0x000b93cd` with default TB params). Wrappers: `tb_top_option_pricer_uart_compute_lanes4` / `_lanes8`; run `./scripts/run_tb_top_uart_safe.ps1 -ComputeMode -NumLanes 4|8`.

**Deferred to silicon:** Actual throughput / fMAX vs lane count — measure on-board under **Priority 1** (FPGA hardware test).

**Constraint:** `lat_N` must be divisible by `NUM_LANES`.

---

## Priority 1: FPGA hardware test

**Goal:** First on-board run. Validates that RTL synthesizes without timing violations and produces correct prices via real UART.

**Steps:**
1. Run Vivado synthesis + implementation for XC7S50
2. Check timing report: target fMAX >= 100 MHz
3. Program board, connect UART, run `python src/uart_host.py --mode benchmark --target fpga`
4. Compare hardware price vs simulation price

**Deliverable:** Confirmed fMAX, hardware-measured price, and compute-time speedup vs CPU baseline.

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
