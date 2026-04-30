# QMC-LSM-to-FPGA — Validation

> How to verify the design before merging RTL or host changes.

---

## Quick-run checklist

Default validation parameters are ATM PUT (`option_type=1`) so the early-exercise branch is exercised. The CPU reference runs in FPGA-style single-exercise mode to match the current RTL. Use `opt=0` / `option_type=0` explicitly when you want the historical non-dividend CALL smoke case.

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

# 6. Numerical diagnosis - first raw C++/RTL divergence
python scripts/diagnose_numerical.py --paths 4 --steps 4 --option-type 1
python scripts/diagnose_numerical.py --paths 8 --steps 12 --option-type 1
python scripts/diagnose_numerical.py --paths 64 --steps 12 --option-type 1
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
| Numerical | Historical CALL price within 1% of C++ baseline | Passing |
| Numerical | Default PUT price vs C++ FPGA-style baseline | Passing: bit-exact trace parity for `N=4/M=4`, `N=8/M=12`, and `N=64/M=12` |
| Multi-lane parity | `NUM_LANES=2` bit-identical to `NUM_LANES=1` | Passing |
| Multi-lane parity | `NUM_LANES=4` bit-identical to `NUM_LANES=1` | Passing |
| Multi-lane parity | `NUM_LANES=8` bit-identical to `NUM_LANES=1` | Passing |
| FPGA (optional hardware) | On-board UART price check vs simulation | Out of scope for default CI |

---

## Elaboration note

Smoke elaboration uses `src/sim/fxDiv_core_stub.sv` in place of the Xilinx `fxDiv_core` IP. The stub completes division in 1 simulation cycle while the real IP is deeper. The top-level FSM includes a `drain_cnt` cooldown guard to tolerate this in simulation.

---

## Numerical parity contract

Production validation uses Sobol QMC from `src/gen/direction.mem`, starts at Sobol index 1, and guards the lower boundary after RTL truncation (`sobol_out[31:16] == 0` feeds `u_q16 = 1`). The C++ `--fpga-style` baseline mirrors this stream and the RTL fixed-point LUT/division/sqrt/inverse-CDF/GBM/regression/final-average stages. `--full-lsm` remains a higher-level CPU model, not the hardware parity oracle.

Latest default PUT gate: C++ `0x0006A7A2`, RTL sim `0x0006A7A2`, Q16.16 delta `0` LSB.

---

## Toolchain prerequisite

Vivado with `xvlog`, `xelab`, and `xsim` on `PATH`. C++ baseline requires `g++` with C++17.
