# Project Report: FPGA QMC-LSM Risk Engine

## Executive Summary

This repository is a corrected and extended fork of an FPGA-accelerated option
pricer. The current deliverable is a deterministic, fixed-point pricing kernel
with C++ and SystemVerilog implementations, a UART control plane, and validated
Artix-7 and Spartan-7 implementation points. The revised research target is a
queued, multi-context FPGA fabric that shares forward stochastic computation,
bypasses unnecessary stages, and targets path-dependent early exercise.

The July 2026 validation pass materially changed the hardware evidence. A
misread Xilinx divider output packet and an unrealistically fast simulation
stub invalidated the previous bitstreams, FPGA cycle counts, routed utilization,
and CPU/FPGA ratios. The numerical C++ work and independent financial-reference
study were not invalidated. This report describes only the corrected state.

## Project Question

The engineering question is not simply, "Can an FPGA price an option?" A tree
or low-dimensional PDE already prices a vanilla early-exercise option
efficiently, and an analytic formula is stronger for many European vanillas.
The more useful question is:

> Can a numerically sensitive pricing kernel be made deterministic and
> verifiable across high-precision references, fixed-point RTL, routed FPGA
> hardware, and measured host transport, then extended into a saturation-safe
> fabric that avoids redundant scenario work and supports path-dependent state?

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
risk engine, but it currently reruns the complete pricing job for every bump.
Common random numbers reduce variance; they neither eliminate duplicated work
nor guarantee an accurate Greek.

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

C++ provides two validation roles:

- the existing fixed-point path is a bit-exact oracle for implemented RTL;
- new readable double-precision models are quick financial references that use
  the CPU's floating-point strengths.

The recorded Google Benchmark results remain useful historical boundary
evidence. Future phases do not require an optimized CPU competitor or an exact
fixed-point C++ replica of every new FPGA feature.

### SystemVerilog

SystemVerilog contains the streaming data path, fixed-point arithmetic,
scheduling state machines, path storage, lane replication, UART packet logic,
and board wrappers. RTL changes should be driven by a measured bottleneck or a
contract mismatch because each change has a much larger verification cost than
an orchestration-layer change.

### Recommended balance

The FPGA is the design target. SystemVerilog should own stable repeated work:
request classification, queues, path/state generation, payoff processing,
optional LSM stages, result ordering, and telemetry. C++ should provide fast
high-precision experiments and bit-exact checks where needed. Python should own
schemas, validation orchestration, experiment matrices, and reports rather than
the latency-critical pricing path.

This partition also prepares for a possible ASIC: isolate a portable pricing
and scheduler core from Xilinx divider, BRAM, MMCM, UART, and board-shell
assumptions, but do not freeze the design while the method is still changing.

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
| Arty S7-50 | multi, 2 lanes | 10.500 ns | +0.013 ns | +0.013 ns | 30,310 | 36,816 | 116 | 65 |

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
100 physical repetitions. Core time was 1.673679 ms; zero-gap UART transport
p50/p95/p99 was 15.974/16.147/16.240 ms. The former 2 ms inter-word workaround
masked a host bug: pyserial's timeout was being reassigned after transmit,
reconfiguring the Windows COM handle while the FTDI could still be active.

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

## Revised Development Plan

The earlier software-first portfolio sequence has been replaced by numerical
and architectural gates. The complete acceptance criteria are in
[`docs/roadmap.md`](docs/roadmap.md).

1. **Numerical foundation.** Preserve sufficient-statistic range through common
   normalization or a wider solver; add scrambled Sobol replicas, uncertainty
   reporting, dimension reduction, and held-out/cross-fit LSM valuation.
2. **Shared scenario work.** Replay normal increments, share compatible paths
   across strikes, payoffs, and bumps, and require independent Greek and
   bump-size validation instead of five unquestioned full reruns.
3. **Configurable European modes.** Add an analytic/interpolation vanilla lane,
   arithmetic-Asian running-average reduction, and a geometric-Asian reference;
   bypass stored paths and regression whenever the contract permits.
4. **Bermudan Asian continuation.** Track `(S,A)`, begin with normalized basis
   `[1,S,A,S^2,S*A,A^2]`, and validate against a two-state PDE and a readable
   double-precision LSM implementation.
5. **Queued multi-context FPGA fabric.** Add per-class FIFOs, job IDs, result
   ordering, backpressure, multiple measured memory contexts, and telemetry;
   protect short jobs from LSM head-of-line blocking.
6. **Transport and device scaling.** Choose AXI, PCIe, or Ethernet from measured
   boundaries, use a larger FPGA only for demonstrated resource bottlenecks,
   and add stochastic dimensions one at a time with validated sparse bases.
7. **ASIC-readiness decision.** Separate the portable computation/scheduler
   core from Xilinx arithmetic, memory, clocking, UART, and board assumptions;
   harden only after the workload, method, precision, and utilization stabilize.

Forward samples may approach a small initiation interval, but a complete LSM
contract is not a one-cycle pipeline item. Each exercise date requires
population statistics, a common regression solve, coefficient broadcast, and
backward cashflow updates. Multiple contexts can overlap these stages where
memory permits; accepting request headers rapidly is not the same as completing
one Bermudan valuation per clock.

C++ remains a quick high-accuracy reference and, for existing RTL, a bit-exact
oracle. It is not a required future CPU competitor.

## Resume-Relevant Skills

A strong final presentation should demonstrate:

- numerical-method selection and limitations;
- option taxonomy and the distinction between inputs, path state, and
  stochastic dimensions;
- fixed-point range, normalization, saturation, and truncation decisions;
- randomized-QMC uncertainty, regression bias, and Greek stability;
- bit-exact C++/RTL co-verification;
- ready/valid protocol debugging across vendor IP;
- multi-context scheduling and the limits of LSM job pipelining;
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
reproducible A7/S7 implementation flow. It does not prove a universal speedup,
a production risk engine, or a fully pipelined heterogeneous fabric. Its
strongest result is the traceable chain from financial contract to C++, RTL,
generated vendor IP, routed hardware, and measurement boundaries. The revised
plan uses that chain to address numerical range, uncertainty, redundant risk
work, path-dependent state, and only then multi-context hardware and deployment
scaling.
