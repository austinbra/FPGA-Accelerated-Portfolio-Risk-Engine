# FPGA QMC‑LSMC American Option Pricer

## Overview
This project implements a **production‑grade, fully handshaked FPGA pipeline** for **American option pricing** using the **Longstaff–Schwartz Monte Carlo (LSMC)** method with **Quasi‑Monte Carlo (Sobol) sequences**.  
The design is proven in **Vivado** on **Digilent Arty A7-100T** (primary STA/bitstream target) and was originally sized for **Spartan‑7**; see [`.user/IMPLEMENTATION_STATUS.md`](.user/IMPLEMENTATION_STATUS.md) for utilization and clock targets.  

In addition to the FPGA implementation, the repository includes a **fixed‑point C++ baseline**:
- Located at `baseline/cpp_fixed/`.  
- Matches the FPGA-oriented fixed-point arithmetic flow for practical comparison.  

This allows direct comparison of **accuracy** and **performance** between CPU and FPGA implementations.

---

## Validation And Status
- Documentation index: [`.user/README.md`](.user/README.md)
- Validation: [`.user/VALIDATION.md`](.user/VALIDATION.md)
- Implementation snapshot: [`.user/IMPLEMENTATION_STATUS.md`](.user/IMPLEMENTATION_STATUS.md)
- Roadmap: [`.user/ROADMAP.md`](.user/ROADMAP.md)
- Current state: All pipeline stages fully synthesizable with ready/valid + skid buffers. Top-level two-pass LSMC engine with antithetic variates compiles/elaborates clean. Numerical validation achieved 0.8% relative error vs C++ baseline. D2 error reporting, D3 antithetic variates, D4 convergence sweep complete. D5 multi-lane (`NUM_LANES` 1/2/4/8) simulation parity verified bit-identical price. **Arty A7-100T** routed timing meets constraints at **83.333 MHz** (`sys_clk` 12 ns in XDC); **Arty A7-35T** does not fit LUT budget without further sharing.

---

## Features
- **Fully pipelined streaming datapath** with skid buffers at every stage boundary:  
  Sobol → Inverse CDF (Zelen–Severo rational approx) → GBM path simulation → Accumulator → Regression (Gaussian elimination) → LSM decision → UART output.  
  Multiple samples in-flight simultaneously; backpressure propagates through ready/valid handshaking without data loss.
- **Fixed‑point math** (default Q16.16) with LUT‑based exp, synthesizable **ln** (2-stage BRAM + `ln_lut_4096.mem`; regenerate with `scripts/gen_ln_lut_4096.py`) and **sqrt** (digit-by-digit restoring, 24 iterations + FSM), and moneyness normalization to prevent overflow. All modules fully synthesizable — no behavioral models.
- **Host running modes** (`src/uart_host.py`): **Benchmark** (CPU, FPGA, both, or **virtual** STA-scaled sim), **Live** (Yahoo Finance snapshot), **Sweep** (convergence vs path count `N`).
- **Antithetic variates** for variance reduction: paired z/−z paths double effective sample count with near-zero overhead.
- **O(1) memory via streaming accumulation**: No path storage required. Running 64‑bit sufficient statistics (8 sums) replace O(N×M) BRAM. Paths are regenerated deterministically (Sobol) for the decision pass — 2× compute, but constant memory regardless of N.
- **Lane replication ready**: top‑level parameter to scale throughput by instantiating multiple parallel pipelines.
- **Assertions** for handshake invariants and stall stability.
- **Fixed‑point C++ baseline** for validation and performance comparison.

---

## Architecture

The design is a **fully pipelined, streaming datapath** with ready/valid handshaking and skid buffers at every stage boundary. The top-level orchestrates two passes (training + decision) while the pipeline stages process data in parallel with overlapping execution.

- **Sobol generator**: Gray‑coded XOR tree with BRAM‑stored direction numbers. Skid-buffered output.
- **Inverse CDF** (~15 cycles):  
  - Fold U(0,1) to (0,0.5] with negate flag (event-alignment FIFO for negate, combinational read).
  - ln (2-stage BRAM LUT) + multiply by −2 + sqrt (digit-by-digit restoring, 24 `COMP` cycles) → t.
  - Zelen–Severo rational polynomial (precomputed Q16.16 constants, elaboration-verified) → z‑score.  
- **GBM step** (~5 cycles, streaming pipeline with input skid buffer):  
  MUL1(vol_sqrt_dt × z) → ADD + saturate → EXP(signed LUT) → MUL2(S × exp).  
  Pre-computed constants (`drift_const`, `vol_sqrt_dt`) eliminate per-sample sqrt/mul overhead.
- **Accumulator** (O(1) memory, no path storage):  
  Collects 8 running sufficient statistics [Σ1, ΣS, ΣS², ΣS³, ΣS⁴, Σy, ΣSy, ΣS²y] in 64‑bit registers using moneyness-normalized inputs (S/K ≈ 1.0) to prevent Q16.16 overflow. Paths are consumed and reduced immediately — no N‑sized buffer exists anywhere.
- **Regression**: Deeply pipelined Gaussian elimination with pivoting; fallback to mean payoff if singular.  
- **LSM decision**: Chooses between immediate exercise payoff and regression-estimated continuation value. Uses moneyness (S/K) for the continuation polynomial to keep inputs in Q16.16 range. Supports PUT/CALL via `option_type` flag.  
- **UART interface**: Streams results to host. Result packet: marker `0xABCD0002` + price + cycle count (lo/hi) + status flags (timeout, singular regression).

---

## Baselines (C++)
- **Fixed‑point baseline** (`baseline/cpp_fixed/`):  
  - Implements a fixed-point workflow aligned with the FPGA-oriented arithmetic path.  
  - Validates numerical behavior and supports CPU timing comparisons.  
  - **How to build and run** the baseline (standalone, via Python, and against sim/hardware) is documented under [Build & Run](#build--run) → *C++ baseline (software)* and the tables that follow.  

---

## Build & Run

### Prerequisites
- **Vivado** on `PATH` (`xvlog`, `xelab`, `xsim`, and `vivado` for batch builds)—e.g. “Vivado 20xx Tcl Shell” or after `settings64.bat` / `settings64.sh`.
- **Python 3** for `src/uart_host.py` and `scripts/validate_numerical.py`. Install **`pyserial`** for on-board UART (`pip install pyserial`). **`yfinance`** is only needed for `--mode live` (`pip install yfinance`).
- **C++17 compiler**: `uart_host.py --build-cpu` invokes `g++` from `PATH`. On Windows you can build manually with MinGW/MSYS `g++` or WSL and rely on a pre-built `fixed_baseline.exe`.

Bitstream flows, board variants, and clock notes: [`.user/FPGA_BUILD.md`](.user/FPGA_BUILD.md). Detailed sim gates: [`.user/VALIDATION.md`](.user/VALIDATION.md).

### FPGA (Vivado) — RTL compile, elaborate, simulate

**Quick compile / simulate:**
```powershell
./scripts/run_xvlog_src.ps1          # Compile (vivado -mode batch)
./scripts/run_xelab_smoke.ps1       # Elaborate
./scripts/run_tb_top_uart_safe.ps1  # Simulate (timeout / smoke path)
./scripts/run_tb_top_uart_safe.ps1 -ComputeMode  # Full UART batch pricing in simulation
```

Root-level `./run_xvlog_src.ps1` and `./run_xelab_smoke.ps1` are thin wrappers into `scripts/`.

**Multi-lane TB** (paths must divide `NUM_LANES`): e.g. `./scripts/run_tb_top_uart_safe.ps1 -ComputeMode -NumLanes 2` (see [`.user/VALIDATION.md`](.user/VALIDATION.md)).

If scripts time out, confirm Vivado is on `PATH`, or run:
```bash
vivado -mode batch -source scripts/run_xvlog.tcl
```

### C++ baseline (software)

**Build once** (from `baseline/cpp_fixed/`):
```bash
cd baseline/cpp_fixed
g++ -std=c++17 main.cpp pricing.cpp linalg.cpp sobol_wrapper.cpp utils.cpp -o fixed_baseline
```
On Windows the artifact may be `fixed_baseline.exe`; `uart_host.py` accepts either name.

**Run standalone** (arguments mirror the `key=value` param file):
```bash
./fixed_baseline --paths 10000 --steps 50 --S0 100 --K 100 --r 0.05 --sigma 0.2 --T 1.0
```
Invalid flags print a usage summary. You can pass **`--input-file path/to/params.txt`**: the loader reads only **`paths`**, **`steps`**, **`S0`**, **`K`**, **`r`**, **`sigma`**, and **`T`** (see `baseline/cpp_fixed/utils.cpp`). Extra keys such as **`option_type` are ignored** by the C++ binary, and this baseline follows a **fixed call-style** payoff path (it does not mirror PUT/CALL switching the way the FPGA UART batch does).

**Run via Python host** (same params as a shared file, optional compile):
```bash
python src/uart_host.py --mode benchmark --target cpu --param-file baseline/cpp_fixed/params_example.txt --build-cpu
```

Optional Boost Sobol: `--use-boost --boost-include <path>`.

### Simulated FPGA — “virtual” Arty A7-100T benchmark (no hardware)

This path runs the **same UART compute testbench** as silicon, reads the DUT **`core_cycles`** counter from the log, and estimates FPGA compute time as `core_cycles / fclk` using the **post-route STA** target (default **83.333 MHz** for A7-100T; override with `-FclkHz`). It then runs the **C++ baseline** with the same `--param-file` and prints price delta and estimated speedup. RTL still runs at the TB clock; only the reported seconds use the STA frequency—see comments in the script for publishing semantics.

**PowerShell (recommended on Windows):**
```powershell
.\scripts\run_virtual_a7_benchmark.ps1 -ParamFile baseline\cpp_fixed\params_example.txt -NumLanes 1
# Slides / reports: UART-shaped block plus mandatory provenance line
.\scripts\run_virtual_a7_benchmark.ps1 -ParamFile baseline\cpp_fixed\params_example.txt -ReportFormat UartShaped
```

**Cross-invocation from Python** (subprocess uses the **`powershell`** executable, same as `validate_numerical.py`):
```bash
python src/uart_host.py --mode benchmark --target virtual --param-file baseline/cpp_fixed/params_example.txt --num-lanes 1 --fpga-fclk-hz 83333333.333333333
```
On platforms where only **`pwsh`** is installed, use the `.ps1` entry point above or ensure `powershell` resolves to PowerShell Core.

Useful flags on the script: `-NumLanes`, `-FclkHz`, `-XsimTimeoutSeconds`, `-TimingReport`, `-UtilReport`.

### Hardware — Arty A7-100T program and UART benchmark

1. **Generate a bitstream** (long run; tune `-TimeoutSeconds` as needed):
   ```powershell
   .\scripts\run_vivado_build_arty_a7.ps1 -TimeoutSeconds 14400
   ```
   Default bitstream: `vivado_build/arty_a7_100/arty_a7_qmc.bit` (see [`.user/FPGA_BUILD.md`](.user/FPGA_BUILD.md)).

2. **Program the board** (Vivado batch):
   ```powershell
   .\scripts\program_arty_a7.ps1
   ```
   Optional `-Bit <path\to\file.bit>`, `-TimeoutSeconds`.

3. **Benchmark on hardware** (auto-picks `COM` if exactly one port; otherwise pass `-Port`):
   ```powershell
   .\scripts\run_fpga_benchmark.ps1 -ParamFile baseline\cpp_fixed\params_example.txt
   ```
   This programs the A7-100T (unless `-SkipProgram`), then runs `uart_host.py --mode benchmark` with `--target both` by default, or `--target fpga` if `-SkipCpu`. Use `-FclkHz` to match your implemented `sys_clk` when interpreting speedup. `-BuildCpu` forwards `--build-cpu` to the host.

**Manual UART flow** (FPGA only, or custom port/baud):
```bash
python src/uart_host.py --mode benchmark --target fpga --param-file baseline/cpp_fixed/params_example.txt --port COM4 --baud 115200 --fpga-fclk-hz 83333333
```

### Host modes summary (`src/uart_host.py`)

| Mode | Typical `--target` | Command / notes |
|------|-------------------|-----------------|
| **Benchmark** | `cpu`, `fpga`, `both`, or `virtual` | Same `paths/steps/...` from `--param-file`. For **hardware speedup**, use `--target both` and set **`--fpga-fclk-hz`** to your core frequency so the host can convert `core_cycles` to seconds and print **CPU wall / FPGA compute** and **speedup**. |
| **Live** | `fpga` | `python src/uart_host.py --mode live --target fpga` — Yahoo Finance snapshot (`--symbol`, `--strike`, `--r`, `--maturity`). Requires `yfinance`. |
| **Sweep** | `cpu`, `fpga`, or `both` | `python src/uart_host.py --mode sweep --target cpu --param-file baseline/cpp_fixed/params_example.txt` — convergence vs path count `N` (override list with `--sweep-n`). |

Examples:
```bash
# CPU + FPGA on the board, full comparison block at end
python src/uart_host.py --mode benchmark --target both --param-file baseline/cpp_fixed/params_example.txt --port COM4 --fpga-fclk-hz 83333333 --build-cpu

# FPGA only (build C++ yourself if you want a local CPU reference)
python src/uart_host.py --mode benchmark --target fpga --param-file baseline/cpp_fixed/params_example.txt --port COM4 --fpga-fclk-hz 83333333
```

### Comparing benchmarks

| What you compare | How | What to look at |
|------------------|-----|------------------|
| **CPU vs FPGA (hardware)** | `--mode benchmark --target both` or `scripts/run_fpga_benchmark.ps1` | Final **BENCHMARK COMPARISON**: prices, **rel_err**, **CPU wall time**, **FPGA compute time** (`core_cycles / fpga_fclk`), **speedup** (UART round-trip is printed separately and is *not* the compute timer). |
| **CPU vs “FPGA” in sim (STA-scaled)** | `scripts/run_virtual_a7_benchmark.ps1` or `--target virtual` | Script summary: price delta, Q16 line when applicable, **Speedup est** from CPU wall vs scaled sim cycles. Read the **Provenance** / note about TB clock vs STA `fclk`. |
| **Gate: sim price vs C++ (fixed TB params)** | Build C++ binary, then from repo root: `python scripts/validate_numerical.py` | Runs a **fixed** small case (64 paths, 12 steps—see script) through **xsim** and C++; expects **≤ 1%** relative error. |

For day-to-day RTL confidence, follow the checklist in [`.user/VALIDATION.md`](.user/VALIDATION.md).

### Other configurations you may need

- **Param file** (`--param-file`): `paths`, `steps`, `S0`, `K`, `r`, `sigma`, `T`; optional **`option_type`** (`0` = CALL, `1` = PUT) for **`uart_host.py` / UART → FPGA** (and the virtual benchmark, which forwards those fields into RTL plusargs). The **C++** `fixed_baseline` does **not** read `option_type`; for apples-to-apples price checks against the CPU baseline, use **CALL** (`0`) or compare only where that matches the C++ model.
- **`NUM_LANES` / `-NumLanes`**: `paths` must be divisible by lane count; `lat_N` divisibility rules apply in RTL (see VALIDATION).
- **Board / build**: Primary **Arty A7-100T**; **A7-35T** script exists but may not meet LUTs without a smaller config. **Arty S7-50** flow and `fxDiv` IP are documented in [`.user/FPGA_BUILD.md`](.user/FPGA_BUILD.md) (`run_vivado_build_arty_s7.ps1`, synth-only env `VIVADO_SYNTH_ONLY`).
- **UART**: `--port`, `--baud`, `--timeout` on `uart_host.py`.
- **Long builds/sims**: Pass `-TimeoutSeconds` / `-XsimTimeoutSeconds` on the PowerShell drivers where supported.

**Arty S7-50 quick synthesis check** (`-SynthOnly` sets `VIVADO_SYNTH_ONLY` inside the driver; clear the env afterward if you run other flows in the same shell):
```powershell
.\scripts\run_vivado_build_arty_s7.ps1 -SynthOnly
Remove-Item Env:VIVADO_SYNTH_ONLY -ErrorAction SilentlyContinue
```
Full S7 place/route + bitstream: `.\scripts\run_vivado_build_arty_s7.ps1` (optional `-TimeoutSeconds`).

**Numerical validation** (run from **repository root**; builds on the same `run_tb_top_uart_safe.ps1 -ComputeMode` flow as [`.user/VALIDATION.md`](.user/VALIDATION.md)):
```bash
cd baseline/cpp_fixed && g++ -std=c++17 main.cpp pricing.cpp linalg.cpp sobol_wrapper.cpp utils.cpp -o fixed_baseline && cd ../..
python scripts/validate_numerical.py
```
`validate_numerical.py` invokes **`powershell`** to drive the Vivado tools (as on Windows). On Linux or macOS you typically need **PowerShell Core** available as `powershell`, or run the checklist commands yourself instead of this script.

### Current status
- Top-level two-pass LSMC engine compiles and elaborates clean. **All modules fully synthesizable.**
- **Numerical validation passed**: FPGA price = 6.553 vs C++ baseline = 6.50 (**0.8% relative error**).
- 8 numerical bugs fixed in Phase 7 (see [`.user/VALIDATION.md`](.user/VALIDATION.md) for details).
- PUT/CALL runtime flag implemented (D1 complete).
- Phase 4 complete: FSM fires Sobol for step k+1 in the same cycle GBM outputs step k.
- Phase 6 complete: benchmark + live + sweep host modes in `uart_host.py`.
- **D2 complete**: 5-word result packet with status flags (timeout, singular regression).
- **D3 complete**: Antithetic variates (paired z/−z paths) double effective path count.
- **D4 complete**: Convergence sweep mode for empirical QMC convergence analysis.
- **Precision centralization**: All FP constants from `fpga_cfg_pkg.sv`; elaboration assertions verify precomputed values.
- Next: FPGA hardware testing (throughput vs `NUM_LANES` on silicon), multi-exercise-date expansion.

---

## Testing
- **Unit testbenches** for Sobol, inverse CDF, GBM, accumulator, and regression.  
- **Assertions** check handshake invariants and stall stability.  
- **C++ vs FPGA comparison**:  
  - Run both baselines and FPGA simulation with the same seeds/parameters.  
  - Compare option prices and timing.  
  - Expect <1% relative error (well within Monte Carlo variance).  

---

## Roadmap
- [x] Fixed‑point math library (fxMul, fxDiv, fxExpLUT, fxLnLUT, fxSqrt) with skid buffers.
- [x] Sobol generator (Gray-coded XOR tree, skid-buffered output).
- [x] Inverse CDF (fold + Zelen–Severo, event-alignment FIFO for negate flag).
- [x] GBM streaming pipeline (MUL→EXP→MUL, input skid buffer, pre-computed constants).
- [x] Accumulator + Regression (64-bit sums, Gaussian elimination, fallback).
- [x] LSM decision (exercise vs continuation comparison).
- [x] C++ fixed‑point baseline (Q16.16, aligned with FPGA arithmetic).
- [x] Top‑level two-pass LSMC integration with UART I/O.
- [x] **Phase 4: Fully pipelined top-level** — fire Sobol for step k+1 in same cycle as GBM output.
- [x] Two running modes: benchmark (CPU vs FPGA comparison) + live (Yahoo Finance data).
- [x] PUT/CALL runtime flag (D1) — 1-bit option_type through UART, top-level, and lsm_decision.
- [x] **Numerical validation**: FPGA 6.553 vs C++ 6.50 = 0.8% error (8 bugs fixed in Phase 7).
- [x] Synthesizable fxSqrt (digit-by-digit restoring, 24 iterations; `FP_SQRT_LATENCY=24`; no DSP/BRAM).
- [x] Synthesizable fxlnLUT (2-stage BRAM + `$readmemh`; `scripts/gen_ln_lut_4096.py` for ROM data).
- [x] Richer error reporting (D2): 5-word result packet with timeout/singular status flags.
- [x] Precision centralization: all FP constants from `fpga_cfg_pkg.sv` with elaboration assertions.
- [x] Antithetic variates (D3): paired z/−z paths double effective N for variance reduction.
- [x] Convergence sweep mode (D4): `--mode sweep` for empirical QMC convergence analysis.
- [x] Lane replication (NUM_LANES 2/4/8): bit-identical price vs single lane in sim; on-board throughput TBD.
- [ ] Multi-exercise-date expansion (full backward induction).

> :warning: Active development — Phases 1-13 complete. All modules fully synthesizable.

---

## Contact
For questions or contributions, please open an issue or pull request.  
