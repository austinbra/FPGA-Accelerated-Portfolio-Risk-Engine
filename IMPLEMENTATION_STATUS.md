# QMC-LSM-to-FPGA: Implementation status

High-level snapshot of **what the repo implements today** (features, validation, limits).

**Planned work and priorities:** [`ROADMAP.md`](ROADMAP.md) (stable, repo-local).

**What to do *this session*:** [`.cursor/rules/primer.md`](.cursor/rules/primer.md) (short handoff; may live only in your Cursor workspace).

Last updated: 2026-03-26

## Current state

All pipeline modules are **complete and fully synthesizable**. No behavioral models remain. The design compiles, elaborates, and simulates clean under Vivado 2025.1.

**Numerical validation**: FPGA price vs C++ baseline about **0.79–0.8% relative error** at N=64 paths (within expected QMC variance; gate is ≤1% in `scripts/validate_numerical.py`).

## What's implemented (Phases 1–13)

| Phase | Description | Status |
|-------|-------------|--------|
| 1 | Signed ExpLUT (8192 entries, x in [-1,1]) | Done |
| 2 | Pre-compute GBM constants (drift, vol_sqrt_dt) | Done |
| 3 | GBM streaming pipeline (MUL->EXP->MUL, ~5 cyc) | Done |
| 4 | Fully pipelined top-level (fire step k+1 same cycle as GBM output) | Done |
| 5 | Accumulator stall diagnosis (ACC_DEBUG traces) | Done |
| 6 | Host running modes (benchmark + live via uart_host.py) | Done |
| 7 | Numerical debugging (8 bugs, 842% -> ~0.8% error) | Done |
| 8 | Cleanup and documentation | Done |
| 9 | D2: Richer error reporting (5-word result + status flags) | Done |
| 10 | Synthesizable math (fxLnLUT interpolation, fxSqrt digit-by-digit) | Done |
| 11 | Precision centralization (fpga_cfg_pkg constants + elaboration assertions) | Done |
| 12 | D3: Antithetic variates (paired z/-z paths, 2x effective N) | Done |
| 13 | D4: Convergence sweep mode (--mode sweep) | Done |

## Feature summary

- **Pipeline**: Sobol → InverseCDF → GBM → Accumulator → Regression → LSM Decision
- **Fixed-point**: Q16.16 (all constants from fpga_cfg_pkg.sv)
- **Memory**: O(1) via streaming accumulation (64 bytes, not O(N*M))
- **Antithetic variates**: Halves QMC variance by running z and -z per Sobol point
- **PUT/CALL**: Runtime flag via UART parameter
- **Error reporting**: Result packet includes timeout and singular-regression flags
- **Host modes**: benchmark (CPU vs FPGA), live (Yahoo Finance), sweep (convergence)
- **Elaboration assertions**: All precomputed constants verified against fp_from_real

## D5 (in progress): lane replication scaffolding

- Top exposes `NUM_LANES` (default **1**). **Replicated** Sobol → InvCDF → GBM exists; FSM still effectively schedules **lane 0** only until multi-lane scheduling lands (see `ROADMAP.md`).

## How to build and test

```powershell
# Compile
./scripts/run_xvlog_src.ps1

# Elaborate (9 module snapshots)
./scripts/run_xelab_smoke.ps1

# Simulate (timeout mode)
./scripts/run_tb_top_uart_safe.ps1

# Simulate (compute mode, real pricing)
./scripts/run_tb_top_uart_safe.ps1 -ComputeMode

# Numerical validation (C++ vs FPGA)
python scripts/validate_numerical.py

# CPU convergence sweep
python src/uart_host.py --mode sweep --target cpu --param-file baseline/cpp_fixed/params_example.txt
```

## Resource budget (Spartan-7 XC7S50)

| Resource | Used | Available | Utilization |
|----------|------|-----------|-------------|
| DSP48E1 | ~33 | 120 | ~28% |
| BRAM36 | ~10-12 | 75 | ~16% |
| LUTs | TBD | ~32K | TBD |

## Known limitations

- Single exercise date (step M-1 only, not full backward induction)
- **Throughput:** `NUM_LANES=1` from the FSM’s point of view until D5 scheduling completes (hardware may already instantiate multiple lanes tied off)
- Q16.16 max = 32767 (stock prices above ~$30K would overflow)
- Sobol quality degrades above 20-30 dimensions (keep M <= 20)
- Not yet tested on real FPGA hardware
