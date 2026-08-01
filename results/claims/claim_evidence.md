# Reproducible Claim Evidence

Status: **CLAIM-READY**

FPGA core latency is measured from acceptance of a complete RTL job through `result_valid`. It excludes UART, USB, Python, and host scheduling.

## Provenance

- Commit: `5a4e661547d494f83ea9ee519d54f797e735fa7e` (dirty worktree: `True`)
- Benchmark CPU: Intel64 Family 6 Model 186 Stepping 2, GenuineIntel
- Current host CPU: Intel64 Family 6 Model 186 Stepping 2, GenuineIntel
- C++ compiler: g++ (MinGW-W64 x86_64-msvcrt-posix-seh, built by Brecht Sanders, r3) 14.2.0
- Benchmark compiler: g++ (MinGW-W64 x86_64-msvcrt-posix-seh, built by Brecht Sanders, r3) 14.2.0
- Vivado: Vivado v.2025.1 (win64) Build 6140274 Thu May 22 00:12:29 MDT 2025
- Device/top: 7a100t-csg324 / arty_a7_option_pricer_top
- Core/lanes/clock: `top_mc_option_pricer_multi_stored` / 4 / 105.263 MHz (routed core_clk_unbuffered Clock Summary)
- RTL divider simulation: generated `div_gen` behavioral VHDL (fingerprinted in the machine-readable evidence)
- Source fingerprint: `7d050a1c4471743fb8091f2778203d3d13b216d5d2666a8fd089bf985b1465c2`
- Product/mode: PUT / multi

## Routed implementation

- WNS: 0.121 ns
- TNS: 0.000 ns
- Setup failing endpoints: 0
- WHS: 0.008 ns
- THS: 0.000 ns
- Hold failing endpoints: 0
- Slice LUTs: 44768 (70.61%)
- Slice registers: 49241 (38.83%)
- DSPs: 180 (75.00%)
- Block RAM tiles: 66 (48.89%)

## Canonical workloads

| Workload | Raw Q16.16 | C++/RTL | Core cycles | Core latency (ms) | CRR error (bp spot) |
|---|---:|---|---:|---:|---:|
| 1024x4 multi PUT | 391343 | bit-exact | 91302 | 0.86737 | -11.8765 |
| 1024x12 multi PUT | 428757 | bit-exact | 293790 | 2.79101 | N/A |

## Explicit CPU/FPGA timing-boundary ratios

Each ratio below is `CPU mean real time / FPGA core time`. It applies only to the named CPU boundary and workload; it is not a general accelerator claim.

| Workload | CPU boundary | CPU mean (ms) | FPGA core (ms) | Boundary-specific ratio | Repetitions |
|---|---|---:|---:|---:|---:|
| 1024x4 | end to end | 0.889880 | 0.867369 | 1.026x | 15 |
| 1024x4 | pricing core | 0.551170 | 0.867369 | 0.635x | 15 |
| 1024x4 | hot kernel | 0.485392 | 0.867369 | 0.560x | 15 |
| 1024x12 | end to end | 1.611681 | 2.791005 | 0.577x | 15 |
| 1024x12 | pricing core | 1.208134 | 2.791005 | 0.433x | 15 |
| 1024x12 | hot kernel | 1.187450 | 2.791005 | 0.425x | 15 |

## Validation

All required parity, cycle, benchmark, and routed-report checks passed.

The CRR comparison is a financial reference for the single canonical 1,024x4 workload, not a global accuracy guarantee.
