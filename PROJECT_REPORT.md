# Project Report: FPGA QMC-LSM Risk Engine

## Executive Summary

This repository is a corrected and extended fork of an FPGA-accelerated option
pricer. The current deliverable is a deterministic, fixed-point pricing kernel
with C++ and SystemVerilog implementations, a UART control plane, and validated
Artix-7 and Spartan-7 implementation points. Its natural next use is repeated
contract revaluation for portfolio scenarios and finite-difference Greeks.

The July 2026 validation pass materially changed the hardware evidence. A
misread Xilinx divider output packet and an unrealistically fast simulation
stub invalidated the previous bitstreams, FPGA cycle counts, routed utilization,
and CPU/FPGA ratios. The numerical C++ work and independent financial-reference
study were not invalidated. This report describes only the corrected state.

## Project Question

The engineering question is not simply, "Can an FPGA price an option?" A tree
already prices a single low-dimensional vanilla American option efficiently.
The more useful question is:

> Can a numerically sensitive pricing kernel be made deterministic and
> verifiable across Python orchestration, optimized C++, fixed-point RTL,
> routed FPGA hardware, and measured host transport, then reused many times for
> scenarios and Greeks?

That framing gives the project a defensible application boundary and exposes
skills that matter in quantitative development, FPGA design, and performance
engineering.

## Current Product Boundary

One request contains:

```text
paths, steps, S0, K, r, sigma, T, option_type
```

The multi-date core performs:

```text
Sobol index stream
  -> inverse-normal transform
  -> fixed-point GBM path generation
  -> stored path/date values
  -> backward Longstaff-Schwartz regression
  -> exercise decisions and discounted cashflows
  -> average and valuation-time intrinsic floor
  -> Q16.16 result plus cycle count
```

PUTs use discrete exercise dates `1..M-1`. No-dividend CALLs use the terminal
fast path. All active hardware arithmetic is signed Q16.16 unless an explicitly
wider accumulator or divider operand is required.

The present bump/revalue layer submits base, spot-up, spot-down,
volatility-up, and volatility-down requests with the same Sobol sequence. It
then calculates finite-difference delta, gamma, and vega. This is the seed of a
risk engine, but it is not yet a portfolio service.

## Hardware/Software Partition

### Python

Python is the correct home for:

- portfolio and scenario file formats;
- validation orchestration;
- experiment matrices;
- UART session management;
- aggregation, diagnostics, plots, and reports;
- comparison with independent financial references.

Python should not become a second hidden pricing implementation. It should make
workflows transparent and keep assumptions visible.

### C++

C++ is the executable specification and CPU comparison target. It provides:

- a bit-exact FPGA-style pricing path;
- a future reusable pricing-library API;
- Google Benchmark timing boundaries;
- fast tests for scenario and Greek orchestration;
- a practical place to learn ownership, interfaces, testing, and performance
  without waiting for FPGA implementation.

### SystemVerilog

SystemVerilog contains the streaming data path, fixed-point arithmetic,
scheduling state machines, path storage, lane replication, UART packet logic,
and board wrappers. RTL changes should be driven by a measured bottleneck or a
contract mismatch because each change has a much larger verification cost than
an orchestration-layer change.

### Recommended balance

The extension should use all three languages. A SystemVerilog-only portfolio
engine would spend scarce time rebuilding parsing, queues, and reporting in the
least ergonomic layer. A Python/C++-only extension would abandon the core FPGA
learning. The highest-value path keeps the pricing accelerator in RTL, extracts
a clean C++ library, and builds portfolio/scenario control in Python.

## Divider Defect and Correction

The generated Xilinx `div_gen` core is configured as a signed 48-bit dividend,
32-bit divisor, 48-bit quotient, 32-bit remainder design. Its 80-bit output is:

```text
[79:32]  signed quotient
[31:0]   signed remainder
```

The Q16.16 wrapper forms `dividend = numerator << 16`, so the quotient is
already in Q16.16 scale. The correct result assignment is therefore:

```systemverilog
assign result = core_dout[WIDTH +: WIDTH]; // bits [63:32]
```

The old selection, `[47:16]`, crossed the quotient/remainder boundary. It could
produce plausible-looking simulation behavior when paired with a custom stub,
but not the generated IP contract.

The second defect was temporal. The old stub produced a result in one cycle;
the generated IP accepts a request and returns after 32 waits. Scheduling logic
that calls division many times therefore had understated full-core cycle counts.

Corrections made:

- `src/math/fxDiv.sv` selects the correct quotient bits;
- `src/sim/fxDiv_core_stub.sv` packs quotient/remainder correctly;
- the stub now implements the 32-cycle blocking ready/valid behavior;
- `tb/tb_fxDiv.sv` checks signed cases, one-third truncation, negative divisor,
  divide-by-zero bypass, and exact wait count;
- `scripts/run_tb_top_uart_safe.ps1` can compile the generated behavioral VHDL
  divider model for claim-grade simulation;
- the evidence collector rejects stub-only full-core runs as claim-ready input.

No payoff, Sobol, GBM, regression, or exercise policy was changed by this
correction. It repaired arithmetic transport and scheduling evidence.

## Board Clock Correction

The Arty A7 and Arty S7 both provide a 100 MHz physical oscillator. An XDC
statement describes that incoming clock; it does not slow the oscillator.
Earlier work changed the S7 XDC period to 10.5 ns without generating a new
clock, so that timing result did not prove a 95.238 MHz physical core.

The corrected wrappers use an MMCM:

```text
100 MHz board clock
  -> 1 GHz MMCM VCO
  -> output divide selected from requested period
  -> BUFG core clock
```

The allowed generated periods are in 0.125 ns increments. The wrapper supplies
the corresponding integer `CORE_CLK_FREQ_HZ` to the UART transmitter. The XDC
remains a literal 10.000 ns physical-input constraint.

Reset deassertion is synchronized to the generated clock and distributed on a
BUFG. The valuation intrinsic was registered and row/path counters were narrowed
to the ranges they actually represent. This narrowed the S7 `scan_row` control
logic and reduced LUT pressure without changing pricing results. The final S7
worst path is route-heavy row-control enable logic; the final A7 worst path is
the regression accumulation datapath. Pipelining either would change the engine
schedule and needs a broader redesign.

## Parameterized Build Architecture

The board scripts are now the configuration source of truth:

- S7 accepts 1 or 2 lanes;
- A7 accepts 1, 2, or 4 lanes;
- 8 lanes remains simulation-only;
- period names are encoded in each output directory;
- illegal 7-series MMCM periods are rejected before Vivado starts;
- a complete in-process synthesis checkpoint is carried into implementation;
- optimization uses `ExploreArea`, `Explore`, `phys_opt_design Explore`, and
  route TNS cleanup;
- WNS and WHS must be nonnegative before bitstream generation;
- every passing build writes timing, utilization, route, DRC, a manifest, a
  bitstream, and one post-synthesis GUI project.

This avoids ambiguous directories such as `lanes2` or projects whose filename
says 10.5 ns while the netlist still contains a 100 MHz core.

## Corrected Implementation Results

| Board | Configuration | Period | WNS | WHS | LUT | Registers | DSP | BRAM |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Arty A7-100T | multi, 4 lanes | 9.500 ns | +0.121 ns | +0.008 ns | 44,768 | 49,241 | 180 | 66 |
| Arty S7-50 | multi, 2 lanes | 10.500 ns | +0.165 ns | +0.011 ns | 30,243 | 36,779 | 116 | 65 |

TNS and THS are zero for both canonical routes. Route reports contain no
failed, unrouted, partially routed, or overlapping nets.

The adjacent faster S7 10.375 ns trial failed with WNS `-0.228 ns`; the
adjacent faster A7 9.375 ns trial failed with WNS `-0.153 ns`. The passing
10.500 ns and 9.500 ns builds are therefore the selected 0.125 ns boundaries
for this Vivado 2025.1 strategy and seed, not guaranteed silicon limits.

## Corrected Functional and Cycle Results

Generated-divider-model parity:

| Board configuration | Workload | Raw price | Core cycles | Routed-clock time |
|---|---|---:|---:|---:|
| A7, 4 lanes | 1,024 paths x 4 steps | 391,343 | 91,302 | 0.867369 ms |
| A7, 4 lanes | 1,024 paths x 12 steps | 428,757 | 293,790 | 2.791005 ms |
| S7, 2 lanes | 1,024 paths x 4 steps | 391,343 | 159,398 | 1.673679 ms |

The generated vendor model and calibrated stub match on the canonical A7 raw
prices and cycles. The S7 2-lane 1,024 x 4 case was also rerun against generated
vendor IP. Stale lane-scaling rows were removed rather than treated as current
evidence; any new lane/workload claim must be simulated afresh.

## CPU Measurement Results

The benchmark exposes three complete-pricing boundaries:

- **Hot kernel:** Sobol directions and path storage persist.
- **Pricing core:** path allocation is included.
- **End to end:** direction-file loading is also included.

Release means over 15 repetitions:

| Workload | Hot kernel | Pricing core | End to end | FPGA 4-lane core |
|---|---:|---:|---:|---:|
| 1,024 x 4 | 0.485392 ms | 0.551170 ms | 0.889880 ms | 0.867369 ms |
| 1,024 x 12 | 1.187450 ms | 1.208134 ms | 1.611681 ms | 2.791005 ms |

The FPGA core is slightly shorter than the 1,024 x 4 end-to-end CPU boundary
but longer than that workload's persistent CPU boundaries. For 1,024 x 12, all
three CPU boundaries are shorter. This mixed result is more useful than a blanket
"speedup": it shows that architecture, workload, setup costs, and measurement
boundary determine the answer.

UART transport remains a fourth boundary and must never be added to or confused
with FPGA core time. The response returns the price and a 64-bit internal cycle
counter so those intervals can be reported separately.

The corrected S7-50 image returned raw price 391,343 and 159,398 cycles in all
30 physical repetitions. Core time was 1.673679 ms; guarded UART transport
p50/p95/p99 was 31.981/32.764/33.207 ms.

## Evidence Hierarchy

The project uses the following evidence levels:

1. C++ numerical and unit tests.
2. Focused RTL unit tests.
3. Full-core RTL with the calibrated stub.
4. Full-core RTL with generated Vivado behavioral IP.
5. Post-route timing, utilization, route, and DRC reports.
6. Programmed-board raw-price and cycle parity.
7. Repeated physical transport statistics.

Levels 1 through 7 are complete for the corrected S7 release. The A7 evidence
remains complete through Level 5 because no physical A7-100T was available.
The old zero-price S7 run is explicitly excluded; programming success alone is
not numerical validation.

## What Was Invalidated

The following should not be cited:

- the old `72,394` and `236,362` four-lane cycle counts;
- prior S7 and A7 utilization/timing rows from pre-fix netlists;
- the former S7 `...10p5ns_mmcm_verified` project;
- old bitstream hashes;
- ratios based on the old one-cycle stub;
- the physical S7 zero-price response as numerical validation;
- any claim that editing the 100 MHz XDC alone created a slower board clock.

The following remain independently meaningful:

- fixed-point C++ raw prices;
- CRR/Black-Scholes financial-reference calculations;
- Sobol direction data and common-random-number policy;
- UART framing and host error handling;
- qualitative architecture and software-engineering work.

## Extension Plan

### Phase 1: clean library boundary

Extract the pricing API from the C++ executable into a reusable library. Define
an immutable request, result, diagnostics, and explicit error status. Keep the
existing CLI as a thin adapter. This is high-value C++ practice and gives Python
and tests one stable interface.

### Phase 2: Python portfolio and scenarios

Create typed CSV/JSON schemas, validate contracts, assign deterministic IDs,
generate scenario shocks, and aggregate values. Start entirely on CPU so data
semantics can be learned without hardware debugging.

### Phase 3: deterministic Greeks

Reuse Sobol indices across base and bumped requests. Report bump sizes, raw
prices, finite-difference formulas, estimator noise, and CPU/FPGA parity per
job. Compare a subset with analytic European Greeks where applicable.

### Phase 4: batch scheduler

Keep one CPU worker pool or UART session open, submit many independent jobs,
retain ordering and job IDs, and separate queue, transport, and compute time.
Measure throughput and latency distributions at several batch sizes.

### Phase 5: hardware interface evolution

Only after the workload is understood, decide whether UART should become AXI,
PCIe, or Ethernet. Add request/result FIFOs and telemetry before changing the
pricing mathematics. This makes the performance case workload-driven.

### Phase 6: new financial products

Add one feature at a time with its own independent reference. Dividend yield is
a smaller extension; Asian and basket options require different state and
verification; correlated multi-asset paths materially change memory and math.

## Resume-Relevant Skills

A strong final presentation should demonstrate:

- numerical-method selection and limitations;
- fixed-point range and truncation decisions;
- bit-exact C++/RTL co-verification;
- ready/valid protocol debugging across vendor IP;
- FPGA clocking, CDC/reset discipline, synthesis, placement, routing, and STA;
- parameterized build automation and artifact provenance;
- benchmark-boundary design rather than headline-number selection;
- Python experiment orchestration and data validation;
- honest failure analysis and corrected evidence.

The divider correction is not an embarrassment to hide. Finding a
cross-layer error, invalidating affected claims, reconstructing the vendor
contract, and rebuilding evidence is exactly the kind of engineering judgment
worth discussing.

## Conclusion

The corrected project proves a coherent single-contract accelerator and a
reproducible A7/S7 implementation flow. It does not prove a universal speedup or
a finished portfolio engine. Its strongest result is the traceable chain from
financial contract to C++, RTL, generated vendor IP, routed hardware, and
measurement boundaries. That chain is now strong enough to support the next
portfolio/scenario/Greeks layer without carrying forward false hardware data.
