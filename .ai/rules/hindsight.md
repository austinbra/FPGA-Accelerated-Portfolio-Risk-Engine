---
description: Learned behavioral patterns from past errors. Not retrieval; active behavior modification. Append new lessons, never delete lightly.
globs: ["**/*.sv", "**/*.py", "**/*.ps1"]
alwaysApply: true
---

# Hindsight: Learned Behavioral Patterns

These are not just facts to recall. They are rules that change how future work should be done.

## Product Fork Lessons

RULE: Treat the FPGA pricer as the foundation, not the whole product.
- The fork's value comes from repeated pricing: portfolios, scenarios, Greeks, path-dependent payoffs, and multi-asset products.
- Do not keep polishing vanilla-option demos unless validation breaks.
- Build host-side product workflows before changing RTL.

RULE: Keep three accuracy questions separate.
- C++/RTL parity proves the hardware implements the numerical contract.
- Financial references prove whether that contract is a good option-pricing method.
- Product reports prove whether portfolio/scenario/Greek outputs preserve assumptions and error visibility.

RULE: Event or sentiment features are optional.
- They belong only after scenario infrastructure exists.
- They must improve volatility, correlation, jump-risk, or scenario forecast quality.
- Do not make sentiment the primary project identity.

## Constant Definition Traps

RULE: Never use 1-bit signed literals for fixed-point constants.
- `1'sd1` is -1 in two's complement, not +1.
- `1'sd1 <<< 16` is -65536, not +65536.
- Always use `32'sd1 <<< QFRAC` or `fpga_cfg_pkg::FP_ONE`.

RULE: Never hand-compute Q16.16 literals when a helper exists.
- Integer overflow can silently corrupt precomputed constants.
- Use `fp_from_real()` or externally verified `32'sd` literals with elaboration assertions.

RULE: Elaboration assertions are required for precomputed real-valued constants.
- Compare against `fp_from_real`.
- Tolerance should usually be plus or minus 1 LSB.

## Pipeline Alignment Traps

RULE: Registered FIFO outputs cause one-cycle misalignment.
- `pop_data <= mem[rptr]` reflects the previous head.
- Use combinational read for the current head when alignment matters.

RULE: Event-driven shift registers break under sporadic throughput.
- A shift register advancing on input events can work at full throughput and fail with one sample in flight.
- Use event-alignment FIFOs with push on accept and pop on output valid.

RULE: Skid-buffer patterns are incompatible with multi-cycle compute blocks.
- A skid buffer assumes one-cycle accept behavior.
- Use a busy flag and started-pulse pattern for multi-cycle blocks.

## Fixed-Point Overflow Traps

RULE: Raw stock prices overflow Q16.16 polynomial regression.
- `S=100` leads to large powers that exceed Q16.16 range.
- Normalize by moneyness before regression.

RULE: Q0.32 to Q16.16 conversion is not just `$signed()`.
- Sobol outputs are unsigned Q0.32.
- Convert explicitly with `$signed({16'd0, sobol_out[31:16]})`.

RULE: LUT address wraparound corrupts interpolation at boundaries.
- Clamp `addr_next` at the final entry.

## Toolchain Traps

RULE: PowerShell `$proc.ExitCode` can be null with `Start-Process`.
- Check for null before treating it as failure.

RULE: Vivado `xvlog` uses `-d MACRO`, not `+define+MACRO`.
- `+define+` is VCS syntax and can be treated as a filename.

RULE: Vivado silently truncates 32-bit integer overflow in localparams.
- Precompute large constants externally or use safe helpers.

RULE: xsim wall time is not FPGA hardware speed.
- FPGA speed is `core_cycles / fclk_hz`.
- Use cycle counters and post-route timing, not simulation wall time.

## Workflow Traps

RULE: When execution hangs, kill and restart after checking generated locks.
- Stale `xsim.dir` locks can cause indefinite hangs.
- Do not sleep-retry a tool that is stuck.

RULE: Run Vivado compile, elaboration, and simulation gates sequentially.
- Parallel tool runs can contend for generated files and licenses.

RULE: Check git status before staging or committing.
- Multiple agent sessions or generated outputs can leave unrelated changes.
- Never revert unrelated user work.

## Algorithm Traps

RULE: `fxLnLUT` must compute `ln(x)`, not `ln(1+frac)`.
- Use range decomposition, normalize, look up the fractional part, and add `int_log2 * ln(2)`.

RULE: Square-root normalization must match the refinement domain.
- Do not mix normalized LUT input with unnormalized Newton refinement.

RULE: Regression pivot fallback must use the correct valid signal.
- Check pre-divide validity when a pivot is zero.
- Do not require one-cycle pulses to overlap multi-cycle valid flags.

## Pipeline Double-Valid Traps

RULE: Never trust pipeline `valid_out` width without empirical verification.
- Stubs and fast turnaround can expose double-collect bugs.
- Add drain guards when an FSM consumes pipeline output.

RULE: Add per-step collect prints as the first diagnostic for path pipeline bugs.
- Compare path, step, and `s_next` between configurations.
- Identical adjacent values usually reveal double collection or stale tokens.

RULE: A good final numerical match can mask a compensating bug.
- Validate step-level dynamics and token counts, not only final price.

RULE: Verify token count before trusting output.
- Assert that collected GBM outputs match expected path and step counts.

## Final Kernel Lessons

RULE: Sobol boundary handling is mandatory before inverse-CDF.
- Sobol index 0 and Q16.16 truncation can produce `u_q16=0`.
- Production policy: start at Sobol index 1 and remap truncated zero to one LSB.

RULE: Low-path fixed-point outliers are expected in LSM studies.
- At low N, regression and estimator noise dominate.
- Scale N and inspect attribution before touching RTL.

RULE: CALL early exercise must be financially justified.
- With `q=0`, American CALL early exercise is dominated.
- Suppress no-dividend CALL exercise instead of letting noisy LSM regression invent bias.

RULE: A latency parameter only helps timing if it splits the critical path.
- The real 100 MHz fix registered the raw multiply product before Q-format rounding/truncation.

RULE: Do not add path batching just because it was an early design idea.
- Final multi-date uses 16 RAMB36 on S7-50 and A7-100T.
- Add batching only if portfolio scheduling, larger `M`, larger state, UART throughput, or smaller boards prove a need.
