# Fixed-Point C++ Pricing Mirror

This directory contains the promoted CPU mirror for the FPGA pricing kernel. In the forked portfolio-risk project, this executable has two jobs:

- provide a bit-exact parity oracle for RTL,
- serve as the first pricing backend for portfolio, scenario, and Greeks tooling before a board is connected.

## Build

From this directory:

```powershell
g++ -std=c++17 main.cpp pricing.cpp linalg.cpp rtl_math.cpp sobol_wrapper.cpp utils.cpp -o fixed_baseline
```

From the repository root:

```powershell
cd baseline\cpp_fixed
g++ -std=c++17 main.cpp pricing.cpp linalg.cpp rtl_math.cpp sobol_wrapper.cpp utils.cpp -o fixed_baseline
cd ..\..
```

## Run The FPGA-Style Mirror

The `--fpga-style` path mirrors the RTL contract:

- reads the RTL Sobol `direction.mem`,
- starts at Sobol index 1,
- truncates `sobol_out[31:16]`,
- applies the one-LSB lower guard for `u=0`,
- mirrors the RTL LUT/division/sqrt/inverse-CDF/GBM/regression/final-average math.

Example:

```powershell
.\baseline\cpp_fixed\fixed_baseline.exe --paths 1024 --steps 12 --S0 100 --K 100 --r 0.05 --sigma 0.2 --T 1 --option-type 1 --fpga-style --exercise-mode multi --direction-file src\gen\direction.mem --lut-dir src\gen
```

Use:

- `--exercise-mode single` for historical single-date compatibility,
- `--exercise-mode multi` for the current American PUT kernel,
- `--option-type 0` for CALL,
- `--option-type 1` for PUT.

No-dividend CALLs use the terminal fast path while `q=0`.

## File-Driven Run

Input file format:

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
.\fixed_baseline.exe --input-file params.txt --fpga-style --exercise-mode multi
```

Example file: `params_example.txt`.

## Role In The Fork

The first product scripts should call this mirror before they call hardware. That lets portfolio parsing, scenario expansion, and Greek bump logic be tested without a connected board.

Planned consumers:

- `scripts/portfolio_price.py`,
- `scripts/scenario_sweep.py`,
- future bump/revalue Greek tooling.

For FPGA speed comparisons, use FPGA core cycle counts from `src/uart_host.py` and compare them with CPU wall time from this executable. Keep UART round-trip time separate from pricing-core time.
