# Corrected Performance Results

This document is the performance source of truth after the divider packet,
handshake, simulator-binding, and row-counter corrections. It keeps simulation,
post-route conversion, CPU benchmarking, UART transport, and physical hardware
as separate evidence boundaries.

## Measurement Boundaries

### FPGA core interval

```text
complete job accepted -> result_valid
```

It includes initialization, Sobol/GBM generation, stored paths, regression,
exercise decisions, averaging, and result writeback. It excludes UART, USB,
Python, and host scheduling.

```text
core_time = core_cycles / implemented_core_frequency
```

### FPGA transport interval

```text
host begins UART write -> host receives all four result words
```

This includes serial transfer, USB bridge behavior, Python/OS scheduling,
protocol handling, and the FPGA core interval.

### CPU boundaries

- **Hot kernel:** Sobol directions and path storage persist.
- **Pricing core:** path allocation is included.
- **End to end:** direction-file loading is also included.

Every reported ratio is:

```text
named CPU mean real time / FPGA core time
```

It is not a system speedup because the two sides intentionally name different
boundaries.

## Invalidated Evidence

Xilinx `div_gen` returns the 48-bit quotient in `[79:32]` after a
32-cycle contract. The old wrapper selected `[47:16]`, and an old XSim work
library could bind the one-cycle stub even when a vendor model was requested.
The regression controller also needed to retain accepted divider outputs.

Do not cite:

- the old 72,394/236,362 or 90,233/290,561 cycle pairs;
- the old S7 response with price zero and 116,733 cycles;
- pre-correction routed timing, utilization, bitstream hashes, or ratios;
- lane-scaling rows that were not rerun with the corrected generated model.

The fixed-point C++ prices and independent financial-reference studies did not
depend on the faulty RTL interface.

## Claim-Grade RTL Results

Fresh full-core XSim runs use the generated Vivado `div_gen` behavioral VHDL.
C++ and RTL raw Q16.16 results are bit-exact.

| Configuration | Workload | Raw Q16.16 | Decoded price | Core cycles |
|---|---|---:|---:|---:|
| A7 target, 4 lanes | 1,024 x 4 PUT/multi | 391,343 | 5.97142029 | 91,302 |
| A7 target, 4 lanes | 1,024 x 12 PUT/multi | 428,757 | 6.54231262 | 293,790 |
| S7 target, 2 lanes | 1,024 x 4 PUT/multi | 391,343 | 5.97142029 | 159,398 |

The 4-path x 4-step intrinsic PUT unit workload also passes with raw price
`0x00320000`. New lane/workload combinations must be rerun; they are not
inferred from these rows.

## Routed Implementations

| Target | Core period/frequency | WNS | WHS | LUT | Registers | DSP | BRAM |
|---|---|---:|---:|---:|---:|---:|---:|
| A7-100T, 4 lanes | 9.500 ns / 105.263 MHz | +0.121 ns | +0.008 ns | 44,768 (70.61%) | 49,241 (38.83%) | 180 (75.00%) | 66 (48.89%) |
| S7-50, 2 lanes | 10.500 ns / 95.238 MHz | +0.165 ns | +0.011 ns | 30,243 (92.77%) | 36,779 (56.41%) | 116 (96.67%) | 65 (86.67%) |

Both have TNS = 0, THS = 0, zero setup/hold failing endpoints, and complete
routes.

### Cycle-derived latency

| Target | Workload | Cycles | Routed-clock interval |
|---|---|---:|---:|
| A7 9.500 ns, 4 lanes | 1,024 x 4 | 91,302 | 0.867369 ms |
| A7 9.500 ns, 4 lanes | 1,024 x 12 | 293,790 | 2.791005 ms |
| S7 10.500 ns, 2 lanes | 1,024 x 4 | 159,398 | 1.673679 ms |

The A7 rows are post-route, cycle-derived intervals. The S7 1,024 x 4 interval
is also physically confirmed by the corrected bitstream's internal cycle
counter.

## Period Boundaries

The build scripts accept legal MMCM periods in 0.125 ns increments. For the
tested Vivado 2025.1 strategy and seed:

| Target | Passing selection | Adjacent faster failure |
|---|---|---|
| A7-100T, 4 lanes | 9.500 ns, WNS +0.121 ns | 9.375 ns, WNS -0.153 ns, TNS -14.851 ns |
| S7-50, 2 lanes | 10.500 ns, WNS +0.165 ns | 10.375 ns, WNS -0.228 ns, TNS -1.768 ns |

These bracket the selected configurations. They are not universal silicon
`fmax` guarantees.

## RTL Optimization Result

The low-risk optimization in this pass:

- registered the valuation intrinsic in the existing initialization state;
- narrowed row and path counters to their actual configured ranges.

This narrowed the S7 row-control logic and reduced final LUT use without
changing raw prices or cycle counts. The final S7 worst path is
`gen_output_row_reg[0]` to `scan_row_reg[4]/CE` and is 78.5% route delay;
the final A7 worst path is a 23-level regression accumulation path. Further
improvement needs placement exploration or pipelining with schedule
revalidation, so it was not folded into this correction.

## Google Benchmark Results

The source-of-record run used Release mode, MinGW-W64 g++ 14.2.0, 15
repetitions, and the same PUT/multi workloads on the recorded Intel Family 6
Model 186 host.

| Workload | CPU boundary | CPU mean real time | FPGA A7 core | CPU/FPGA ratio |
|---|---|---:|---:|---:|
| 1,024 x 4 | hot kernel | 0.485392 ms | 0.867369 ms | 0.560x |
| 1,024 x 4 | pricing core | 0.551170 ms | 0.867369 ms | 0.635x |
| 1,024 x 4 | end to end | 0.889880 ms | 0.867369 ms | 1.026x |
| 1,024 x 12 | hot kernel | 1.187450 ms | 2.791005 ms | 0.425x |
| 1,024 x 12 | pricing core | 1.208134 ms | 2.791005 ms | 0.433x |
| 1,024 x 12 | end to end | 1.611681 ms | 2.791005 ms | 0.577x |

For 1,024 x 4, the FPGA core is 2.6% shorter than the CPU end-to-end boundary
but longer than the persistent CPU boundaries. For 1,024 x 12, all three CPU
boundaries are shorter. This is a boundary-specific result, not a general
CPU/FPGA ranking.

## Google Benchmark Command

When Google Benchmark is already available locally:

```powershell
cmake -S baseline\cpp_fixed -B .tmp\bench-google -G "MinGW Makefiles" -DCMAKE_BUILD_TYPE=Release
cmake --build .tmp\bench-google --target qmc_google_benchmark -j
.\.tmp\bench-google\qmc_google_benchmark.exe `
  "--benchmark_filter=BM_(HotKernel|PricingCore|EndToEnd)MultiPutMatrix" `
  "--benchmark_repetitions=15" `
  "--benchmark_min_time=0.05s" `
  "--benchmark_report_aggregates_only=true" `
  "--benchmark_out=.tmp/google-benchmark-final.json" `
  "--benchmark_out_format=json"
```

CMake may try to fetch Google Benchmark when it is not installed. That fetch
requires network access; it is not evidence that the benchmark source failed.
The corrected source-of-record JSON was produced with the existing local
Release executable because no benchmark C++ source changed.

## Physical-Board Status

JTAG identified `xc7s50`, and the corrected 2-lane S7 bitstream passed 30
physical repetitions of the canonical 1,024 x 4 multi-exercise PUT:

- CPU and FPGA raw price: 391,343, bit-exact;
- FPGA core cycles: 159,398 in every repetition;
- core interval at 95,238,095 Hz: 1.673679 ms;
- UART transport p50/p95/p99: 31.981/32.764/33.207 ms.

The host uses guarded 32-bit request writes because unpaced FTDI bursts caused
framing errors. That guard is included only in transport time. The previous
zero-price run remains excluded, and there is no physical A7 measurement in
this pass.

## Claim Boundary

Defensible now:

- generated-IP C++/RTL bit-exact parity for the listed workloads;
- the listed core cycles and routed-clock conversions;
- complete A7/S7 post-route timing and utilization;
- corrected physical S7 price/cycle parity and transport distribution;
- the exact named CPU/FPGA ratios above;
- a parameterized, timing-gated lane/period build flow.

Not yet defensible:

- physical A7 latency;
- real board power;
- a generic CPU/FPGA speedup;
- production portfolio throughput;
- a universal maximum clock.

The machine-readable source of record is
[claim_evidence.json](../results/claims/claim_evidence.json).
