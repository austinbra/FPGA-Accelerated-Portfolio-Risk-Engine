# QMC-LSM-to-FPGA — Implementation Status

> **Where we are:** All pipeline modules complete and fully synthesizable. Multi-lane (`NUM_LANES` 1/2/4/8) verified bit-identical in simulation. Next: FPGA hardware test and throughput measurement on silicon.

Last updated: 2026-04-15

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
| 12 | Synthesizable fxLnLUT (3-stage pipeline + linear interpolation, no `$ln`) | Done |
| 13 | Synthesizable fxSqrt (non-restoring digit-by-digit, 25 cycles, no `$sqrt`) | Done |
| 14 | Precision centralization (all constants in `fpga_cfg_pkg.sv`, elaboration assertions) | Done |
| 15 | Multi-lane scheduling - `NUM_LANES > 1` (D5) | Done |
| 16 | Host: benchmark mode (CPU vs FPGA price + timing) | Done |
| 17 | Host: live mode (Yahoo Finance params) | Done |
| 18 | Host: convergence sweep (`--mode sweep`) | Done |

---

## Current validated price

| Config | Q16.16 hex | Float approx | vs C++ baseline |
|--------|-----------|--------------|----------------|
| `NUM_LANES=1` | `0x000b93cd` | approx 11.58 | within QMC variance |
| `NUM_LANES=2` | `0x000b93cd` | approx 11.58 | bit-identical |
| `NUM_LANES=4` | `0x000b93cd` | approx 11.58 | bit-identical |
| `NUM_LANES=8` | `0x000b93cd` | approx 11.58 | bit-identical |

Parameters used: N=64 paths, M=12 steps, S0=K=100, r=0.05, sigma=0.2, T=1.0, CALL

---

## What's next

| Priority | Work | Effort |
|----------|------|--------|
| High | FPGA hardware test - bitstream, on-board UART, fMAX + throughput vs `NUM_LANES` | Medium |
| Medium | Multi-exercise-date expansion (full backward induction, multiple regression passes) | High |
| Low | Multi-batch UART regression (`-Multibatch`) stability | Low |

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
```

Full validation procedure and gate criteria: [`VALIDATION.md`](VALIDATION.md)

---

## Resource budget (Spartan-7 XC7S50, estimated)

| Resource | Used | Available | Utilization |
|----------|------|-----------|-------------|
| DSP48E1 | ~33 | 120 | ~28% |
| BRAM36 | ~10-12 | 75 | ~16% |
| LUTs | TBD (post-synth) | ~32K | TBD |

---

## Known limitations

- Single exercise date: checks exercise at step M-1 only. Full backward induction (M-1 passes) is future work.
- Lane divisibility: `lat_N` must be divisible by `NUM_LANES`. No tail-batch handling yet.
- Q16.16 range: max representable value is about 32767. Stock prices above about $30K would overflow.
- Sobol quality: degrades above about 20-30 dimensions. Keep M <= 20 in practice.
- Not hardware-tested: all results are from Vivado behavioral simulation, not on-board.
