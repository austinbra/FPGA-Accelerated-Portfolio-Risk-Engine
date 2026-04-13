# QMC-LSM-to-FPGA — Roadmap

> **What's already built:** see [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md)
> **How to verify:** see [`VALIDATION.md`](VALIDATION.md)

Last updated: 2026-04-13

---

## Priority 1: Higher lane counts + throughput scaling

**Goal:** Confirm `NUM_LANES=4` and `NUM_LANES=8` produce bit-identical prices, then measure actual throughput improvement on the target FPGA.

**Where to look:**
- `src/top/top_option_pricer.sv` - `NUM_LANES` parameter, `gen_lane` generate block
- `tb/tb_top_option_pricer_uart.sv` - add `lanes4` and `lanes8` wrapper modules
- `scripts/run_tb_top_uart_safe.ps1` - `-NumLanes` dispatch

**Constraint:** `lat_N` must be divisible by `NUM_LANES`. Testbench params already satisfy this for powers of 2.

---

## Priority 2: FPGA hardware test

**Goal:** First on-board run. Validates that RTL synthesizes without timing violations and produces correct prices via real UART.

**Steps:**
1. Run Vivado synthesis + implementation for XC7S50
2. Check timing report: target fMAX >= 100 MHz
3. Program board, connect UART, run `python src/uart_host.py --mode benchmark --target fpga`
4. Compare hardware price vs simulation price

**Deliverable:** Confirmed fMAX, hardware-measured price, and compute-time speedup vs CPU baseline.

---

## Priority 3: Multi-exercise-date (full backward induction)

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
