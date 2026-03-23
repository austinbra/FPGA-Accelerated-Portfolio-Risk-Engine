# QMC-LSM-to-FPGA: Project Status

Last updated: 2026-03-22

## Current State

All pipeline modules are **complete and fully synthesizable**. No behavioral models remain. The design compiles, elaborates, and simulates clean under Vivado 2025.1.

**Numerical validation**: FPGA price = 6.553 vs C++ baseline = 6.50 (**0.8% relative error**) at N=64 paths. Error is within expected QMC variance.

## What's Done (Phases 1-13)

| Phase | Description | Status |
|-------|-------------|--------|
| 1 | Signed ExpLUT (8192 entries, x in [-1,1]) | Done |
| 2 | Pre-compute GBM constants (drift, vol_sqrt_dt) | Done |
| 3 | GBM streaming pipeline (MUL->EXP->MUL, ~5 cyc) | Done |
| 4 | Fully pipelined top-level (fire step k+1 same cycle as GBM output) | Done |
| 5 | Accumulator stall diagnosis (ACC_DEBUG traces) | Done |
| 6 | Host running modes (benchmark + live via uart_host.py) | Done |
| 7 | Numerical debugging (8 bugs, 842% -> 0.8% error) | Done |
| 8 | Cleanup and documentation | Done |
| 9 | D2: Richer error reporting (5-word result + status flags) | Done |
| 10 | Synthesizable math (fxLnLUT interpolation, fxSqrt digit-by-digit) | Done |
| 11 | Precision centralization (fpga_cfg_pkg constants + elaboration assertions) | Done |
| 12 | D3: Antithetic variates (paired z/-z paths, 2x effective N) | Done |
| 13 | D4: Convergence sweep mode (--mode sweep) | Done |

## Feature Summary

- **Pipeline**: Sobol -> InverseCDF -> GBM -> Accumulator -> Regression -> LSM Decision
- **Fixed-point**: Q16.16 (all constants from fpga_cfg_pkg.sv)
- **Memory**: O(1) via streaming accumulation (64 bytes, not O(N*M))
- **Antithetic variates**: Halves QMC variance by running z and -z per Sobol point
- **PUT/CALL**: Runtime flag via UART parameter
- **Error reporting**: Result packet includes timeout and singular-regression flags
- **Host modes**: benchmark (CPU vs FPGA), live (Yahoo Finance), sweep (convergence)
- **Elaboration assertions**: All precomputed constants verified against fp_from_real

## What's Next

### Priority 1: Lane Replication (D5)
- **What**: Instantiate NUM_LANES > 1 parallel pipelines (sobol->invCDF->GBM)
- **Where**: `src/top/top_option_pricer.sv` — generate blocks, sum merging
- **Impact**: Linear throughput scaling. With 33 DSP/lane and 120 available, max ~3 lanes.
- **Effort**: ~100-200 lines
- **Progress (2026-03-22)**:
  - Added D5 scaffolding in top-level (`NUM_LANES` parameter + centralized path->Sobol/antithetic mapping helpers + elaboration guard messages).
  - Implemented replicated lane RTL generation for Sobol/InverseCDF/GBM (`for`-generate over `NUM_LANES`) with active-lane signal muxing.
  - Added round-robin lane scheduler hook at path boundaries (training + decision passes).
  - Current limitation: scheduler still runs one active lane at a time; full concurrent lane feed/merge remains next.

### Priority 2: Multi-Exercise-Date Expansion
- **What**: Full backward induction with M-1 regression passes
- **Where**: `src/top/top_option_pricer.sv` — much more complex FSM
- **Impact**: True American option pricing (currently single exercise at step M-1)
- **Effort**: Major — per-step beta arrays, multiply compute time by M

### Priority 3: FPGA Hardware Test
- **What**: Generate bitstream for XC7S50, validate on board via UART
- **Where**: Vivado project setup, constraints file, uart_host.py
- **Impact**: Proves the design works on real hardware, measures actual fMAX

### Lower Priority
- Multi-batch UART regression (re-test `-Multibatch` after all fixes)
- Lane-aware accumulator merging (prerequisite for D5)
- Higher Sobol dimensions (quality vs dimension trade-off analysis)

## How to Build & Test

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

## Resource Budget (Spartan-7 XC7S50)

| Resource | Used | Available | Utilization |
|----------|------|-----------|-------------|
| DSP48E1 | ~33 | 120 | ~28% |
| BRAM36 | ~10-12 | 75 | ~16% |
| LUTs | TBD | ~32K | TBD |

## Known Limitations

- Single exercise date (step M-1 only, not full backward induction)
- Single pipeline lane (no parallelism across paths yet)
- Q16.16 max = 32767 (stock prices above ~$30K would overflow)
- Sobol quality degrades above 20-30 dimensions (keep M <= 20)
- Not yet tested on real FPGA hardware
