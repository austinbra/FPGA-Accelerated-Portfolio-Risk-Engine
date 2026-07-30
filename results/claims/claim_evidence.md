# Reproducible Claim Evidence

Status: **CLAIM-READY**

FPGA core latency is measured from acceptance of a complete RTL job through `result_valid`. It excludes UART, USB, Python, and host scheduling.

## Provenance

- Commit: `c031f4b24fc783fc0dc30e0185cfc2e6ae3850e6` (dirty worktree: `True`)
- Benchmark CPU: Intel64 Family 6 Model 186 Stepping 2, GenuineIntel
- Current host CPU: Intel64 Family 6 Model 186 Stepping 2, GenuineIntel
- C++ compiler: g++ (MinGW-W64 x86_64-msvcrt-posix-seh, built by Brecht Sanders, r3) 14.2.0
- Benchmark compiler: g++ (MinGW-W64 x86_64-msvcrt-posix-seh, built by Brecht Sanders, r3) 14.2.0
- Vivado: Vivado v.2025.1 (win64) Build 6140274 Thu May 22 00:12:29 MDT 2025
- Device/top: 7a100t-csg324 / arty_a7_option_pricer_top
- Core/lanes/clock: `top_mc_option_pricer_multi_stored` / 4 / 100 MHz (routed sys_clk Clock Summary)
- Source fingerprint: `8f577a64e569a4296cb2c375e4a0fe1da4cb59d3801b2ed0c45be42fc62b6802`
- Product/mode: PUT / multi

## Routed implementation

- WNS: 0.139 ns
- TNS: 0.000 ns
- Setup failing endpoints: 0
- Slice LUTs: 45955 (72.48%)
- Slice registers: 46905 (36.99%)
- DSPs: 180 (75.00%)
- Block RAM tiles: 66 (48.89%)

## Canonical workloads

| Workload | Raw Q16.16 | C++/RTL | Core cycles | Core latency (ms) | CRR error (bp spot) |
|---|---:|---|---:|---:|---:|
| 1024×4 multi PUT | 391343 | bit-exact | 72394 | 0.72394 | -11.8765 |
| 1024×12 multi PUT | 428757 | bit-exact | 236362 | 2.36362 | N/A |

## Explicit CPU/FPGA timing-boundary ratios

Each ratio below is `CPU mean real time / FPGA core time`. It applies only to the named CPU boundary and workload; it is not a general accelerator claim.

| Workload | CPU boundary | CPU mean (ms) | FPGA core (ms) | Boundary-specific ratio | Repetitions |
|---|---|---:|---:|---:|---:|
| 1024×4 | end to end | 0.967301 | 0.723940 | 1.336× | 15 |
| 1024×4 | pricing core | 0.844558 | 0.723940 | 1.167× | 15 |
| 1024×4 | hot kernel | 0.725242 | 0.723940 | 1.002× | 15 |
| 1024×12 | end to end | 2.076906 | 2.363620 | 0.879× | 15 |
| 1024×12 | pricing core | 1.841793 | 2.363620 | 0.779× | 15 |
| 1024×12 | hot kernel | 1.870528 | 2.363620 | 0.791× | 15 |

## Validation

All required parity, cycle, benchmark, and routed-report checks passed.

The CRR comparison is a financial reference for the single canonical 1,024×4 workload, not a global accuracy guarantee.
