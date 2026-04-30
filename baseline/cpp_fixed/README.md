# Fixed-Point C++ Baseline

This is the promoted CPU baseline used to compare against the FPGA SystemVerilog implementation.

## Purpose

- Numerical baseline for option price comparisons.
- CPU timing baseline for throughput/performance comparisons.
- Reference implementation for algorithm/debug sanity checks.

## Build and run (PowerShell + g++)

```powershell
g++ -std=c++17 main.cpp pricing.cpp linalg.cpp rtl_math.cpp sobol_wrapper.cpp utils.cpp -o fixed_baseline
./fixed_baseline --paths 10000 --steps 50 --S0 100 --K 100 --r 0.05 --sigma 0.2 --T 1.0 --put
```

### RTL mirror inputs

The default `--fpga-style` path is a bit-exact parity oracle for the RTL:
it reads the RTL Sobol `direction.mem`, starts at Sobol index 1, truncates
`sobol_out[31:16]`, applies the one-LSB lower guard for `u=0`, and mirrors
the RTL LUT/division/sqrt/inverse-CDF/GBM/regression/final-average math.
Use `--direction-file <path>` and `--lut-dir <path>` to point at explicit
generated `.mem` files.

### File-driven run

Input file format (`key=value`, one per line):

```text
paths=10000
steps=50
S0=100.0
K=100.0
r=0.05
sigma=0.2
T=1.0
option_type=1
# optional:
# direction_file=../../src/gen/direction.mem
# lut_dir=../../src/gen
```

Run:

```powershell
./fixed_baseline --input-file params.txt
```

Example file: `params_example.txt`

`option_type=0` selects a call and `option_type=1` selects a put. The default is
PUT so the early-exercise path is exercised in demos and validation. The default
pricing mode is `--fpga-style`, matching the current RTL single-exercise date at
`M-1`; use `--full-lsm` when you want the full backward-induction CPU model.
Use `--trace-numerical` for diagnostic-only raw Q16.16 stage tracing.

## Notes

- Sobol QMC is the production stream; pseudo-random and Boost Sobol are not the validation oracle.
- For FPGA speed comparison, use FPGA core cycle counts (exclude UART transfer time), then compare with CPU runtime from this baseline.
- Unified benchmark/live runner is `src/uart_host.py` with selectable target: `cpu`, `fpga`, or `both`.
