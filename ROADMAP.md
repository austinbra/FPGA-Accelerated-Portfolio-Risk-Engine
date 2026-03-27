# QMC-LSM-to-FPGA: Roadmap

Forward-looking **priorities** and **next engineering steps**. For **what is already implemented**, see [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md).

For **immediate session tasks** (“what we’re doing right now”), see [`.cursor/rules/primer.md`](.cursor/rules/primer.md) if you use Cursor (often not committed).

Last updated: 2026-03-26

## Priority 1: Lane replication (D5)

- **Goal:** `NUM_LANES > 1` with correct path scheduling and merged results; linear datapath throughput scaling where DSP allows (~3 lanes on XC7S50-class parts).
- **Where:** `src/top/top_option_pricer.sv` — multi-lane FSM scheduling on top of existing generate block / per-lane state.
- **Policy:** Land in **small steps**; after each RTL change run `scripts/run_xvlog_src.ps1`, `scripts/run_xelab_smoke.ps1`, TB with `-ComputeMode` as needed, and `python scripts/validate_numerical.py` (≤1% relative error). Bisect breaks before stacking features.
- **Context:** A prior large D5 change caused a major numerical regression; baseline was restored; re-introduce scheduling incrementally.

## Priority 2: Multi-exercise-date expansion

- **Goal:** Full backward induction (multiple regression passes / exercise opportunities).
- **Where:** Top FSM and storage for per-step betas — large control and compute-time growth vs today’s single exercise step.

## Priority 3: FPGA hardware test

- **Goal:** Bitstream for target board (e.g. XC7S50), constraints, on-board UART check, **fMAX** measurement.

## Lower priority

- Multi-batch UART regression (`-Multibatch`) after broader changes stabilize
- Lane-aware accumulator / result merging details as lane count rises
- Sobol dimension / quality trade-off analysis (keep M moderate in practice)

## Verification quick reference

See [`VALIDATION.md`](VALIDATION.md) in the repo root for commands and the numerical gate.
