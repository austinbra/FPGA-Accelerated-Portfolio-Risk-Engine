# Validation

How this repo is checked before merging RTL or host changes. Run from the repository root.

## Toolchain

Prerequisite: Vivado `xvlog` / `xelab` / `xsim` on `PATH` (or use Vivado batch mode where the scripts invoke `vivado`).

| Step | Command |
|------|---------|
| Compile SystemVerilog | `./scripts/run_xvlog_src.ps1` |
| Elaboration smoke (module snapshots) | `./scripts/run_xelab_smoke.ps1` |
| UART TB (timeout / smoke) | `./scripts/run_tb_top_uart_safe.ps1` |
| UART TB (full pricing run) | `./scripts/run_tb_top_uart_safe.ps1 -ComputeMode` |

Thin wrappers at repo root (`./run_xvlog_src.ps1`, `./run_xelab_smoke.ps1`) forward to the same `scripts/` implementations.

Optional log cleanup (repo root): `./scripts/cleanup_artifacts.ps1` — add `-IncludeSimDirs` to remove `xsim.dir` / `.Xil`.

## Numerical check (FPGA simulation vs C++ fixed-point)

1. Build the CPU baseline in `baseline/cpp_fixed/` (see that folder’s README or use `g++` on `main.cpp` and linked sources).
2. Run:

```bash
python scripts/validate_numerical.py
```

**Pass criterion (default case in script):** relative error between FPGA Q16.16 price and CPU double price ≤ **1%** for the bundled parameters (e.g. 64 paths, 12 steps).

## Elaboration note

Smoke elaboration may use `src/sim/fxDiv_core_stub.sv` when the generated `fxDiv_core` IP is not present in the simulation tree.

## Status pointer

What is implemented: `IMPLEMENTATION_STATUS.md`. Planned work: `ROADMAP.md`.
