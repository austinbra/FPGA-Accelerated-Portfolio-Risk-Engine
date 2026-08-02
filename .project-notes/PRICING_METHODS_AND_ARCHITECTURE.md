# Pricing Methods and Architecture Background

This note records the reasoning behind `docs/roadmap.md`. It is background for
future design work, not evidence that the planned features are implemented.

## Contract taxonomy

- **European:** exercise only at maturity.
- **Bermudan:** exercise on a specified finite set of dates.
- **American:** exercise at any time up to maturity; a time grid approximates
  the continuous opportunity.
- **Asian:** payoff or exercise depends on an average of past underlying prices.
  Asian describes path dependence and can be combined with European, Bermudan,
  or American exercise rights.

For an arithmetic-average contract, the running average is an additional state.
A simple Bermudan Asian value can be written as `V(t,S,A)`. A PDE can represent
those two state variables directly and can be extremely accurate. Stochastic
volatility changes the state to `V(t,S,A,sigma)`; stochastic rates or more
assets add more dimensions. Grid cost then grows multiplicatively, while Monte
Carlo path cost grows less directly with state dimension.

Contract inputs such as strike or a spot bump are not automatically stochastic
state dimensions. A new dimension is created when another evolving random
variable or necessary path statistic must be carried through time.

## Method boundaries

Closed forms are best when a supported formula exists. Trees and finite-
difference PDEs are strong for low-dimensional vanilla early exercise. PDEs
remain a serious baseline for a simple Asian option when spot and average are
the only spatial states. Monte Carlo/QMC becomes more attractive for path
dependence, many risk factors, baskets, stochastic volatility/rates, or one
shared path population serving many contracts.

Longstaff-Schwartz Monte Carlo is one way to estimate early exercise. It
regresses discounted future cashflow onto functions of the state, compares the
estimated continuation value with immediate payoff, and works backward across
exercise dates. Its strengths are flexibility and less direct sensitivity to
state dimension than a full grid. Its weaknesses include sampling error,
regression bias, basis sensitivity, conditioning, memory traffic, and global
barriers between regression and exercise updates.

LSM is therefore a good general approximation engine, not the top method for
every individual product. Bermudan Asian is a useful target because it exercises
the shared path, state, regression, and scheduling architecture. It is not a
guarantee of better accuracy than a two-state PDE.

## Precision

Q16.16 path values and a 32-bit regression solve can be adequate over a bounded
domain, but the error is not described simply as "32-bit instead of 64-bit."
Normal-equation statistics can be accumulated in 64 bits and still be damaged
when independently narrowed or saturated before the solve. That changes the
relative scale of the matrix and right-hand side.

Candidate remedies are normalized state variables, common block scaling,
block-floating representation, wider fixed-point solver inputs, better-
conditioned bases, or a floating-point solver if device resources justify it.
Every choice needs overflow, conditioning, fallback, and output-error evidence.

## QMC uncertainty

A single deterministic Sobol run is reproducible but does not by itself provide
a conventional sampling error bar. Digitally scrambled Sobol replicas preserve
low-discrepancy structure while allowing variation across independent scrambles
to estimate uncertainty. Brownian bridge or PCA can place important path
variation in earlier Sobol dimensions and may improve convergence.

Exercise regression can introduce optimistic policy bias when the same paths
both fit and value the policy. Held-out paths or cross-fitting should be tested
before increasing hardware scale.

## Scenarios and Greeks

Restarting the same Sobol indices for base and bumped valuations gives common
random numbers and can reduce variance in price differences. It does not avoid
recomputing the same work and does not make a bad bump size correct.

Potential sharing includes replaying normal increments, scaling GBM paths for
spot bumps when mathematically valid, evaluating many strikes/payoffs from one
path population, and computing compatible scenarios together. Volatility bumps
still change the path evolution, but they may share the random increments. Rate,
model, and calibration changes require their own validity analysis.

Finite-difference Greeks should be checked across bump sizes and against
analytic, pathwise, likelihood-ratio, or adjoint values where those methods are
valid. Gamma is especially sensitive to noise and exercise-boundary movement.

## FPGA, CPU, and GPU roles

An FPGA can accept individual streaming requests, produce deterministic cycle
behavior, connect closely to network/market-data logic, implement custom
arithmetic, and deliver strong throughput per watt. A CPU can also accept and
act on one request immediately; it does not inherently require batching. Its
strengths include flexible control, large memory, mature floating point, and
fast algorithm changes. A GPU is strongest when enough independent work exists
to amortize launch and transfer overhead and occupy many lanes.

For this project, future C++ is primarily a quick high-accuracy reference, not a
mandatory optimized CPU competitor. The FPGA must justify itself through the
intended streaming/mixed workload and hardware behavior, not by forcing an
unfair bit-exact fixed-point CPU comparison. Historical CPU measurements remain
recorded evidence about their explicitly named boundaries.

At an exchange, the most latency-sensitive FPGA work is often feed handling,
book building, signal evaluation, and order generation. A large LSM valuation
may be a near-line pricing/risk service rather than part of every order decision.
Eliminating a host round trip matters only if the required price really is on
the decision path and the FPGA already has the necessary state.

## Concurrency and transport

European jobs can bypass storage and regression. Bermudan/American LSM jobs
cannot simply flow through one early-exit pipeline at one contract per clock:
the regression coefficients depend on statistics from the path population, and
backward exercise dates depend on later cashflows. Multiple tagged contexts and
decoupled stages can overlap useful work, subject to memory capacity and
bandwidth.

PCIe, Ethernet, or AXI can reduce transport overhead or increase submission
throughput, but the correct link depends on placement and workload. A larger
FPGA provides more DSPs, BRAM/URAM, bandwidth, and job contexts. It does not
remove the LSM barriers, cure fixed-point error, or create a useful workload.

## ASIC direction

The FPGA can lay ASIC groundwork by separating a portable computation and
scheduler core from vendor memories, dividers, MMCMs, UART, and board wrappers.
An ASIC should follow only after precision, product mix, algorithms, memory
traffic, utilization, volume, and upgrade needs are stable. Hardening a design
too early would freeze the assumptions currently being investigated.
