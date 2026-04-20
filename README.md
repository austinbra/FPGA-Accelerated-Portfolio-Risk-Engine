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
- **Three running modes** (host-side via `src/uart_host.py`):
  - **Benchmark**: CPU vs FPGA side-by-side with identical parameters; reports price, cycles, wall time, speedup.
  - **Live**: Fetches real market data from Yahoo Finance, derives S0/sigma, runs pricing with live parameters.
  - **Sweep**: Convergence analysis — runs at increasing N (64→4096) and prints price convergence table.
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

---

## Build & Run
### FPGA (Vivado)

**Prerequisite:** Run from a shell where Vivado is in PATH (e.g. "Vivado 2023.x Command Prompt" or after sourcing `settings64.bat` / `settings64.sh`).

**Quick compile/simulate (recommended):**
```powershell
./scripts/run_xvlog_src.ps1          # Compile (uses vivado -mode batch by default)
./scripts/run_xelab_smoke.ps1       # Elaborate
./scripts/run_tb_top_uart_safe.ps1  # Simulate (timeout mode)
./scripts/run_tb_top_uart_safe.ps1 -ComputeMode  # Simulate (compute mode)
```

Root-level `./run_xvlog_src.ps1` and `./run_xelab_smoke.ps1` are thin wrappers that call the same files under `scripts/`.

If scripts time out, ensure Vivado is in PATH. Alternatively run directly:
```bash
vivado -mode batch -source scripts/run_xvlog.tcl
```

**Numerical validation** (C++ vs FPGA sim):
```bash
cd baseline/cpp_fixed && g++ -std=c++17 main.cpp pricing.cpp linalg.cpp sobol_wrapper.cpp utils.cpp -o fixed_baseline
python scripts/validate_numerical.py
```

**Arty S7-50 bitstream (scripted):** full flow is documented in [`.user/FPGA_BUILD.md`](.user/FPGA_BUILD.md). Quick synthesis check:

```powershell
$env:VIVADO_SYNTH_ONLY = "1"
.\scripts\run_vivado_build_arty_s7.ps1 -SynthOnly
Remove-Item Env:VIVADO_SYNTH_ONLY -ErrorAction SilentlyContinue
```

Full implementation + `.bit` (long run): `.\scripts\run_vivado_build_arty_s7.ps1` (optional `-TimeoutSeconds`).

### C++ Baseline
1. Build `baseline/cpp_fixed/` with a modern C++ compiler (C++17 or later).  
2. Run with the same option parameters as the FPGA to compare results.  
3. For speed comparison, measure FPGA core cycles (exclude UART transfer time) and compare against baseline runtime.  
4. You can drive CPU/FPGA run modes from `src/uart_host.py` using `--mode benchmark|live` and `--target cpu|fpga|both`.  

### Running modes

Three host-side modes are supported via `src/uart_host.py`:

| Mode | Command | Purpose |
|------|---------|---------|
| **Benchmark** | `python src/uart_host.py --mode benchmark --target both --param-file baseline/cpp_fixed/params_example.txt` | Run CPU baseline and FPGA with identical params. Compare price, FPGA core cycles vs CPU wall time, speedup. UART I/O excluded from FPGA timing. |
| **Live** | `python src/uart_host.py --mode live --target fpga` | Fetch real market data from Yahoo Finance, derive S0 and sigma, run pricing. Logs input snapshot. |
| **Sweep** | `python src/uart_host.py --mode sweep --target cpu --param-file baseline/cpp_fixed/params_example.txt` | Convergence analysis: run at N=64,128,...,4096 and print price convergence table. |

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

> :warning: Active development — Phases 1-13 complete. All modules fully synthesizable. See [`.user/IMPLEMENTATION_STATUS.md`](.user/IMPLEMENTATION_STATUS.md) for what is built; [`.user/ROADMAP.md`](.user/ROADMAP.md) for next priorities.

---

## Contact
For questions or contributions, please open an issue or pull request.  
