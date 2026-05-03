# QMC-LSM-to-FPGA — Roadmap

> **What's already built:** see [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md)
> **How to verify:** see [`VALIDATION.md`](VALIDATION.md)

Last updated: 2026-05-02 (RTL multi-date v1 price parity plus A7-100T and S7-50 implementation completed)

---

## Completed: Arty A7-100T timing at **83.333 MHz** (STA)

**Done:** `constraints/arty_a7_100.xdc` constrains `CLK100MHZ` as **12 ns** `sys_clk` (83.333 MHz). Post-route **`timing_post_route.rpt`**: WNS **+0.173 ns**, TNS **0**, **0** failing endpoints. **`utilization.rpt`**: ~**22.6k** slice LUTs, ~**27.4k** FFs. Bitstream **`vivado_build/arty_a7_100/arty_a7_qmc.bit`**.

**Learning:** Closing **100 MHz** required a pipelined **`fxMul`** variant (`FP_MUL_LATENCY=2`); that revision **broke** UART compute-mode simulation (timeout / `0xDEAD0001`). Repo is back to **`FP_MUL_LATENCY=1`** and sim price **`0x000b93cd`**. For 100 MHz without RTL risk, next attempt needs a handshake-correct multiply split.

**Not done:** **Arty A7-35T** — impl stops at **LUT over-utilization** (~24.8k logic LUTs needed vs ~20.8k available). Needs Plan B (more divider sharing) or smaller configuration.

---

## Completed: Multi-lane simulation (not the same as silicon Priority 1b)

**Done:** `NUM_LANES=4` and `NUM_LANES=8` produce the same Q16.16 price as `NUM_LANES=1` (`0x000b93cd` with default TB params). Wrappers: `tb_top_option_pricer_uart_compute_lanes4` / `_lanes8`; run `./scripts/run_tb_top_uart_safe.ps1 -ComputeMode -NumLanes 4|8`.

**Deferred to silicon:** Actual throughput / fMAX vs lane count — measure on-board under **Priority 1b** when hardware is available.

**Constraint:** `lat_N` must be divisible by `NUM_LANES`.

---

## Priority 1a: A7-100T implementation + STA (no board required) — **done**

**Goal:** Bitstream + timing closure at the XDC clock target so the design is **ready** for Arty A7-100T.

**Done (checklist):**
1. Full build: `.\scripts\run_vivado_build_arty_a7.ps1 -TimeoutSeconds 14400`
2. `vivado_build/arty_a7_100/timing_post_route.rpt`: WNS ≥ 0 for `sys_clk` (**12 ns** → **83.333 MHz** in current `constraints/arty_a7_100.xdc`).
3. Bitstream path: `vivado_build/arty_a7_100/arty_a7_qmc.bit` (after successful impl).

**Throughput without silicon:** `.\scripts\run_virtual_a7_benchmark.ps1` or `python src/uart_host.py --mode benchmark --target virtual --param-file …` — DUT `core_cycles` from xsim × **1/fclk** (same STA fclk). See [`.user/FPGA_BUILD.md`](FPGA_BUILD.md).

---

## Priority 1b: Arty A7-100T silicon smoke test — **pending** (needs hardware)

**Goal:** Prove USB-UART, IO, and host flow on real silicon; compare to simulation.

**Steps (Arty A7-100T):**
1. Program `vivado_build/arty_a7_100/arty_a7_qmc.bit` (e.g. `.\scripts\program_arty_a7.ps1` or Vivado Hardware Manager).
2. Connect USB-UART; run `python src/uart_host.py --mode benchmark --target fpga --port COMx --param-file baseline\cpp_fixed\params_example.txt` (or `.\scripts\run_fpga_benchmark.ps1 -Port COMx`).
3. Confirm price vs `./scripts/run_tb_top_uart_safe.ps1 -ComputeMode` → **`0x000b93cd`** (same param semantics as your chosen `param` file / TB).

**Steps (Arty S7-50 — legacy / smaller part):** see [`.user/FPGA_BUILD.md`](FPGA_BUILD.md) — `scripts/run_vivado_build_arty_s7.ps1`. Pre–Plan-A impl did not fit; re-try only after confirming resource goals.

**Deliverable:** Optional hardware-measured price match; real UART round-trip time; **or** defer 1b entirely if you only need STA + virtual cycles (document which you used).

**S7-50 update:** multi-date v1 now fits and passes timing at 12 ns / 83.333 MHz with `.\scripts\run_vivado_build_arty_s7.ps1 -MultiExercise -ClockPeriodNs 12 -TimeoutSeconds 21600`. The 10 ns / 100 MHz route fits but misses setup timing by WNS `-1.742 ns`.

---

## Priority 2: Multi-exercise-date (full backward induction)

**Goal:** American option with M-1 exercise opportunities, not just step M-1.

**Current status:** RTL multi-date v1 is implemented behind compile parameter `MULTI_EXERCISE=1`. It supports `NUM_LANES=1`, stores one Q16.16 cashflow per path in synchronous BRAM, regenerates deterministic Sobol/GBM paths for each exercise date, performs PUT backward induction over steps `M-1..1`, and uses a no-dividend CALL terminal-payoff fast path. The C++ `fixed_baseline --exercise-mode multi` is now the bit-exact mirror for this RTL path: centered PUT basis `[1, S/K-1, (S/K-1)^2]`, RTL regression mirror, and beta-cap fallback at `4096`.

**Parity status:** passing trace parity for PUT `N=4/M=4`, PUT `N=8/M=12`, PUT `N=64/M=12`, and CALL `N=8/M=12`. Parameterized non-debug price parity passes PUT `N=64/M=12`, PUT `N=256/M=12`, PUT `N=1024/M=12`, PUT `N=4096/M=12`, PUT `N=8192/M=12`, and CALL `N=64/M=12`, all at `0` Q16.16 LSB delta. Single-date default parity remains passing. The `N=4096/M=12` multi-date PUT run returns `0x0006235d` in `25,685,613` core cycles, about `0.308227 s`; the `N=8192/M=12` run returns `0x0004e45d` in `51,371,559` core cycles, about `0.616459 s` at the current `83.333 MHz` STA target.

**Implementation status:** A7-100T multi-date full implementation passes in `vivado_build/arty_a7_100_multi`. Post-route timing at the 12 ns constraint is clean: WNS `+0.180 ns`, TNS `0`, 0 failing endpoints, fully routed. Routed utilization is `23,646` LUTs, `27,083` registers, `68` DSP48E1, and `16` RAMB36 tiles. S7-50 multi-date full implementation also passes at 12 ns: WNS `+0.082 ns`, TNS `0`, 0 failing endpoints, `23,648` LUTs, `27,173` registers, `68` DSP48E1, and `16` RAMB36 tiles. At 10 ns / 100 MHz, S7-50 fits and routes but misses timing with WNS `-1.742 ns`. The cashflow memory now infers as BRAM, so batching is not justified by current A7-100T or S7-50 BRAM pressure.

**Next gate:** optional `M=20` simulation spot checks, 100 MHz timing work if required, and host/system work. Path batching should be added only if `M=20`, larger portfolio runs, timing, or a smaller target FPGA proves the cashflow-BRAM design needs it.

**What changes:**
- Default top wrapper keeps the single-date engine unless `MULTI_EXERCISE=1`
- Multi-date v1 does not store `S[path][step]`; it stores cashflows and regenerates each path prefix per exercise date
- PUT training accumulates only ITM paths at each exercise step, then decisions update cashflow RAM in place
- CALL skips backward regression/decision while `q=0`
- Multi-lane multi-date and path batching remain later performance/resource phases

**Effort remaining:** Medium-high. The first RTL architecture is in place; production hardening is now cycle/resource/timing evidence rather than a blank-page FSM.

---

## Lower priority

- Multi-batch UART stability (`-Multibatch` flag)
- Lane-aware accumulator merging at higher lane counts
- Sobol dimension analysis vs pricing quality as M rises
