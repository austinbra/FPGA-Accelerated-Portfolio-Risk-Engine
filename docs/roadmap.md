# FPGA Pricing Fabric Roadmap

## Purpose

The current repository proves a corrected, deterministic, single-contract
QMC-LSM FPGA kernel. The next objective is not a universal pricer that replaces
every closed form, tree, PDE, CPU, or GPU implementation. It is a queued,
multi-context FPGA pricing fabric that keeps stable high-volume work in
hardware, reuses stochastic work across related valuations, and is especially
useful for path-dependent early-exercise products.

The leading showcase is a Bermudan arithmetic-Asian option. It combines:

- a path state, the running average;
- exercise on a finite set of dates;
- a continuation-value estimate using both spot and average;
- repeated revaluation across contracts, scenarios, and risk bumps.

This is a direction to validate, not a claim that the FPGA is already the best
implementation or that QMC-LSM is always the best pricing method.

## Design Position

The target is a hybrid fabric rather than one monolithic pipeline:

```text
tagged request -> classifier and queues
                  |-> analytic/interpolation fast lane -> result queue
                  `-> shared Sobol/model path pipeline
                       -> configurable path state and payoff
                          |-> European reduction -> result queue
                          `-> stored-state LSM -> result queue
```

The short lane handles products such as European vanilla options without
forcing them through path generation or regression. The stochastic lane shares
Sobol generation, inverse-normal transformation, model evolution, discounting,
and reduction. European Asian jobs use a running-average state and bypass LSM.
Bermudan Asian jobs use the same forward work and invoke continuation
regression at their permitted exercise dates.

Hardware should be divided by reusable computation and measured bottlenecks,
not by giving every option label a completely separate engine. Per-class
queues, tagged results, and scheduler policy prevent long LSM jobs from causing
head-of-line blocking for short requests.

## Language and Validation Roles

### SystemVerilog and FPGA

The FPGA is the product and learning target. Stable, repeatedly used work
belongs in RTL when practical:

- request classification and job scheduling;
- Sobol and model-state generation;
- running path statistics and payoff evaluation;
- path/state storage required by early exercise;
- regression statistics, solve, and exercise decisions;
- shared scenario/path fan-out;
- FIFOs, job IDs, result ordering, and telemetry.

### C++

C++ is not a required future performance competitor. The existing fixed-point
mirror remains valuable as a bit-exact oracle for the implemented RTL. New C++
financial references should normally be straightforward, readable,
double-precision implementations that use the CPU's floating-point strengths.
Their purpose is quick experimentation, accuracy validation, and detection of
fixed-point or algorithmic error before a feature is committed to hardware.

Historical CPU timing evidence remains useful as recorded boundary evidence,
but the roadmap does not require an optimized all-core CPU implementation for
every new FPGA feature.

### Python

Python owns schemas, experiment generation, reference orchestration,
diagnostics, plots, and reports. It should not hide an unreviewed second pricing
model or sit in the latency-critical hardware data path.

## Pipeline Reality

Individual arithmetic and forward-path stages can be deeply pipelined and may
approach a small initiation interval. A complete LSM valuation cannot generally
accept and complete an independent contract every clock. At each exercise date
it has population-wide barriers:

1. accumulate sufficient statistics from eligible paths;
2. solve one common regression;
3. broadcast the coefficients;
4. update path cashflows and continue backward.

The correct concurrency goal is therefore overlapping independent path lanes,
jobs, and stages where memory contexts permit. Multiple contexts can keep the
forward engine busy while another context waits for a regression solve, but
they consume BRAM/URAM, bandwidth, and control resources. Accepting one request
header per cycle is not the same as completing one LSM contract per cycle.

## Gated Development Sequence

### Gate 0: preserve the corrected baseline

- Keep all corrected prices, cycle counts, timing reports, bitstreams, and
  evidence manifests unchanged.
- Require exact C++/RTL parity for the existing contract after each structural
  refactor.
- Keep the divider and clock corrections as permanent regression tests.

Exit condition: the existing claim collector still reproduces the corrected
baseline and no new-product claim is mixed into historical evidence.

### Gate 1: numerical range and estimator uncertainty

- Retain 64-bit sufficient statistics through a common scaling or
  block-floating normalization step, or evaluate a wider fixed-point solver.
- Do not independently saturate normal-equation entries into Q16.16; doing so
  can alter the regression system even when the accumulators themselves are
  wide.
- Add digitally scrambled Sobol replicas and report variation across replicas.
- Evaluate Brownian-bridge or PCA dimension ordering for multi-date paths.
- Separate policy fitting from valuation with held-out paths or cross-fitting.
- Add explicit overflow, saturation, conditioning, and fallback telemetry.

Exit condition: increasing path count no longer degrades the reference result
because of narrowing, and every stochastic price/risk result carries an
uncertainty or convergence study appropriate to the method.

### Gate 2: shared scenario and Greek work

- Introduce immutable tagged request/result records and random-stream identity.
- Replay or cache common normal increments rather than merely restarting a full
  job with the same Sobol indices.
- For GBM spot bumps, test scaling base paths where mathematically valid.
- Fan one path population into several strikes, payoffs, or scenarios when
  model parameters permit it.
- Compare bump Greeks with analytic, pathwise, or adjoint references where
  available; require bump-size convergence, especially for gamma.

Exit condition: a measured multi-request workload demonstrates less duplicated
work as well as validated risk numbers. Common random numbers alone do not meet
this gate.

### Gate 3: configurable European modes

- Add a European vanilla fast lane or bypass with a high-precision analytic
  reference.
- Add arithmetic-Asian running sum/average state and terminal payoff reduction.
- Add a geometric-Asian analytic reference or control variate.
- Avoid path storage and regression when the contract does not need them.

Exit condition: tagged mixed requests return correctly ordered results, and
each mode passes an independent accuracy surface rather than a single example.

### Gate 4: Bermudan Asian continuation

- Represent the Markov state as spot and running average, `(S, A)`.
- Begin with normalized quadratic basis
  `[1, S, A, S^2, S*A, A^2]`.
- Generalize moment accumulation and the solver interface so future sparse
  bases do not require rewriting the entire engine.
- Use holdout or cross-fit valuation and record exercise-policy diagnostics.
- Compare a simple low-dimensional case against a two-state PDE and a
  double-precision LSM reference.

Exit condition: price, policy, and Greeks are stable across path counts,
exercise grids, basis choices, Sobol scrambles, and held-out samples.

### Gate 5: queued multi-context fabric

- Add per-class FIFOs, job IDs, result reordering, backpressure, and telemetry.
- Decouple classification, forward generation, state/payoff processing,
  European reduction, and LSM processing with ready/valid boundaries.
- Add multiple path/cashflow contexts only after memory demand is measured.
- Protect short jobs from LSM head-of-line blocking.
- Replicate the measured bottleneck rather than assuming more path lanes always
  improve complete-job throughput.

Exit condition: a mixed trace reports per-class throughput, p50/p99 latency,
queue residence, stage utilization, memory pressure, power, and accuracy.

### Gate 6: transport, device scaling, and added state

- Choose AXI, PCIe, or Ethernet from measured request sizes and transport
  overhead; faster transport does not fix a slow or numerically weak kernel.
- Use a larger FPGA when additional DSPs, BRAM/URAM, memory bandwidth, or
  contexts address a demonstrated bottleneck.
- Compare GPU throughput only when the intended workload is large enough to
  usefully batch; retain CPU floating-point references for correctness.
- Add stochastic volatility, rates, or correlated assets one state at a time
  with a validated sparse regression basis.

Exit condition: end-to-end measurements show that the selected link and device
improve the intended workload, including accuracy and joules per valuation.

### Gate 7: ASIC-readiness decision

- Separate the portable pricing/scheduling core from Xilinx divider, BRAM,
  MMCM, UART, and board-shell assumptions.
- Define arithmetic, memory, and clock/reset macro interfaces.
- Preserve request, result, cycle, and bit-level contracts through replacement
  tests.
- Consider an ASIC only after product mix, precision, utilization, algorithms,
  deployment volume, and update requirements are stable.

An FPGA implementation is useful ASIC groundwork, but programmability is still
valuable while the numerical method and supported products are changing.

## Method Selection Boundary

The fabric should route rather than pretend one method is best everywhere:

| Product | Preferred validation/pricing baseline | FPGA roadmap path |
|---|---|---|
| European vanilla | closed form | analytic/interpolation fast lane |
| European arithmetic Asian | 1D/2D PDE or double-precision MC/QMC | shared paths plus average reduction |
| European geometric Asian | closed form | reference/control variate or fast lane |
| Low-dimensional American vanilla | tree or PDE | optional LSM mode, not presumed superior |
| Bermudan Asian | two-state PDE for simple cases; LSM as dimension grows | shared paths, `(S,A)` state, LSM |
| Higher-dimensional early exercise | high-precision MC/LSM and specialized references | long-term sparse-basis LSM target |

This makes Bermudan Asian a strong architectural demonstration without claiming
that it defeats a low-dimensional PDE on accuracy or that all European products
should be simulated.

## Success Criteria

The project is successful if it can show:

- preserved and reproducible historical evidence;
- numerical error attributed separately to sampling, regression, fixed point,
  and model choice;
- useful sharing across related risk requests;
- correct mixed-product routing and bounded queue behavior;
- transparent latency, throughput, utilization, power, and transport boundaries;
- a clear reason each implemented function belongs on the FPGA;
- a portable core that could inform an ASIC after the design stabilizes.

It does not need to claim that an FPGA is universally faster than a CPU or GPU,
or that QMC-LSM is the best algorithm for every option.
