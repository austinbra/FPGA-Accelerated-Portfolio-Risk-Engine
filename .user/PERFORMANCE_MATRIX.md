# Stored-Path Multi-Lane Performance Evidence

Last updated: 2026-06-24

This is the durable source for resume claims and future LLM handoffs. It
separates cycle-accurate simulation, post-route board results, optimized C++
timings, and financial-reference error so unlike quantities are not mixed.

## Implemented Architecture

- Every simulated spot is generated once and stored in lane-banked block RAM.
- Each lane owns its path and cashflow bank, so all lanes can read and write in
  the same cycle without a shared-memory port conflict.
- Independent paths are scheduled step-major through replicated
  Sobol/inverse-CDF/GBM pipelines.
- Lane-local feature workers accumulate exact 64-bit LSM sufficient statistics;
  the statistics are reduced globally before the shared regression solve.
- The final 64-bit average divider separates shift, compare, and subtract phases
  to remove a long timing path. This costs 128 cycles per complete price, only
  1.28 microseconds at 100 MHz.
- Active capacity is 1,024 paths by 50 simulated dates. Larger jobs need
  BRAM-sized batching; they are rejected rather than silently overflowing.

Stored path capacity is 51,200 Q16.16 values, or 1,638,400 logical bits
(200 KiB), plus 1,024 Q16.16 cashflows (4 KiB). Physical BRAM consumption is
higher because FPGA RAM primitives have width/depth granularity.

## Why 1,024 Paths And 12 Steps

1,024 is not a magic accuracy threshold. It is the largest currently validated
stored-path job, a power of two that is natural for Sobol QMC, divides evenly
across 1/2/4/8 lanes, gives the three-term LSM regression hundreds of in-the-money
samples in the studied cases, and fits the chosen BRAM budget. Twelve steps are
monthly exercise dates over a one-year option. They are a representative resume
workload, not a universal production setting.

More paths generally reduce QMC and regression sampling error. More dates make
the early-exercise grid finer. Both increase work approximately linearly, and
neither changes the Q16.16 arithmetic contract.

## Exact Four-Lane Workload Matrix

All rows are multi-date American PUT jobs with S0=K=100, r=5%, sigma=20%, T=1.
Every raw price matches the C++ RTL mirror exactly. UART time is excluded.

| Paths | Steps | Raw Q16.16 price | Core cycles | Time at 100 MHz |
|------:|------:|-----------------:|------------:|----------------:|
| 64 | 4 | 426,130 | 5,034 | 0.05034 ms |
| 64 | 12 | 373,676 | 15,802 | 0.15802 ms |
| 64 | 24 | 356,530 | 32,142 | 0.32142 ms |
| 64 | 50 | 389,580 | 67,604 | 0.67604 ms |
| 256 | 4 | 395,487 | 18,498 | 0.18498 ms |
| 256 | 12 | 426,642 | 59,754 | 0.59754 ms |
| 256 | 24 | 384,128 | 121,958 | 1.21958 ms |
| 256 | 50 | 385,641 | 257,140 | 2.57140 ms |
| 1,024 | 4 | 391,343 | 72,394 | 0.72394 ms |
| 1,024 | 12 | 428,757 | 236,362 | 2.36362 ms |
| 1,024 | 24 | 408,031 | 483,694 | 4.83694 ms |
| 1,024 | 50 | 396,582 | 1,017,700 | 10.17700 ms |

The 1,024x12 row sustains about 433,231 complete paths/s or 5.199 million
path-date evaluations/s. Across the larger rows, throughput stays close to
5 million path-date evaluations/s, which is the more transferable measure when
the number of exercise dates changes.

## Lane Scaling At 1,024 Paths By 12 Steps

Every lane count returns raw Q16.16 `428757` (`0x00068AD5`) exactly.

| Lanes | Core cycles | Time at 100 MHz | Scaling vs one lane | Speedup vs 7,370,906-cycle v1 |
|------:|------------:|----------------:|--------------------:|--------------------------------:|
| 1 | 720,474 | 7.20474 ms | 1.00x | 10.23x |
| 2 | 411,626 | 4.11626 ms | 1.75x | 17.91x |
| 4 | 236,362 | 2.36362 ms | 3.05x | 31.18x |
| 8 | 121,290 | 1.21290 ms | 5.94x | 60.77x |

The eight-lane row is simulation evidence, not a board-fit claim. The physical
A7-100T result is four lanes. Fixed initialization, shared regression, final
division, and lane synchronization explain why scaling is strong but sublinear.

## Routed Board Configurations

| Target / config | Clock | WNS | LUT | DSP | RAMB36 | 1,024x12 time | Status |
|-----------------|-------|----:|----:|----:|-------:|--------------:|--------|
| A7-100T, 4 lanes | 100 MHz | +0.144 ns | 45,875 (72.36%) | 180 (75.00%) | 66 (48.89%) | 2.364 ms | Headline routed deliverable |
| S7-50, 1 lane | 100 MHz | +0.310 ns | 23,399 (71.78%) | 84 (70.00%) | 65 (86.67%) | 7.205 ms | Routed |
| S7-50, 2 lanes | 95.24 MHz | +0.083 ns | 30,606 (93.88%) | 116 (96.67%) | 65 (86.67%) | 4.322 ms | Routed at relaxed clock; fails 100 MHz by -0.180 ns |

The A7-100T four-lane build is the fastest routed configuration. The S7-50
ceiling at 100 MHz is one lane; its two-lane configuration fits but only closes
at 95.24 MHz (10.5 ns, WNS +0.083 ns), so it is reported at that honest closing
clock and not claimed at 100 MHz. Eight lanes does not fit any evaluated board.

## Optimized C++ Comparison

Measured on a 13th Gen Intel Core i9-13905H, 20 logical CPUs, MinGW Release
`-O3 -DNDEBUG`. These are single-thread real-time means across 30 repetitions
of the exact 1,024x12 PUT, with raw price `428757` verified each iteration.

| C++ timing boundary | Mean | Median | Std. dev. | A7 four-lane speed factor (CPU / 2.36362 ms) |
|---------------------|-----:|-------:|----------:|--------------------------------------------:|
| Hot kernel: direction and path storage persistent | 1.285 ms | 1.283 ms | 0.055 ms | 0.54x |
| Pricing core plus path allocation | 1.336 ms | 1.332 ms | 0.148 ms | 0.57x |
| End-to-end plus direction-file load | 1.860 ms | 1.851 ms | 0.083 ms | 0.79x |

Thus the routed A7 engine is 1.27x to 1.84x slower than this optimized laptop
CPU, depending on the honest boundary. It is not defensible to claim a CPU
speedup for the physical four-lane board. The simulation-only eight-lane RTL
would be 1.06x faster than the hot C++ mean and 1.53x faster than the
file-loading mean, but it does not fit the evaluated boards.

The CPU wins because it runs at multi-GHz frequency with large caches and
out-of-order execution, while the FPGA is proven at 100 MHz, fits only four
replicated lanes on A7, and still performs serialized fixed-point inverse-CDF,
feature-worker, regression, and control phases. The FPGA's strongest measured
achievement is the 31.18x architectural improvement over its own v1 RTL while
preserving exact output, not a fabricated win over a modern i9.

## Legacy Single-Date Comparison

The legacy single-exercise engine and active multi-date engine price different
financial models, so their prices and runtimes are not an apples-to-apples
speedup comparison. The rows remain useful architecture evidence.

| Engine | Lanes | 1,024x12 cycles | 100 MHz time | Raw price |
|--------|------:|----------------:|-------------:|----------:|
| Legacy single-date | 1 | 1,206,483 | 12.06483 ms | 360,645 |
| Legacy single-date | 2 | 615,635 | 6.15635 ms | 360,645 |
| Legacy single-date | 4 | 320,211 | 3.20211 ms | 360,645 |
| Legacy single-date | 8 | 172,499 | 1.72499 ms | 360,645 |
| Stored multi-date | 1 | 720,474 | 7.20474 ms | 428,757 |
| Stored multi-date | 2 | 411,626 | 4.11626 ms | 428,757 |
| Stored multi-date | 4 | 236,362 | 2.36362 ms | 428,757 |
| Stored multi-date | 8 | 121,290 | 1.21290 ms | 428,757 |

The richer multi-date engine is faster here because stored paths and
interleaving eliminate the legacy controller's repeated/serialized work.

## Accuracy Evidence And Limits

- Hardware/software parity: zero Q16.16 LSB difference for all 12 performance
  matrix rows and all validated lane counts.
- The repository's 12-case, N=1,024/M=12 financial study reports average
  fixed-point attribution of 2.57 bps of spot for PUTs and 1.52 bps for CALLs;
  the worst fixed-point contribution is 4.92 bps of spot.
- Total estimator/model error versus the American CRR reference is larger:
  average 49.32 bps of spot for PUTs and 41.66 bps for CALLs, with a 94.36-bp
  worst case in that study. Do not describe total financial error as below
  0.5% across the whole grid.
- For the exact resume workload, the engine returns 6.54231 versus a 6.09019
  CRR reference. Most of that gap is QMC/regression/model error, not RTL error.

Longstaff-Schwartz is often described as a lower-bound estimator because a
suboptimal exercise policy cannot outperform the true optimal policy when it is
evaluated independently. This implementation fits and evaluates on the same
paths, uses a finite exercise grid, and has regression/quantization error, so it
is not guaranteed to remain below the CRR value in every finite sample. That is
an estimator issue even when the hardware works exactly as designed.

## Defensible Resume Framing

Strong claims:

- exact C++/RTL parity across 12 path-count/date-count workloads;
- 2.364 ms for the routed 1,024-path, 12-date A7 kernel at 100 MHz;
- 31.18x lower core-cycle count than the preserved regeneration-based RTL;
- 5.199 million path-date evaluations/s;
- maximum fixed-point attribution below 5 bps of spot in the documented
  12-case N=1,024 study.

Do not claim the eight-lane result as an A7/S7 board result, include UART time
inside a kernel number, compare single-date and multi-date prices as the same
financial workload, or call the C++ comparison apples-to-apples without naming
the timed boundary and CPU/compiler.
