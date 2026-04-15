# QMC-LSM-to-FPGA — Validation

> How to verify the design before merging RTL or host changes.

---

## Quick-run checklist

```powershell
# 1. Compile all RTL
./scripts/run_xvlog_src.ps1

# 2. Elaboration smoke
./scripts/run_xelab_smoke.ps1

# 3. UART TB - timeout path
./scripts/run_tb_top_uart_safe.ps1

# 4. UART TB - full pricing run, single lane
./scripts/run_tb_top_uart_safe.ps1 -ComputeMode

# 5. Numerical gate - FPGA sim vs C++ baseline
python scripts/validate_numerical.py
```

Optional cleanup:

```powershell
./scripts/cleanup_artifacts.ps1 -IncludeSimDirs
```

---

## Multi-lane checks

```powershell
# Two-lane parity
./scripts/run_tb_top_uart_safe.ps1 -ComputeMode -NumLanes 2

# Higher-lane spot checks
./scripts/run_tb_top_uart_safe.ps1 -ComputeMode -NumLanes 3
./scripts/run_tb_top_uart_safe.ps1 -ComputeMode -NumLanes 4
./scripts/run_tb_top_uart_safe.ps1 -ComputeMode -NumLanes 8
```

**Constraint:** `lat_N` must be divisible by `NUM_LANES`.

---

## Gate criteria

| Gate | Criterion | Status |
|------|-----------|--------|
| RTL compile | 0 errors from `xvlog` | Passing |
| Elaboration | 0 errors from `xelab` | Passing |
| Numerical | FPGA price within 1% of C++ baseline | Passing |
| Multi-lane parity | `NUM_LANES=2` bit-identical to `NUM_LANES=1` | Passing |
| Multi-lane parity | `NUM_LANES=4` bit-identical to `NUM_LANES=1` | Passing |
| Multi-lane parity | `NUM_LANES=8` bit-identical to `NUM_LANES=1` | Passing |
| FPGA hardware | On-board price matches simulation | Not yet run |

---

## Elaboration note

Smoke elaboration uses `src/sim/fxDiv_core_stub.sv` in place of the Xilinx `fxDiv_core` IP. The stub completes division in 1 simulation cycle while the real IP is deeper. The top-level FSM includes a `drain_cnt` cooldown guard to tolerate this in simulation.

---

## Toolchain prerequisite

Vivado with `xvlog`, `xelab`, and `xsim` on `PATH`. C++ baseline requires `g++` with C++17.
