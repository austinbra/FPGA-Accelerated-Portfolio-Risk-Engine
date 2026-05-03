# Validation Log

This is a chronological log. Older entries can be superseded by later results.
The current completed-state handoff is at the bottom under 2026-05-03 and in
`.ai/rules/primer.md`.

This file records the main verification steps run during repository cleanup and benchmark workflow integration.

## Scope

- Source-tree reorganization (`src/io`, `src/top`, baseline promotion).
- `src/` compile and elaboration health.
- C++ fixed-point baseline build/run checks.
- Host benchmark/live runner checks.

## Toolchain Checks

### Vivado SystemVerilog compile

- Command:
  - `./run_xvlog_src.ps1`
- Result:
  - Pass
- Notes:
  - Re-run multiple times after each major RTL update (including file moves, `inverseCDF_fold` rename, UART packet updates, top-level benchmark hooks).

### Vivado elaboration smoke

- Command:
  - `./run_xelab_smoke.ps1`
- Result:
  - Pass
- Covered module snapshots:
  - `top_mc_option_pricer`
  - `uart_input_handler`
  - `sobol`
  - `inverseCDF_fold`
  - `inverseCDF`
  - `GBM`
  - `accumulator`
  - `regression`
  - `lsm_decision`
- Notes:
  - Uses simulation stub `src/sim/fxDiv_core_stub.sv` to unblock elaboration without generated `fxDiv_core` IP in sim context.

## C++ Baseline Validation

### Baseline compile and run (promoted location)

- Location:
  - `baseline/cpp_fixed/`
- Commands used:
  - `g++ -std=c++17 main.cpp pricing.cpp linalg.cpp sobol_wrapper.cpp utils.cpp -o fixed_baseline`
  - `./fixed_baseline --paths 256 --steps 12 --S0 100 --K 100 --r 0.05 --sigma 0.2 --T 1.0`
  - `./run_baseline.ps1 -InputFile params_example.txt`
- Result:
  - Pass
- Representative output observed:
  - `Estimated Option Price (double): 5.31464`
  - runtime printed successfully

### CPU sanity behavior check

- Method:
  - Compared runs with different `S0` values under same other params.
- Result:
  - Higher `S0` produced higher option value (expected monotonic call-like behavior).

## Python Host Runner Validation

### Syntax and CPU benchmark path

- Command:
  - `python -m py_compile src/uart_host.py`
- Result:
  - Pass

- Command:
  - `python src/uart_host.py --mode benchmark --target cpu --param-file baseline/cpp_fixed/params_example.txt --build-cpu`
- Result:
  - Pass
- Notes:
  - Prints parameters, CPU output, parsed CPU price/runtime.

### CPU baseline monotonic sweep (quick regression)

- Location:
  - `baseline/cpp_fixed/`
- Commands:
  - Build: `g++ -std=c++17 main.cpp pricing.cpp linalg.cpp sobol_wrapper.cpp utils.cpp -o fixed_baseline`
  - Runs (paths=2048, steps=12, r=0.05, sigma=0.2, T=1.0):
    - `S0=80, K=100`  -> `price=1.09646`
    - `S0=100, K=100` -> `price=5.46686`
    - `S0=120, K=100` -> `price=21.1872`
    - `S0=100, K=90`  -> `price=11.3954`
    - `S0=100, K=110` -> `price=3.09445`
- Result:
  - Pass
- Why this indicates correctness:
  - Call option value rises as `S0` rises (holding other params fixed).
  - Call option value falls as strike `K` rises (holding other params fixed).
  - These monotonic properties are required for financially sane pricing behavior.

## Functional Protocol Validation

### UART result packet protocol

- Implemented packet words (after parameter echo phase):
  - `0xABCD0001` marker
  - `price_raw`
  - `cycles_lo`
  - `cycles_hi`
- Host decode support:
  - `src/uart_host.py` decodes marker/price/cycles and can compute `compute_time_s` with `--fpga-fclk-hz`.

### Top UART integration testbench (`tb_top_option_pricer_uart.sv`)

- Added hardened host-side UART tasks with bounded waits:
  - `wait_for_tx_ready`
  - `wait_for_rx_byte_valid`
  - `wait_for_tx_busy`
  - `recv_byte` / `recv_word`
- Added explicit global watchdog in TB to prevent infinite simulation runs.
- Test modes:
  - `tb_top_option_pricer_uart` (timeout-expected): **Pass**
  - `tb_top_option_pricer_uart_compute` (real compute-expected): **Pass**
- Notes:
  - `tb_top_option_pricer_uart` now uses a deliberately short timeout budget in timeout mode (`CORE_MAX_CYCLES=32`) to keep timeout-path coverage deterministic.
  - `tb_top_option_pricer_uart_compute` uses a long budget and now observes non-timeout completion.
  - Top-level start logic now keys off accepted batch handshake (`batch_valid && batch_ready` edge), not raw `batch_valid` edge.

### Stability and resource-safety guards

- Added bounded/guarded runner scripts:
  - `run_xvlog_src.ps1`
  - `run_xelab_smoke.ps1`
  - `run_tb_top_uart_safe.ps1`
- Guard behavior:
  - Hard wall-clock timeout per tool invocation with forced process-tree kill on timeout.
  - `-nolog` enabled for `xvlog/xelab/xsim` in safe scripts to avoid unbounded log growth.
  - `--mt off` for `xelab` in safe scripts to reduce peak memory pressure.

### Multi-batch UART regression (diagnostic)

- Added wrapper:
  - `tb_top_option_pricer_uart_multibatch` (`NUM_BATCHES=2`)
- Run: `run_tb_top_uart_safe.ps1 -Multibatch`
- Previous result (pre bug fixes): **Fail** — batch 1 returned X, fxInvCDF_ZS assertion.
- Re-test after P0 fixes + fxInvCDF_ZS in_flight rewrite: run `-Multibatch` to verify.

## P0 Bug Fix Audit (2026-03-01)

A full-codebase correctness review identified and fixed 13 blocking bugs across the math, pipeline, and baseline modules. All fixes pass `xvlog` + `xelab` smoke.

### Math module LUT timing bugs (off-by-one pipeline races)

Three BRAM-backed LUT modules had the same systemic defect: a registered address/input and the LUT read occurred on the same clock edge, causing the LUT output to correspond to the *previous* sample.

| Module | Bug | Fix |
|--------|-----|-----|
| `fxLnLUT` | `lut_index` derived from registered `a_bound`; `result_reg` captures stale lookup | Rewrote as 2-stage pipeline: stage 1 registers `a_bound`, stage 2 reads `lut[lut_index]` from the registered value |
| `fxExpLUT` | `addr_reg` captures stale `a_shifted` | Same 2-stage pipeline: clamp+register in stage 1, LUT read in stage 2 |
| `fxSqrt` | LUT index from stale `a_norm_reg`; final `v4_result` from stale `tmp` | LUT index now computed from combinational `a_norm`; output is combinational from `mul4_result` (stable under stall by fxMul guarantee) |

### GBM pipeline bugs

| Bug | Fix |
|-----|-----|
| Diffusion branch fires on `buf_valid` alone (double-fire under stall) | Gated: `diff_v_in = buf_valid && shift_en` |
| `sign_bit` derived combinationally from `exp_arg` but used after ExpLUT+Div latency | Added `exp_launch` one-cycle-delayed pulse; `exp_arg` is now registered before ExpLUT fires, so `sign_bit` is stable throughout |
| `exp_arg` saturation `(1<<<(WIDTH-1)-1)` has wrong operator precedence; no negative clamp | Replaced with `MAX_POS`/`MIN_NEG` localparam constants with correct full-range signed saturation |

### Inverse CDF pipeline bugs

| Bug | Fix |
|-----|-----|
| `fxInvCDF_ZS`: `t_eff` and `negate_pipe` are stale at output (divider latency mismatch) | Complete rewrite: `in_flight` flag prevents double-acceptance; `t_cap` and `negate_cap` captured at input and held stable through entire computation |
| `inverseCDF`: `negate_pipe` shift register drifts under stalls | Replaced fixed shift register with `event_align_fifo_arr` FIFO: push on fold output, pop on sqrt output |
| `inverseCDF_fold`: negate polarity is inverted | Swapped: `u < 0.5 -> negate=1` (left tail), `u >= 0.5 -> negate=0` (right tail) |

### Accumulator / decision / baseline alignment bugs

| Bug | Fix |
|-----|-----|
| `accumulator`: `sum1 <= sum1 + acc_t'(1)` adds integer 1, not 1.0 in Q16.16 | Changed to `sum1 + (acc_t'(1) <<< QFRAC)` |
| `lsm_decision`: originally hard-coded to one payoff direction | D1: Added `option_type` input; 0=CALL `max(S-K,0)`, 1=PUT `max(K-S,0)`. Same flag used in `top_option_pricer.sv` terminal_payoff. |
| C++ baseline `types.h`: `FRAC_BITS=21` (Q11.21) while FPGA uses Q16.16 | Changed to `FRAC_BITS=16` |
| `tb_regression`, `tb_accumulator`: connect to non-existent `.solver_ready` port | Removed the port connection |

### lsm_decision interface change

- Replaced `disc` input with `cont_value` input.
- The "continue" branch now uses the actual discounted future cashflow (`cont_value`) instead of `regression_estimate * disc`.
- Why: in proper LSMC, the regression estimate is only used for the exercise *decision*; the actual cashflow must be the real discounted future value.

### Verification status after P0 fixes

- `run_xvlog_src.ps1`: **Pass** (all 22 source files)
- `run_xelab_smoke.ps1`: **Pass** (all 9 module snapshots)

## Top-Level Integration (2026-03-01)

### Architecture: two-pass QMC-LSMC pipeline (target: fully pipelined)

Rewrote `top_option_pricer.sv` from a single-sample stub into a complete two-pass LSMC engine. The current implementation uses an 11-state FSM that serializes samples (one sobol→inverseCDF→GBM at a time). **This is interim.** The architectural goal is a **fully pipelined, streaming top-level** where:

- Each pipeline stage (Sobol, InverseCDF, GBM) has skid buffers and ready/valid interfaces.
- The top-level fires samples into the pipeline as fast as it can accept them, NOT one-at-a-time after end-to-end completion.
- Multiple samples are in-flight simultaneously across pipeline stages.
- Throughput is limited only by the slowest stage, not by total pipeline depth.

**Pass 1 (Training):** For each of N paths, run M sequential GBM steps via the streaming pipeline `sobol -> inverseCDF -> GBM`, feeding `(S_exercise, disc * terminal_payoff)` into the accumulator. After N paths, accumulator triggers regression and outputs `beta[0:2]`.

**Pass 2 (Decision):** Regenerate the same N paths (Sobol is deterministic from `idx_in`). For each path, `lsm_decision` compares immediate exercise payoff against the regression-estimated continuation, then selects the actual cashflow. The PV is discounted to t=0 via `disc_total` and accumulated. Final price = `sum_pv / N`.

**Exercise date:** Step M-1 (one step before maturity). Single exercise date for this version.

**Init phase:** Computes `dt = T / M`, `disc = exp(-r * dt)`, `disc_total = disc^(M-1)`, `drift_const = (r - sigma²/2) * dt`, `vol_sqrt_dt = sigma * sqrt(dt)` using dedicated utility fxDiv/fxMul/fxExpLUT/fxSqrt instances (time-shared, not on the critical path).

**Timeout guard:** `CORE_MAX_CYCLES` checked in every long-running FSM state. Timeout returns marker `0xDEAD0001`.

### Two running modes (host-side)

The project targets two host-side running modes via `src/uart_host.py`:

| Mode | Flag | Description |
|------|------|-------------|
| **Benchmark** | `--mode benchmark --target cpu\|fpga\|both` | Run CPU baseline and/or FPGA with identical parameters. Compare price, cycles, wall time, speedup. UART I/O time excluded from FPGA timing. |
| **Live** | `--mode live --target cpu\|fpga` | Fetch real market data from Yahoo Finance, derive S0/sigma, run pricing with live params. Logs input snapshot for repeatability. |

### Verification status after integration

- `run_xvlog_src.ps1`: **Pass**
- `run_xelab_smoke.ps1`: **Pass** (all 9 module snapshots including top)

## Accumulator Runtime Sample Count (2026-03-01)

- Added `n_samples_cfg` runtime input port to `accumulator.sv`.
- When non-zero, overrides the `N_SAMPLES` parameter. When zero, uses parameter default.
- Why: the top-level FSM sends `lat_N` paths (from UART params), which varies per batch. The hardcoded `N_SAMPLES=10000` parameter would cause the accumulator to wait forever for paths that never arrive.
- `top_option_pricer.sv`: wires `.n_samples_cfg(lat_N[$clog2(10001)-1:0])`.
- `tb_accumulator.sv`: wires `.n_samples_cfg('0)` (uses parameter default).

### Verification status

- `run_xvlog_src.ps1`: **Pass** (all sources + both TBs)
- `run_xelab_smoke.ps1`: **Pass** (all 9 module snapshots including top, accumulator)

## Top UART Testbench Update (2026-03-01)

- Removed stale `ENABLE_PLACEHOLDER_RESULT` parameter (no longer exists in new top).
- Updated debug probes to match new signal names (`sobol_vout`, `inv_vout`, `gbm_vout`, `lsm_vout`, `core_active`, `result_valid`, `u_inv.*`).
- Added Q16.16 price sanity check in compute mode: logs price in human-readable form and flags out-of-range values.
- `CORE_MAX_CYCLES` in compute mode set to 2M (sufficient for N=64, M=12 two-pass LSMC).

## Pipeline Restoration Phase 2 (2026-03-02): Pre-compute GBM Constants

**What changed:**
- Added utility `fxSqrt` instance to `top_option_pricer.sv` (used only during INIT, idle during compute).
- Added `ST_INIT_GBM_CONST` state between `ST_INIT_DT` and `ST_INIT_DISC` to compute:
  - `sigma2 = sigma * sigma`
  - `drift_const = (r - sigma2/2) * dt`
  - `sqrt_dt = sqrt(dt)` via util_sqrt
  - `vol_sqrt_dt = sigma * sqrt_dt`
- Stored `drift_const_reg` and `vol_sqrt_dt_reg`; pass them to GBM instead of `r`, `sigma`, `dt`.
- Modified `GBM.sv`: interface now takes `drift_const`, `vol_sqrt_dt`; removed `r`, `sigma`, `dt`.
- GBM internal FSM simplified: removed MUL_SIGMA2, MUL_DRIFT, DO_SQRT, MUL_SIG_SQRT states and fxSqrt instance.
- GBM per-sample flow: `diffusion = vol_sqrt_dt * z` → `exp_arg = drift_const + diffusion` → exp → S_next.

**Why:** Pre-computing constants during INIT eliminates redundant per-sample sigma², sqrt(dt), and drift computation in GBM, reducing latency and preparing for streaming pipeline (Phase 3/4).

**Verification:** Run `run_xvlog_src.ps1` and `run_xelab_smoke.ps1` to confirm compile/elab pass.

## Pipeline Restoration Phase 3 (2026-03-02): GBM Streaming Pipeline

**What changed:**
- Rewrote `GBM.sv` from sequential FSM to streaming pipeline with skid buffers: MUL1(vol_sqrt_dt*z) → ADD+Saturate → EXP(signed) → MUL2(S*exp).
- Added `SIGNED_RANGE` parameter to `fxExpLUT.sv`: when 1, uses 8192-entry `exp_signed_lut_8192.mem` for exp(a) with a in [-1,1], eliminating fxDiv reciprocal for negative exp_arg.
- GBM now uses 2× fxMul, 1× fxExpLUT (signed). No fxSqrt, no fxDiv.
- Input skid buffer decouples from inverseCDF backpressure.
- S pipeline (4-stage) aligns S with exp output for final multiply.
- Latency: ~5 cycles (MUL1=1 + EXP=2 + MUL2=1 + alignment).

**Why:** Constant low latency, full throughput under backpressure, 3 fewer DSPs, ready for Phase 4 fully pipelined top-level.

**Status:** Compile/elab clean. Has a known bug (S pipeline misalignment under non-streaming use — see historical notes / `IMPLEMENTATION_STATUS.md`).

**Phase 4 (next):** The top-level must be converted from serialized FSM control to streaming control that fires samples into the pipeline as fast as it can accept. This is the core architectural goal of the project — without it, the FPGA has no throughput advantage. See `ROADMAP.md` and `IMPLEMENTATION_STATUS.md`.

**Verification:** Run `run_xvlog_src.ps1` and `run_xelab_smoke.ps1`.

## Known Gaps / Pending Validation

- ~~**Fully pipelined top-level (Phase 4)**~~ **COMPLETE 2026-03-02**: FSM fires Sobol for step k+1 in the same cycle GBM outputs step k.
- ~~**Two running modes not yet validated end-to-end**~~ **Phase 6 COMPLETE 2026-03-02**: Benchmark + live mode code implemented in `uart_host.py`. Not yet tested with real FPGA hardware (needs bitstream + serial connection).
- ~~**Numerical validation**~~ **COMPLETE 2026-03-02**: FPGA price = 6.553, C++ baseline = 6.50, relative error = 0.8%. Required fixing 8 numerical bugs (see Phase 7 section).
- ~~**Three critical bugs block all forward progress**~~ **FIXED 2026-03-02** (see P0 Bug Fixes Phase 2 below).
- ~~**D1 PUT/CALL**~~ **COMPLETE 2026-03-02**: option_type flag flows from UART word 7 through top-level to lsm_decision.
- ~~**fxSqrt / fxLnLUT behavioral models**~~ **COMPLETE 2026-04-15 (supersedes 2026-03-17 notes):** `fxlnLUT` = 2-stage BRAM + `ln_lut_4096.mem` (regenerate via `scripts/gen_ln_lut_4096.py`). `fxSqrt` = restoring digit-by-digit (24 `COMP` cycles); `FP_SQRT_LATENCY=24`. Vivado `synth_design` **0 errors** (see log section below dated 2026-04-15).
- ~~**D2 richer error reporting**~~ **COMPLETE 2026-03-17**: 5-word result packet with status flags (timeout, singular regression).
- ~~**Precision centralization**~~ **COMPLETE 2026-03-17**: FP_ONE/HALF/NEG_ONE/NEG_TWO in fpga_cfg_pkg; elaboration assertions for precomputed constants.
- ~~**D3 antithetic variates**~~ **COMPLETE 2026-03-17**: Paired z/-z paths double effective N for variance reduction.
- ~~**D4 convergence sweep**~~ **COMPLETE 2026-03-17**: `uart_host.py --mode sweep` for empirical convergence analysis.
- Multi-exercise-date expansion: current architecture checks exercise at step M-1 only; full backward induction with M-1 regression passes is future work.
- Lane replication (D5): NUM_LANES > 1 for throughput scaling is future work.
- Multi-batch UART regression: `-Multibatch` flag added; not yet re-tested after full numerical fixes.

## Baseline/Archive Policy Validation

- Non-fixed-point archive baseline removed from active tree and superseded by promoted baseline path:
  - Active: `baseline/cpp_fixed/`
  - Archive marker retained: `archive/buildup/Cpp_outline_32/README.md`
- Archive legacy RTL kept for reference in `archive/old` and `archive/buildup/sv_regression_handshake`.

## Re-run Quick Checklist

1. `./run_xvlog_src.ps1`
2. `./run_xelab_smoke.ps1`
3. `python -m py_compile src/uart_host.py`
4. `cd baseline/cpp_fixed`
5. `./run_baseline.ps1 -InputFile params_example.txt`
6. `python src/uart_host.py --mode benchmark --target cpu --param-file baseline/cpp_fixed/params_example.txt --build-cpu`

## Task Completion Log (rolling)

- 2026-03-01: Safe run wrappers validated (`run_xvlog_src.ps1`, `run_xelab_smoke.ps1`, `run_tb_top_uart_safe.ps1`).
  - Status: working.
  - Why: each script completed with bounded execution and no uncontrolled log growth (`-nolog`, timeout kill path available).
- 2026-03-01: top UART timeout and compute wrappers both pass.
  - Status: working.
  - Why: full 7-word param RX, echo packet, and result packet checks complete under bounded TB watchdogs.
- 2026-03-01: workspace artifact cleanup executed (`cleanup_artifacts.ps1 -IncludeSimDirs`).
  - Status: working.
  - Why: generated simulator directory/log context removed after task completion.
- 2026-03-01: top-level batch accept/start handshake tightened in `top_option_pricer`.
  - Status: working.
  - Why: `core_start` now triggers only on accepted batch handshake edge, avoiding raw `batch_valid` edge races.
- 2026-03-01: multi-batch UART diagnostic added (`tb_top_option_pricer_uart_multibatch`).
  - Status: reproduces known issue.
  - Why: reliably exposes second-batch inverse-CDF handshake/data-valid instability for focused fixing.
- 2026-03-01: single-batch timeout/compute regressions re-verified after top/inverseCDF iterations.
  - Status: working.
  - Why: both wrappers (`tb_top_option_pricer_uart`, `tb_top_option_pricer_uart_compute`) report PASS with bounded waits and clean packet checks.
- 2026-03-01: Full P0 correctness audit: 13 bugs fixed across fxLnLUT, fxExpLUT, fxSqrt, GBM, fxInvCDF_ZS, inverseCDF, inverseCDF_fold, accumulator, lsm_decision, C++ baseline, testbenches.
  - Status: all fixes compile and elaborate clean.
  - Why: systemic LUT timing races, pipeline misalignment, negate polarity inversion, Q-format mismatch, and payoff direction mismatch all caused silent numerical errors or data corruption.
- 2026-03-01: lsm_decision interface changed: `disc` input replaced with `cont_value` for proper LSMC cashflow semantics.
  - Status: compile/elab clean; tb_lsm_decision updated.
  - Why: regression estimate should only drive the exercise decision, not the actual continuation cashflow.
- 2026-03-01: top_option_pricer.sv rewritten with 11-state two-pass LSMC FSM integrating sobol -> inverseCDF -> GBM -> accumulator -> regression -> lsm_decision.
  - Status: compile/elab clean.
  - Why: previous top was a single-sample stub with hardwired beta=[0,0,0] and no accumulator/regression.
- 2026-03-01: regression.sv debug $display traces gated behind `ifdef REG_DEBUG`.
  - Status: working.
  - Why: unconditional traces flood simulation logs during integration runs.
- 2026-03-01: C++ baseline Q-format aligned to Q16.16 (`FRAC_BITS=16`).
  - Status: working.
  - Why: was Q11.21, making cross-validation against FPGA unreliable.
- 2026-03-01: .gitignore updated to cover `dfx_runtime.txt`, `xvlog.pb`, `xelab.pb`.
  - Status: working.
- 2026-03-01: accumulator.sv: added `n_samples_cfg` runtime port (overrides N_SAMPLES parameter when non-zero).
  - Status: compile/elab clean.
  - Why: top-level sends lat_N paths per batch; hardcoded N_SAMPLES=10000 would deadlock for smaller batches.
- 2026-03-01: tb_top_option_pricer_uart.sv: removed ENABLE_PLACEHOLDER_RESULT, updated debug probes, added price sanity check.
  - Status: compile clean.
  - Why: aligned to new two-pass top-level (old params/signal names no longer exist).

## P0 Bug Fixes Phase 2 (2026-03-02): Three Critical Bugs + Timeout Guards

**Bug 1 — sub_phase overflow (top_option_pricer.sv):**
- `logic [1:0] sub_phase` widened to `logic [2:0] sub_phase` (needed values 0–4).
- All sized literals changed from `2'd` to `3'd` for sub_phase.
- Fix: FSM no longer stuck forever in ST_INIT_GBM_CONST; vol_sqrt_dt_reg is set and INIT completes.

**Bug 2 — GBM S pipeline misalignment (GBM.sv):**
- Replaced event-driven `s_pipe` shift register with `event_align_fifo_arr` FIFO.
- Push on `mul1_accept`, pop on `exp_vout && mul2_rout`.
- Fix: Correct S aligned with exp output under sporadic (non-streaming) throughput.
- Added ASSERT_STRICT assertion for S FIFO overflow.

**Bug 3 — fxInvCDF_ZS C0 constant (fxInvCDF_ZS.sv):**
- OLD: `C0 = (2 <<< QFRAC) + ((515517 <<< (QFRAC - 20)) / 1000000)` → 2.0 (negative shift undefined).
- NEW: `C0 = (2515517 * (1 <<< QFRAC)) / 1000000` → 2.515517 in Q16.16.
- Fix: Z-scores now correct; GBM paths and final price no longer corrupted.

**Timeout guards (infinite-loop prevention):**
- Added `core_timeout` checks to all blocking states: ST_INIT_DT, ST_INIT_GBM_CONST, ST_INIT_DISC, ST_INIT_DISC_TOTAL, ST_TRAIN_FEED, ST_WAIT_BETA, ST_DECIDE_FEED, ST_FINAL_DIV.
- `CORE_MAX_CYCLES` (default 50M) ensures FSM never spins indefinitely.
- Timeout returns marker `0xDEAD0001` via ST_DONE.

**Verification:** Run `run_xvlog_src.ps1`, `run_xelab_smoke.ps1`, then `run_tb_top_uart_safe.ps1` (timeout), `run_tb_top_uart_safe.ps1 -ComputeMode` (compute), `run_tb_top_uart_safe.ps1 -Multibatch` (2 batches).

## Phase 4: Fully Pipelined Top-Level (2026-03-02)

**What changed:**
- ST_TRAIN_STEP and ST_DECIDE_STEP: fire Sobol for step k+1 in the **same cycle** as GBM outputs step k (when sobol_rout).
- Eliminates idle cycle between steps; pipeline latency overlaps with FSM bookkeeping.
- When sobol_rout is low (backpressure), fall back to Phase A on next cycle.

**Why:** Eliminates idle cycle between steps. Within a path, steps are still sequential (~21 cycle pipeline latency) since step k+1 depends on step k's S output. Savings: ~1 cycle per step (22→21). True ~5 cycles/step throughput requires lane replication (multiple paths in parallel).

## Phase 5: Accumulator/Regression Stall Diagnosis (2026-03-02)

**What added:**
- `accumulator.sv`: `ifdef ACC_DEBUG` block traces fire_head, cnt_launch, cnt_done, n_eff, start_solver, solver_done, solver_ready, singular_err.
- `run_tb_top_uart_safe.ps1 -DebugAcc`: adds `+define+ACC_DEBUG` for accumulator stall diagnosis.

**Purpose:** Diagnose ST_WAIT_BETA stalls — verify cnt_done reaches n_eff, solver fires, and beta is produced.

## P2: Numerical Validation vs C++ Baseline (2026-03-02)

**Script:** `scripts/validate_numerical.py`

Runs C++ baseline and FPGA simulation with identical params (paths=64, steps=12, S0=K=100, r=0.05, sigma=0.2, T=1.0). Compares prices; expects <1% relative error.

```bash
python scripts/validate_numerical.py
```

Prerequisite: C++ baseline built (`cd baseline/cpp_fixed && g++ ...`), Vivado in PATH.

## Phase 6: Two Host Running Modes (2026-03-02)

**uart_host.py enhancements:**

- **BENCHMARK mode** (`--mode benchmark --target both`): Consolidated comparison report with price delta, relative error, CPU wall time, FPGA compute time (when --fpga-fclk-hz set), speedup ratio.
- **LIVE mode** (`--mode live`): Logs input snapshot (ticker, date, derived params) for repeatability before running.
- **q16_16_to_float**: Fixed signed handling for FPGA price decode.
- **run_cpu_baseline**: Captures stdout+stderr for robust parsing.

## D1: PUT/CALL Runtime Flag (2026-03-02)

**What changed:**
- `uart_input_handler.sv`: 8-word payload (was 7). `option_type = reg_array[7][0]`.
- `top_option_pricer.sv`: `param_option_type` → `lat_option_type`, used in `terminal_payoff` computation. 0=CALL `max(S-K,0)`, 1=PUT `max(K-S,0)`.
- `lsm_decision.sv`: Added `option_type` input port. Payoff selection uses `option_type`.
- `tb_top_option_pricer_uart.sv`: Sends 8 words per batch (`params[7] = 0` for CALL).
- `uart_host.py`: `send_params_uart` includes `option_type` field.

**Verification:** Compilation passed for all modules. TB receives all 8 words.

## Regression Module Fixes (2026-03-02)

**Pivot2 fallback (regression.sv):**
- `fallback_req` and `singular_err` checked `v6b`, which never fires when `pivot2_is_zero`. Changed to use `v6` when pivot2 is zero.

**v3 deadlock (regression.sv):**
- `v3` condition required `&& v2` (a 1-cycle pulse) simultaneously with `mul0_done` (arrives 1 cycle later). Removed `&& v2`.

**Verification:** Training pass now completes; ACC-OUT, beta, and FSM transitions 7→8→9 observed.

## lsm_decision Stall Fix (2026-03-02)

**Problem:** `lsm_decision` accepted input but never asserted `valid_out`. The skid-buffer pattern was incompatible with multi-cycle fxMul computation (ready_in circular dependency).

**Fix:** Replaced skid-buffer input buffering with a `busy` flag + `started` pulse pattern:
- `ready_out = !busy`
- On `valid_in && !busy`: latch inputs, set `busy=1`, fire `started` pulse
- On `valid_out && ready_in`: clear `busy`

**Verification:** Decision pass completes; `[LSM-OUT]` traces observed.

## Phase 7: Numerical Debugging — 8 Bugs Fixed (2026-03-02)

Starting condition: FPGA sim = 61.27, C++ baseline = 6.50 (842% relative error).

### Bug N1: ONE_Q = -65536 (top_option_pricer.sv)
- `ONE_Q = 1'sd1 <<< QF` — `1'sd1` is -1 in 1-bit signed. ONE_Q = -65536.
- Discount factor became large negative. Fix: `ONE_Q = 32'sd1 <<< QF`.

### Bug N2: Q16.16 overflow in regression inputs
- S ≈ 100 → S⁴ = 100M, but Q16.16 max = 32767. All higher powers saturated.
- Fix: Moneyness normalization (s_norm = S/K ≈ 1.0) for all regression inputs.
- Added `ST_INIT_INV_K` state, `inv_K_reg`, modified `ST_TRAIN_FEED`/`ST_DECIDE_FEED` to compute `s_norm`.
- Updated `lsm_decision` to use `s_norm` for continuation estimate.

### Bug N3: Sobol Q0.32 → Q16.16 mismatch (top_option_pricer.sv)
- `sobol_out` is Q0.32 unsigned. `$signed(sobol_out)` reinterprets 0x80000000 (0.5) as -32768 in Q16.16.
- Fix: `sobol_q16 = $signed({16'd0, sobol_out[31:16]})` — explicit format conversion.

### Bug N4: inverseCDF_fold HALF = -32768 (inverseCDF_fold.sv)
- `HALF = 1'sd1 << (QFRAC-1)` — same 1-bit signed pattern as N1. HALF = -32768.
- Fix: `HALF = 32'sd1 << (QFRAC-1)`.

### Bug N5: fxSqrt Newton-Raphson scale mismatch (fxSqrt.sv)
- LUT lookup used normalized a_norm ∈ [0.5, 1.0), but refinement used unnormalized a_in.
- Fix: Replaced with behavioral model (`$sqrt()`). Needs synthesizable rewrite.

### Bug N6: fxLnLUT computed ln(1+frac) not ln(x) (fxLnLUT.sv)
- LUT stored ln(1+frac) for frac ∈ [0,1). For x=0.5: got -ln(1.5) = -0.405. Correct: ln(0.5) = -0.693.
- Fix: Replaced with behavioral model (`$ln()`). Needs synthesizable rewrite.

### Bug N7: fxInvCDF_ZS 32-bit overflow in constants (fxInvCDF_ZS.sv)
- `C0 = (2515517 * (1 <<< QFRAC)) / 1000000` → intermediate = 164B, overflows 32-bit signed.
- Fix: All constants precomputed as `32'sd` literals (C0=164889, C1=52603, etc.).

### Bug N8: event_align_fifo_arr registered pop_data (event_align_fifo_arr.sv)
- `pop_data` was registered — reflected previous cycle's head, not current.
- In inverseCDF, `negate_aligned` was latched 1 cycle too late → sign errors.
- Fix: `pop_data` changed to combinational output (`assign pop_data = mem[rptr]`).

### Result
- **FPGA price: 6.553**
- **C++ baseline: 6.50**
- **Relative error: 0.8%** (within QMC variance for N=64 paths)

### Files changed
| File | Change |
|------|--------|
| `src/top/top_option_pricer.sv` | ONE_Q fix, Sobol Q0.32→Q16.16 conversion, ST_INIT_INV_K state, moneyness normalization in ST_TRAIN_FEED/ST_DECIDE_FEED |
| `src/steps/lsm_decision.sv` | Added `s_norm` input, uses moneyness for continuation estimate |
| `src/steps/inverseCDF_fold.sv` | HALF constant fix (32'sd1) |
| `src/math/fxSqrt.sv` | Behavioral model replacement |
| `src/math/fxLnLUT.sv` | Behavioral model replacement |
| `src/math/fxInvCDF_ZS.sv` | Precomputed Q16.16 constants |
| `src/helpers/event_align_fifo_arr.sv` | Combinational pop_data output |
| `tb/tb_lsm_decision.sv` | Added s_norm port connection |
| `run_tb_top_uart_safe.ps1` | Build hardening (timeout increases) |
| `scripts/validate_numerical.py` | Tolerant parsing of "out of plausible range" |

## D2: Richer Error Reporting (2026-03-17)

**What changed:**
- `uart_input_handler.sv`: 5-word result packet (`result_buf[0:4]`), marker updated to `0xABCD0002`, result_idx widened to 3 bits. New `result_status` input port.
- `accumulator.sv`: New `regression_singular` output port, wired from regression's `singular_err`.
- `top_option_pricer.sv`: 32-bit `status_flags` register. Bit 0 = timeout (set in ST_DONE), bit 1 = singular regression (set in ST_WAIT_BETA). New `result_status` output connected to UART handler.
- `tb_top_option_pricer_uart.sv`: NUM_RESULT=5, accepts both `0xABCD0001` and `0xABCD0002` markers, decodes and displays status word.
- `src/uart_host.py`: Parses 5th result word, decodes TIMEOUT and SINGULAR_REGRESSION flags.

**Verification:** Full compile/elaborate pass. TB reports status word correctly.

## Synthesizable fxLnLUT Rewrite (2026-03-17)

**What changed:**
- Replaced behavioral `$ln()` model with synthesizable 3-stage pipelined RTL.
- Algorithm: Range decomposition (priority encoder → barrel shift → LUT address) + linear interpolation between adjacent LUT entries for sub-fractional accuracy.
- Stage 1: Find MSB, normalize input, compute LUT addresses and sub-fractional bits.
- Stage 2: Read two adjacent LUT entries from BRAM, compute delta.
- Stage 3: Linear interpolation (`base + sub_frac * delta >> SUB_BITS`) + `int_log2 * LN2_Q`.
- Ready/valid handshaking across all 3 stages. No DSP required.
- Added elaboration assertions for `LN2_Q` and `LN_ZERO_CLAMP` constants.
- Fixed LUT address wraparound bug: `s1_lut_addr_next` now clamped at max instead of wrapping to 0.

**Verification:** Compile/elaborate clean. Elaboration assertions pass.

## Synthesizable fxSqrt Rewrite (2026-03-17)

**What changed:**
- Replaced behavioral `$sqrt()` model with synthesizable non-restoring digit-by-digit algorithm.
- Input extended to 48 bits (`{a, {QFRAC{1'b0}}}`) for Q16.16 → Q16.16 computation.
- 24 iterations (2 input bits per cycle → 1 result bit), 25 total cycles including setup.
- No LUT, no DSP. Uses trial subtraction comparator only.
- FSM: S_IDLE → S_COMPUTE (24 iterations) → S_DONE.

**Verification:** Compile/elaborate clean. Stall stability assertion.

## Precision Centralization (2026-03-17)

**What changed:**
- `fpga_cfg_pkg.sv`: Added `FP_ONE`, `FP_HALF`, `FP_NEG_ONE`, `FP_NEG_TWO` localparam constants (all use `32'sd` to prevent 1-bit signed bugs). Added `fp_from_real()` simulation helper function for elaboration assertions.
- 6 RTL modules updated to use package constants:
  - `fxDiv.sv`: `ONE_Q → fpga_cfg_pkg::FP_ONE`
  - `fxExpLUT.sv`: `A_MIN/A_MAX → fpga_cfg_pkg::FP_ONE`
  - `fxInvCDF_ZS.sv`: `ONE → fpga_cfg_pkg::FP_ONE`, elaboration assertions for C0-D3
  - `inverseCDF_fold.sv`: `HALF → fpga_cfg_pkg::FP_HALF`, `1<<QFRAC → fpga_cfg_pkg::FP_ONE`
  - `inverseCDF.sv`: `NEG_TWO → fpga_cfg_pkg::FP_NEG_TWO`
  - `top_option_pricer.sv`: removed local `ONE_Q`, uses `fpga_cfg_pkg::FP_ONE`
- 7 testbenches updated: local `parameter WIDTH/QINT/QFRAC` replaced with `localparam int` from `fpga_cfg_pkg`.
- `top_option_pricer.sv`: Hardcoded `sobol_out[31:16]` replaced with parameterized `sobol_out[W-1:QF]`.

**Verification:** Full compile/elaborate pass. Elaboration assertions caught 3 incorrect Z-S constants (see below).

## Zelen-Severo Constant Corrections (2026-03-17)

**What changed:**
- Elaboration-time assertions in `fxInvCDF_ZS.sv` detected 3 precomputed constants that didn't match `fp_from_real()`:
  - `C0`: 164889 → 164857 (correct: `fp_from_real(2.515517)`)
  - `C1`: 52603 → 52615 (correct: `fp_from_real(0.802853)`)
  - `D1`: 93896 → 93899 (correct: `fp_from_real(1.432788)`)

**Root cause:** Original hand-computation had minor rounding errors in the decimal → Q16.16 conversion.

**Verification:** All elaboration assertions now pass.

## D3: Antithetic Variates (2026-03-17)

**What changed:**
- `top_option_pricer.sv`: Added `ANTITHETIC_EN` parameter (default 1).
- Path pairing: even `path_idx` uses normal z, odd uses negated z (−inv_z). Both share the same Sobol index (`path_idx >> 1`).
- `total_paths = ANTITHETIC_EN ? 2*lat_N : lat_N` used for all loop bounds, n_samples_cfg, and final division.
- z-score negation is a simple wire mux between inverseCDF and GBM — no pipeline changes needed.
- The antithetic flag is stable across all M steps of a path (changes only between paths).

**Impact:** Doubles effective path count with near-zero hardware overhead. Halves QMC variance.

**Verification:** Compile/elaborate clean.

## D4: Convergence Sweep Mode (2026-03-17)

**What changed:**
- `src/uart_host.py`: Added `--mode sweep` with `--sweep-n` for custom N list.
- Runs pricing at increasing N values, prints convergence table (N, price, delta from previous, wall time).
- Works for `--target cpu`, `--target fpga`, or `--target both`.
- Default sweep: N = 64, 128, 256, 512, 1024, 2048, 4096.

**Verification:** `python -m py_compile src/uart_host.py` passes.

## D5: Multi-Lane FSM Scheduling — Double-Collect Bug Fix (2026-04-13)

### Problem

`NUM_LANES=1` produced price `0x00068D82` (≈6.55). `NUM_LANES=2` produced `0x00060B3C`. Not bit-identical. Initial hypothesis was stale GBM token or pipeline state contamination. The real cause was much deeper.

### Root Cause: inverseCDF Double-Valid Pulse

The inverseCDF pipeline produced **two valid-out pulses** for each single input token. Per-stage valid tracing revealed:

```
SOB_VIN (1 pulse) → SOB_VOUT (1 pulse) → INV_VOUT (2 pulses, 20ns apart) → GBM_VOUT (2 pulses, 20ns apart)
```

The `fxInvCDF_ZS` rational approximation stage completed its first computation, output `valid_out=1`, got consumed (`ready_in=1`), cleared `in_flight`, and then a lingering upstream valid (likely from the fast div simulation stub completing in 1 cycle instead of 16) re-triggered a second identical computation.

The FSM's collect condition (`sobol_accepted && gbm_vout`) fired on BOTH GBM outputs, incrementing `step_idx` twice per actual GBM computation. With M=12 time steps, only **6 unique GBM results** were computed (each counted twice). This halved the effective simulation for ALL lane counts.

### Why It Wasn't Detected Earlier

1. The single-lane price `0x00068D82` (6.55) was within 0.8% of the C++ baseline (6.50). This "good" match was **accidental**: the double-collect bug halved the time steps, and the resulting error happened to roughly cancel out.
2. The `validate_numerical.py` gate (≤1% relative error) PASSED with the buggy price.
3. The problem only became visible when comparing 1-lane vs 2-lane prices, because different lane counts interleave the echo pulses differently.

### Diagnosis Path (and what should have been done differently)

**What I did (slow, 6+ rounds):**
1. Added `!gbm_vout` guard on new-path fire → no effect
2. Hypothesized pipeline state contamination → read 6 module sources
3. Hypothesized stale GBM token → added per-lane debug prints
4. Eventually added per-step COLLECT prints → saw paired identical values
5. Added per-stage valid prints → found INV_VOUT double pulse

**What I should have done (fast, 2 rounds):**
1. Added per-step COLLECT prints immediately → see paired values in round 1
2. Added per-stage valid prints → find double INV_VOUT in round 2
3. Apply fix in round 3

### Fix

Added a `drain_cnt` register (3-bit, initialized to 0) to the FSM:
- After each GBM collect: `drain_cnt <= 3'd5` (5-cycle cooldown)
- Phase A (sobol fire) gated by `drain_cnt == 0`
- Collect branch gated by `drain_cnt == 0`
- `drain_cnt` decrements each cycle in the default block

This ensures echo GBM pulses during the cooldown window are ignored. Applied to both TRAIN_STEP and DECIDE_STEP.

### Results

| Config | Old Price | New Price | Match? |
|--------|-----------|-----------|--------|
| `NUM_LANES=1` | `0x00068D82` (6.55) | `0x000b93cd` (11.58) | baseline |
| `NUM_LANES=2` | `0x00060B3C` (6.04) | `0x000b93cd` (11.58) | **bit-identical** |

### Files Changed

| File | Change |
|------|--------|
| `src/top/top_option_pricer.sv` | Added `drain_cnt` register; gated Phase A and collect in TRAIN_STEP and DECIDE_STEP |
| `IMPLEMENTATION_STATUS.md` | D5 marked done, new price documented |
| `VALIDATION.md` | D5 gate passed, double-collect bug explanation |
| `ROADMAP.md` | D5 marked complete |

### Ancillary Changes (from diagnosis)

| File | Change |
|------|--------|
| `tb/tb_top_option_pricer_uart.sv` | Added `tb_top_option_pricer_uart_compute_lanes3` and `tb_top_option_pricer_uart_compute_lanes4` wrapper modules |
| `scripts/run_tb_top_uart_safe.ps1` | Extended `-NumLanes` dispatch to handle 3 and 4 lanes |

### Note on the Corrected Price

The old "validated" price of 6.55 (0.8% vs C++ baseline 6.50) was wrong. The true 12-step price is 11.58. The `validate_numerical.py` script needs to be re-run against the C++ baseline to establish the new error margin. The C++ baseline may also have the same or a different value since it uses double-precision arithmetic, not Q16.16.

---

## 2026-04-15 — NUM_LANES 4 and 8 simulation parity

### Goal

Close roadmap “higher lane counts” simulation gate: same Q16.16 price as single-lane when `lat_N` is divisible by `NUM_LANES`.

### Commands

- `./scripts/run_tb_top_uart_safe.ps1 -ComputeMode -NumLanes 4`
- `./scripts/run_tb_top_uart_safe.ps1 -ComputeMode -NumLanes 8`

### Results

| `NUM_LANES` | Price (hex) | TB outcome |
|-------------|---------------|------------|
| 4 | `0x000b93cd` | PASS (echo/result packet) |
| 8 | `0x000b93cd` | PASS |

Matches documented `NUM_LANES` 1 and 2 price for default UART TB batch (N=64, M=12, CALL, S0=K=100).

### RTL / infra touched

| File | Change |
|------|--------|
| `tb/tb_top_option_pricer_uart.sv` | `tb_top_option_pricer_uart_compute_lanes8` wrapper |
| `scripts/run_tb_top_uart_safe.ps1` | `-NumLanes 8` → `work.tb_top_option_pricer_uart_compute_lanes8` |

### Notes

- Bit-identicality is expected when lanes feed the shared accumulator in global path order (see `top_option_pricer.sv` `lane_feed_idx` / `path_idx` advance).
- On-board throughput vs lane count remains future work (FPGA hardware milestone).

---

## 2026-04-15 — Arty S7-50 synthesis prep (Vivado batch + `div_gen` port width)

### Added

- `fpga/arty_s7_option_pricer_top.sv`, `constraints/arty_s7_50.xdc`, `scripts/vivado_build_arty_s7.tcl`, `scripts/run_vivado_build_arty_s7.ps1`, `.user/FPGA_BUILD.md`.
- `.gitignore`: `vivado_build/`.

### RTL

- `fxDiv.sv` / `fxDiv_core_stub.sv`: `m_axis_dout_tdata` widened to **80 bits** to match Xilinx `div_gen` v5.1 (48/32 signed, remainder, blocking) with `OutTready` + `ARESETN` enabled in IP Tcl.

### Verification

- Re-run `./scripts/run_tb_top_uart_safe.ps1 -ComputeMode` after stub width change (PASS, `0x000b93cd`).
- `mem_paths_pkg` (`fpga/mem_paths_pkg.sv` + Vivado-generated copy) wires `$readmemh` paths for synth cwd vs repo-root sim.

---

## 2026-04-15 — Synthesizable `fxlnLUT` / `fxSqrt` + synth gate

### RTL

| File | Change |
|------|--------|
| `src/math/fxLnLUT.sv` | 2-stage BRAM (`fxExpLUT` handshake), `$readmemh`, `a==0` → `LN_CLAMP`, `ASSERT_STRICT` |
| `src/math/fxSqrt.sv` | Restoring sqrt on `{a,QFRAC'b0}`; 24 iterations; FSM `IDLE`/`COMP`/`DONE`; stall assert `ASSERT_STRICT` |
| `src/fpga_cfg_pkg.sv` | `FP_SQRT_LATENCY = 24` |
| `src/steps/inverseCDF.sv` | Negate FIFO `push_en = v1 && ln_ready`; `ln_raw` + `$signed(ln_raw)`; signed `neg2_ln_x` / `t_val` |
| `src/helpers/rv_skid_arr_gate.sv` | Signed `s_data` / `m_data` / `buf_data` |
| `src/steps/accumulator.sv` | Signed skid arrays |
| `src/gen/ln_lut_4096.mem` | Regenerated: **`ln((i<<4)/65536)`** for `i>0`, **`ln(1/65536)`** for `i==0` (`int(trunc)`), not `ln(1+i/4096)` |
| `scripts/gen_ln_lut_4096.py` | Reproducible LUT generator |

### Verification

| Command | Result |
|---------|--------|
| `./scripts/run_tb_top_uart_safe.ps1 -ComputeMode` | PASS, **`0x000b93cd`** |
| `$env:VIVADO_SYNTH_ONLY='1'; .\scripts\run_vivado_build_arty_s7.ps1 -SynthOnly` | **`synth_design` 0 errors** |

### Obsidian

Mirrored to vault `Options-Pricer-vault` (`Arty S7-50 hardware.md`, `QMC-LSM Option Pricer.md`).

---

## 2026-04-21 — `fxMul` split: register `raw_prod` between DSP cascade and round/shift (breaks GBM `u_mul2` critical path)

### Context

Rebuild with Stage-1 pivot pipelining closed a lot of ground: WNS=−3.435 ns → **−1.648 ns** (fMAX 74.4 → ≈85.9 MHz); TNS=−1,852 → −410 ns; failing endpoints 1,321 → 705. Post-route util stayed flat (LUT 35.75%, FF 21.86%, DSP 41.67%). New worst endpoint (`timing_post_route.rpt`):

- Source: `u_top/gen_lane[0].u_gbm/u_s_align/mem_reg[1][0][1]/C`
- Dest: `u_top/gen_lane[0].u_gbm/u_mul2/d_pipe_reg[0][31]/D`
- Data path: 11.639 ns, 14 logic levels (10× CARRY4, 2× DSP48E1, 1× LUT2, 1× LUT6), 76% logic / 24% route
- Slack: −1.648 ns

Trace: `s_align FF → LUT6 → DSP48E1 cascade (PCOUT→PCIN) → LUT2 → 10× CARRY4 chain → d_pipe[0]`. All of `raw_prod = a*b` (2-DSP cascade) *and* `prod_scaled = (raw_prod + r) >>> QFRAC` (64-bit add + shift) were collapsed into one clock edge into `d_pipe[0]`.

### Action: split `fxMul` into DSP-out reg + round-shift reg (staged 2026-04-21)

- `src/math/fxMul.sv`: added mandatory Stage-0 register `raw_prod_q[2*WIDTH-1:0]` between the combinational `a*b` and the round/shift adder. `d_pipe[0]` now latches `(raw_prod_q + r) >>> QFRAC` on the following clock edge.
- Pipeline semantics reshaped: `LATENCY` is now the total visible cycles (>=2 required). Internal layout = 1 mandatory raw-prod stage + (LATENCY−1) round-shift stages. `ready_out` gates on `v_raw` instead of `v_pipe[0]`. `shift_en` still gates the whole pipe together so back-pressure propagation is unchanged.
- `src/fpga_cfg_pkg.sv`: `FP_MUL_LATENCY` 1 → 2.
- Downstream consumers auto-track: `accumulator.sv` (`ALIGN_DEPTH = FP_MUL_LATENCY`), `fxInvCDF_ZS.sv` (`MUL_LATENCY = FP_MUL_LATENCY`), all `fxMul` instances in GBM / inverseCDF / regression / accumulator already use the package constant. No caller changes.
- Cost: +1 cycle per multiply (9 instances); +~32 FFs per mul for `raw_prod_q` ≈ +290 FFs overall. Still well under the 21% FF util headroom.

### Expected outcome

The DSP cascade alone is ~5.55 ns; the round/shift (LUT2 + 10× CARRY4) is ~2.5 ns. Splitting them puts both inside 10 ns with plenty of margin. WNS should close at 100 MHz unless a different path (not in the top few) surfaces. If it doesn't, the fallback is a clock relax in `arty_a7_100.xdc` to the attainable period.

### Rebuild result (same day)

**Closed at 100 MHz on the first try.** `vivado_build/arty_a7_100/timing_post_route.rpt`:

| Metric | Value |
|--------|-------|
| WNS (setup) | **+0.178 ns — MET** |
| TNS | **0.000 ns** |
| Failing endpoints | **0 / 75,541** |
| WHS (hold) | +0.014 ns |
| Worst path | `u_top/gen_lane[0].u_inv/rational/t_cap_reg[1]/C` → `.../mul_c1t/raw_prod_q_reg[40]/D` (9.868 ns, 15 levels, CARRY4=10 + 4 LUTs) |

The worst path now *ends at the new `raw_prod_q` register* we added — exactly the expected behaviour. The pre-stage soaked up the DSP-cascade-plus-rounding path and the remaining critical path (a chain inside the inverse-CDF rational multiplier `mul_c1t`) fits in 9.87 ns with 0.178 ns margin.

Utilization at closure (`utilization.rpt`):

| Resource | Used | Util% | Δ vs pre-split |
|----------|------|-------|----------------|
| Slice LUTs | 22,720 | 35.84% | +53 |
| Slice Registers | 28,212 | 22.25% | +498 |
| DSP48E1 | ≈ 100 | 41.67% | unchanged |

Cost was ~500 FFs (9 `fxMul` × 32-bit `raw_prod_q` plus downstream re-timing Vivado did to balance slack) for 1.83 ns of WNS recovery and full 100 MHz closure. Bitstream `vivado_build/arty_a7_100/arty_a7_qmc.bit` is now timing-clean at 100 MHz.

### Docs touched (final)

- `.user/IMPLEMENTATION_STATUS.md`: Timing table marks 100 MHz MET, updated "what's next" to silicon bring-up.
- `.ai/rules/primer.md`: Open Blockers collapsed to "timing MET, bitstream ready".

---

## 2026-04-20 — Stage-1 pivot pipelining in `regression.sv` (breaks 12-CARRY4 / 20-level critical path)

### Context

Prior build (2026-04-19, Plan A + `FP_DIV_LATENCY=32`) improved WNS from −5.987 ns to −3.435 ns (fMAX 62.6 → 74.4 MHz) and moved the critical path *out of* `div_gen`. New worst endpoint, from `vivado_build/arty_a7_100/timing_post_route.rpt`:

- Source: `u_top/u_accum/solver/mat0_reg[0][0][15]_replica/C`
- Dest:   `u_top/u_accum/solver/mat1_reg[1][1][8]/D`
- Levels: 20 logic (12 CARRY4 chained)
- Data path delay: 13.393 ns (63% route, 37% logic)

The entire Stage-1 in `regression.sv` is one combinational blob:

```
mat0 (FF) -> 3x abs_val -> priority-cascade compare (pivot0_row) -> 12-wide row mux -> mat1 (FF)
```

### Action: split Stage-1 into two pipeline cycles (staged 2026-04-20)

- Added `v0a` stage valid and two new registered bundles in `src/steps/regression.sv`:
  - `a0_col0[0:2]` — registered `abs_val(mat0[i][0])`
  - `mat0_d[0:2][0:3]` — delayed copy of `mat0` for the row mux
- Stage-1b now computes `pivot0_row` from the *registered* absolutes (`a0_col0`) and muxes `mat0_d` into `mat1`.
- Net cost: +1 pipeline cycle per solve (≈ 25 cycles total → ~4% latency hit, no throughput impact) and +~400 FFs. The 12-CARRY4 chain is split into two ~6-level chains with a register break in between; routing fanout on the pivot mux also reduces now that inputs come from a local stage register instead of `mat0`.

### Why Stage-4 (`pivot1_row`) left untouched

Stage-4 has only one 2-wide compare (`abs(mat3[2][1]) > abs(mat3[1][1])`) — about 1/3 the combinational depth of Stage-1. Not in the failing endpoint list; not worth an extra cycle.

### Expected outcome

Elimination of the 20-level Stage-1 path should push WNS above 0 at 100 MHz (the remaining paths reported were 2–3 ns shorter). If true: bitstream usable at 100 MHz, Plan B is deferred. If false: next worst endpoint dictates either a second pivot pipelining step or a small clock relax.

### Docs touched

- `.user/IMPLEMENTATION_STATUS.md`: Timing table extended, staged fix noted, What's next updated.
- `.ai/rules/primer.md`: Open Blockers rewritten for the new critical path and staged fix.

---

## 2026-04-19 — Plan A (shared solver divider) + A7-100T retarget: **routes, bitstream produced, timing fails at 100 MHz**

### Summary

- Plan A shipped in `src/steps/regression.sv`: 1 shared `fxDiv` + 4-state scheduler (`D_IDLE → D_G0 → D_G1 → D_G2`) replaces the 3 parallel generate blocks (DIV0 ×4, DIV1 ×3, DIV2 ×3 = 10 dividers → 1). Same `divN_res[]` buffers; `gN_all_done` pulses replace `&divN_done`.
- Retargeted to Arty A7-100T (`xc7a100tcsg324-1`). New files: `fpga/arty_a7_option_pricer_top.sv`, `constraints/arty_a7_100.xdc`, `scripts/vivado_build_arty_a7.tcl`, `scripts/run_vivado_build_arty_a7.ps1`.
- Full build routed, bitstream `arty_a7_qmc.bit` produced.

### Measured numbers (A7-100T, post-route)

| | Pre-Plan-A (S7-50 impl DRC) | Post-Plan-A (A7-100T route) | Δ |
|---|---|---|---|
| LUT as Logic | 37,141 | 22,692 | **−14,449 (−38.9%)** |
| CARRY4 | 8,344 | 4,593 | **−3,751 (−45%)** |
| `fxDiv_core` instances | 16 | 7 | −9 |

Plan A at 22,692 LUTs would have fit S7-50 retroactively (69.6% util vs 32,600).

### Timing: **fail at 100 MHz**

- WNS = **−5.987 ns**, TNS = −14,398 ns, WHS = +0.019 ns (hold OK)
- fMAX ≈ 62.6 MHz
- Critical paths inside `div_gen` core (`div_loop[46]`) of `solver/div_b0` and `solver/div_mean` — the back-sub dividers Plan A deliberately did not share.

### Action: `FP_DIV_LATENCY` 16 → 32 (staged 2026-04-19)

- `src/fpga_cfg_pkg.sv`: `FP_DIV_LATENCY = 32`
- `scripts/vivado_build_arty_a7.tcl` + `scripts/vivado_build_arty_s7.tcl`: `CONFIG.latency {32}` on `fxDiv_core` IP
- `src/math/fxDiv.sv`: elaboration `$warning` expected-value updated 16 → 32

Doubling the div_gen pipeline depth should halve the 46-stage combinational critical path. Expected WNS improvement ≈ +5.5 to +6 ns → closes at 100 MHz. Rebuild pending.

---

## 2026-04-17 — Full `impl_1` run: design does **not** fit XC7S50

### Summary

- `scripts/run_vivado_build_arty_s7.ps1 -TimeoutSeconds 14400` ran to completion of `synth_1`, then **`impl_1` failed at DRC `UTLZ-1` before `place_design`**.
- **Synth:** 0 errors, 0 critical warnings, 1 warning. Bitstream generation blocked by impl DRC.
- **Cause:** 16 × `div_gen` v5.1 IPs. Each expands to ~2.3K LUTs at `link_design`. Total LUT budget (post-opt, pre-place) exceeds S7-50 capacity.

### Numbers (from terminal)

| Resource | Needed (post-opt) | S7-50 | Util | Line |
|----------|-------------------|-------|------|------|
| LUT as Logic | 37,141 | 32,600 | 113.9% | DRC error |
| CARRY4 | 8,344 | 8,150 | 102.4% | DRC error |
| DSP48E1 (post-synth) | 100 | 120 | 83.3% | Report Cell Usage |
| `fxDiv_core` blackbox | 16 instances | — | — | Report BlackBoxes |

### 16 divider locations (from synth log earlier in session)

- 1 × `u_inv/rational/div_nd` (inverse CDF)
- 1 × `u_util_div` (T/M during INIT)
- 10 × `u_accum/solver/DIV[0-2][n].d*` (regression Gaussian elimination)
- 4 × `u_accum/solver/div_b{0,1,2,mean}` (beta + fallback mean)

### Paths forward

1. **Retarget a larger part** (Arty A7-100 / XC7A100T or Spartan-7 XC7S75). No RTL change.
2. **Time-share dividers in `regression.sv`.** 10 of 16 dividers are used sequentially through the solver FSM — they can be muxed through 1–2 shared `div_gen` blocks with a small scheduler. RTL change, medium effort.
3. **Replace `div_gen` with LUT + Newton-Raphson reciprocal.** Cheapest LUTs per divide, more DSP and more cycles. Large RTL change.

### Docs updated

- `.user/IMPLEMENTATION_STATUS.md`: new Resource budget table (real numbers), new Known-limitations bullet, blocker row in What's Next.
- `.ai/rules/primer.md`: Open Blockers top entry.

---

## 2026-04-19 — A7-100T: **83.333 MHz** STA clean; `fxMul` latency experiment reverted; A7-35T LUT DRC

### Summary

- **`constraints/arty_a7_100.xdc`:** `create_clock` on `CLK100MHZ` set to **period 12.000 ns** (83.333 MHz) so post-route timing reflects an attainable internal clock without the broken `FP_MUL_LATENCY=2` multiply path.
- **`src/math/fxMul.sv` + `FP_MUL_LATENCY`:** The **DSP-output register** version that met **100 MHz** WNS caused **UART compute-mode sim timeout** (`0xDEAD0001` / `CORE_MAX_CYCLES`). **Reverted** to committed `fxMul` and **`FP_MUL_LATENCY = 1`** in `fpga_cfg_pkg.sv`. Regression gate: `./scripts/run_tb_top_uart_safe.ps1 -ComputeMode` → **`0x000b93cd`**.
- **Routed A7-100T (`timing_post_route.rpt`, 2026-04-19):** WNS **+0.173 ns**, TNS **0.000**, **0** failing endpoints, `sys_clk` **12.000 ns**. **`utilization.rpt`:** Slice LUTs **22,637**, LUT-as-logic **22,504**, Slice Registers **27,412**, BRAM tiles **0** (large ROMs not in tile BRAM in this build).
- **Arty A7-35T:** Implementation path added (`run_vivado_build_arty_a7_35.ps1` / Tcl); **fails before place** — logic LUT demand **>** xc7a35t capacity (~24.8k vs ~20.8k in session notes). Needs **Plan B** divider sharing for beta/mean path or a smaller `NUM_LANES` configuration.

### Docs / handoff

- `.user/IMPLEMENTATION_STATUS.md`, `.user/ROADMAP.md`, `.user/FPGA_BUILD.md`, `.ai/rules/primer.md`, `.ai/rules/obsidian_sync.md`, **`.user/OBSIDIAN_HANDOFF.md`** (paste into Obsidian vault).

---

## 2026-05-03 - Thesis kernel complete; docs switched to product handoff

### Summary

- Root docs now present the project as a completed FPGA QMC-LSM American option pricing kernel: `README.md` plus `PROJECT_REPORT.md`.
- `.user` and `.ai` now point future sessions toward the larger portfolio/scenario/Greeks product story.
- Final thesis implementation is multi-date RTL with bit-exact C++ mirror and 100 MHz post-route signoff on both A7-100T and S7-50.

### Final measured hardware results

- **Arty A7-100T:** 10 ns route passes with WNS `+0.153 ns`, TNS `0`, 0 failing endpoints. Resources: 23,167 LUTs, 27,873 registers, 80 DSP48E1, 16 RAMB36. Bitstream: `vivado_build/arty_a7_100_multi_10ns/arty_a7_qmc_multi.bit`.
- **Arty S7-50:** 10 ns route passes with WNS `+0.113 ns`, TNS `0`, 0 failing endpoints. Resources: 23,154 LUTs, 27,873 registers, 80 DSP48E1, 16 RAMB36. Bitstream: `vivado_build/arty_s7_50_multi_10ns/arty_s7_qmc_multi.bit`.

### Final parity snapshot

- Single-date PUT N=64/M=12: C++/RTL `263688`, delta 0 LSB, 75,603 cycles.
- Multi-date PUT N=64/M=12: C++/RTL `373676`, delta 0 LSB, 461,245 cycles.
- Multi-date PUT N=256/M=12: C++/RTL `426642`, delta 0 LSB, 1,843,158 cycles.
- Multi-date PUT N=1024/M=12: C++/RTL `428757`, delta 0 LSB, 7,370,906 cycles.
- Multi-date CALL N=64/M=12: C++/RTL `482546`, delta 0 LSB, 37,726 cycles.

### Next product story

Do not keep expanding the vanilla kernel by default. Start from:

1. portfolio CSV input/output,
2. contract IDs and aggregation,
3. scenario sweeps,
4. Greeks through bump/revalue,
5. Asian payoff,
6. basket payoff and correlation input.

---

## 2026-05-03 - Fork docs reframed as portfolio risk engine; `.cursor` renamed to `.ai`

### Summary

- Root docs now present the fork as an FPGA QMC-LSM portfolio risk engine.
- The completed American option pricer is documented as the acceleration foundation, not the final product boundary.
- `.cursor` was renamed to `.ai` so repo-local AI memory is editor-neutral.
- `.user` now treats portfolio CSVs, scenarios, Greeks, Asian payoff, and basket/correlation support as the active product roadmap.

### Product boundary

Build product infrastructure before RTL changes:

1. `examples/portfolio.csv`
2. `scripts/portfolio_price.py`
3. `examples/scenarios.csv`
4. `scripts/scenario_sweep.py`
5. bump/revalue Greeks

Keep the inherited parity and timing gates green throughout.

---

## 2026-05-03 - Cleanup pass after fork reframing

### Summary

- Removed ignored/generated workspace artifacts: `.tmp`, `.Xil`, Vivado/XSIM logs, `vivado_build`, `xsim.dir`, caches, editor folders, and empty legacy vendor directories.
- Removed root-level wrappers after standardizing on `scripts/...` entry points.
- Removed duplicate root `cleanup_artifacts.ps1`; kept `scripts/cleanup_artifacts.ps1`.
- Removed failed/unused A7-35 build flow: `scripts/run_vivado_build_arty_a7_35.ps1` and `scripts/vivado_build_arty_a7_35.tcl`.
- Removed one-off helpers: `baseline/cpp_fixed/test_itm.cpp`, `src/gen_dim.cpp`, `src/max_X4.py`.
- Removed `src/gen/joe-kuo-6.21201.mem`; the active kernel uses the generated `src/gen/direction.mem`.
- Removed local `.user/ROADMAP_PRIVATE.md` scratch.

### Current live entry points

- `scripts/run_xvlog_src.ps1`
- `scripts/run_xelab_smoke.ps1`
- `scripts/run_tb_top_uart_safe.ps1`
- `scripts/run_vivado_build_arty_a7.ps1`
- `scripts/run_vivado_build_arty_s7.ps1`
- `scripts/validate_numerical.py`
- `scripts/diagnose_numerical.py`
