# Portfolio Risk Engine Extension Lab Manual

Last updated: 2026-06-23

## Purpose Of This Manual

This manual is a learning-first plan for extending the existing FPGA QMC-LSM American option pricer into a portfolio, scenario, and Greeks engine.

It is written for a student who has already touched C++, Python, quantitative modeling, fixed-point arithmetic, UART, and SystemVerilog, but wants to convert project exposure into first-principles ownership. The goal is not only to finish a larger project. The goal is to become able to explain, implement, test, profile, and defend every important design decision.

Treat this document like a laboratory course:

1. Read the concept section before touching code.
2. Write predictions before running experiments.
3. Implement the required work yourself.
4. Use AI only within the boundaries stated for each lab.
5. Save measurements and failed attempts.
6. Do not advance until the lab gate passes.

The finished project should demonstrate four kinds of ability:

- quantitative reasoning: option valuation, scenarios, finite-difference Greeks, QMC, and LSM;
- modern C++ design: types, APIs, ownership, error handling, tests, and performance;
- Python research infrastructure: data validation, orchestration, reporting, and experiment automation;
- hardware/software co-design: protocol design, backpressure, batching, cycle accounting, and honest end-to-end benchmarking.

## Executive Recommendation

### Use C++, Python, And SystemVerilog

Do not build the entire extension in SystemVerilog.

Portfolio parsing, scenario construction, Greek scheduling, report generation, and experiment analysis are poor uses of RTL. They change frequently, involve variable-sized structured data, and do not benefit from cycle-level hardware implementation.

Do not build the entire project in Python either.

Python is excellent for orchestration and research, but the pricing engine is where you should demonstrate C++ ownership, deterministic behavior, memory awareness, and performance engineering.

Recommended division of responsibility:

| Language | Responsibility | Why it belongs there |
|----------|----------------|----------------------|
| C++ | Reusable pricing library, contract validation, batch pricing loop, deterministic result types | Builds the low-level and systems depth you want to strengthen |
| Python | Portfolio CSVs, scenarios, Greek job generation, reports, plots, experiment automation | Fast iteration and clear research infrastructure |
| SystemVerilog | Existing pricing kernel, later job batching/queueing, protocol changes, counters, hardware verification | Demonstrates hardware/software co-design where hardware is actually useful |

The product should think of the FPGA as a pricing service, not as a place to store financial business logic.

```text
Python risk workflow
    -> normalized pricing jobs
    -> C++ backend or FPGA backend
    -> normalized pricing results
    -> aggregation and reports
```

### Recommended Implementation Order

1. Stabilize and understand the inherited kernel.
2. Extract a clean C++ pricing API from the current CLI.
3. Build a CPU-only portfolio engine.
4. Add scenarios.
5. Add Greeks with deterministic common random numbers.
6. Profile the software path.
7. Add a persistent FPGA backend.
8. Measure whether UART or kernel compute is the bottleneck.
9. Only then design an RTL batch/job protocol if the data justifies it.
10. Treat Asian and basket products as a separate advanced phase.

This ordering maximizes learning and reduces the chance that a difficult RTL change hides a basic product-modeling mistake.

## Should AI Build The C++ Library For You?

### Recommendation: No, Not End To End

The C++ library extraction is one of the highest-value learning tasks in the project. It requires you to understand how data enters the engine, where fixed-point conversion happens, who owns path memory, how Sobol state is constructed, how pricing modes differ, and how errors should be represented.

If AI writes this entire layer, the project may finish faster but it will reinforce the exact ownership gap you want to close.

Recommended AI division:

**You should implement:**

- `Contract`, `EngineConfig`, and `PriceResult` types;
- validation rules and error messages;
- the `priceContract(...)` API;
- conversion between floating-point inputs and Q16.16;
- the batch loop;
- at least the first tests for each API;
- the explanation of memory ownership and deterministic Sobol behavior.

**AI may help with:**

- reviewing an API proposal after you write it;
- generating adversarial test cases after you write the first tests;
- explaining compiler errors without providing a full replacement;
- reviewing CMake or build scaffolding;
- checking undefined behavior, lifetime, and integer-conversion risks;
- comparing your benchmark methodology against common mistakes;
- code review after a milestone is complete.

**AI should not do during the learning pass:**

- write an entire lab solution;
- replace a function before you can explain why yours failed;
- generate the RTL batch controller;
- choose every data structure without your written tradeoff analysis;
- write resume bullets before measurements exist.

### The Two-Attempt Rule

For educational tasks:

1. Attempt the problem without AI.
2. Write down the exact failure or uncertainty.
3. Make a second attempt using documentation, compiler output, waveforms, or a debugger.
4. Only then ask AI a narrow question.

Example of a good request:

> My `PriceResult` stores both raw Q16.16 and double values. I chose value semantics because results are small. Here is my implementation and failing test. Explain the lifetime or conversion issue without rewriting the function.

Example of a weak request:

> Build the pricing library and tests.

## Target V1 Scope

The first credible release should support:

- a CSV portfolio of vanilla PUT and CALL positions;
- contract IDs, underlying IDs, quantity, and contract multiplier;
- base valuation through CPU, FPGA, or both;
- named spot, volatility, rate, and time scenarios;
- delta, gamma, vega, rho, and theta through bump/revalue;
- per-position and portfolio aggregation;
- CSV and Markdown reports;
- deterministic inputs and repeatable results;
- CPU wall time, FPGA core time, UART time, and total workflow time;
- tests for parsing, transformations, aggregation, numerical behavior, and backend parity.

V1 should explicitly retain the inherited kernel limitations:

- geometric Brownian motion;
- `q=0` dividend yield;
- vanilla payoff;
- one asset per pricing job;
- Q16.16 fixed-point hardware path;
- multi-date PUT and no-dividend CALL terminal behavior.

Do not hide these limitations. Documented constraints make the project more credible.

## Proposed Repository Shape

Do not reorganize the entire repository immediately. First add an adapter around the working baseline.

Recommended incremental structure:

```text
baseline/cpp_fixed/
    pricing_api.h              new public API types and declarations
    pricing_api.cpp            new adapter over the existing pricing functions
    main.cpp                   gradually becomes a thin CLI
    pricing.cpp                existing numerical implementation
    ...

python/qmc_risk/
    __init__.py
    models.py                  portfolio and scenario domain models
    schema.py                  CSV parsing and validation
    jobs.py                    pricing-job expansion
    backends.py                CPU and FPGA backend interfaces
    scenarios.py               pure scenario transforms
    greeks.py                  bump definitions and finite differences
    aggregate.py               position and portfolio totals
    reports.py                 CSV and Markdown output

scripts/
    portfolio_price.py         command-line entry point
    scenario_sweep.py          optional focused entry point

examples/
    portfolio.csv
    scenarios.csv

tests/
    cpp/
    python/
    fixtures/
```

This layout exposes clear boundaries without moving the proven RTL.

## Final Architecture

```text
Portfolio CSV
    -> Python schema validation
    -> Contract and Position objects
    -> Scenario expansion
    -> Greek bump expansion
    -> PricingJob list
    -> backend interface
         -> C++ pricing library/CLI
         -> FPGA UART service
    -> PriceResult list
    -> position valuation
    -> portfolio aggregation
    -> CSV/Markdown report
```

Important distinction:

- A **contract** describes the derivative.
- A **position** describes ownership of a contract.
- A **market state** describes spot, volatility, rate, and valuation time.
- A **scenario** transforms a market state.
- A **pricing job** is one fully specified request sent to a backend.
- A **price result** is one backend response plus timing and status metadata.

If these concepts are mixed together, Greeks and scenario PnL become difficult to reason about.

## Feasibility And Time Budget

Expected focused effort:

| Phase | Hours | Part-time calendar estimate |
|-------|------:|-----------------------------|
| Foundation audit and C++ API | 20-35 | 2-3 weeks |
| CPU portfolio engine | 20-30 | 1-2 weeks |
| Scenarios and reports | 15-25 | 1-2 weeks |
| Greeks and numerical validation | 25-40 | 2-3 weeks |
| Profiling and persistent FPGA backend | 25-45 | 2-3 weeks |
| Optional RTL batch protocol | 50-90 | 4-7 weeks |
| Final benchmark and project presentation | 15-25 | 1-2 weeks |

A credible CPU plus existing-UART V1 is approximately 100-160 hours. A polished version with a new RTL batch path is approximately 160-250 hours.

## Sixteen-Week Learning Schedule

Assume 10-15 focused hours each week.

| Week | Focus | Main evidence |
|------|-------|---------------|
| 1 | Baseline ownership and dirty-worktree stabilization | Reproduction notes and architecture diagram |
| 2 | C++ API design | Header, invariants, written tradeoff record |
| 3 | C++ API implementation and tests | Thin CLI plus API tests |
| 4 | Batch design and backend contract | Batch benchmark and structured result format |
| 5 | Python models and CSV validation | Parser tests and example portfolio |
| 6 | CPU portfolio valuation | Position and portfolio report |
| 7 | Scenario engine | Named scenario PnL table |
| 8 | Greek mathematics and job generation | Bump policy document |
| 9 | Greek implementation and convergence | Stability plots/tables |
| 10 | End-to-end validation | Golden fixtures and failure tests |
| 11 | Profiling and Amdahl analysis | Timing breakdown |
| 12 | Persistent FPGA session | Multiple jobs over one serial session |
| 13 | Hardware batch protocol specification | Packet/state-machine document |
| 14 | RTL batch controller and testbench | Waveforms and assertions |
| 15 | CPU/FPGA portfolio benchmark | Honest throughput report |
| 16 | Documentation and interview preparation | Demo, report, resume bullets |

If school or recruiting pressure is high, stop after Week 12. That still produces a strong project.

## Compressed Eight-Week Route

For a near-full-time push:

| Week | Work |
|------|------|
| 1 | Labs 0-2 |
| 2 | Labs 3-4 |
| 3 | Labs 5-6 |
| 4 | Lab 7 |
| 5 | Labs 8-9 |
| 6 | Labs 10-11 |
| 7 | Lab 12 or benchmark-only alternative |
| 8 | Labs 13-14 |

Do not compress by skipping tests or measurements. Compress by limiting optional features.

## How To Keep A Lab Notebook

Create a dated Markdown note for each work session under a local notebook or `.user/lab_notes/` if you want it version-controlled.

Use this template:

```markdown
# Session YYYY-MM-DD

## Goal

## Prediction Before Running

## Work Performed

## Commands

## Results

## Failure Or Surprise

## Explanation In My Own Words

## Next Small Step
```

The prediction section matters. It forces you to build a mental model instead of merely reacting to output.

## Core Concept Primer

### 1. Contract Price Versus Position Value

The pricing kernel returns a value per option contract unit. A portfolio owns quantities of those contracts.

For position `i`:

```text
position_value_i = quantity_i * contract_multiplier_i * option_price_i
```

Portfolio value:

```text
portfolio_value = sum(position_value_i)
```

Quantity can be negative for short positions. The multiplier is commonly 100 for listed equity options, but it must be explicit rather than assumed.

Example:

```text
option price = 6.25
quantity = -3
multiplier = 100
position value = -3 * 100 * 6.25 = -1875
```

The option price is positive. The position value is negative because the portfolio is short.

### 2. Scenario PnL

A scenario changes one or more market inputs and reprices the portfolio.

```text
scenario_pnl = scenario_portfolio_value - base_portfolio_value
```

Example:

```text
base value = 42,000
spot-down-10-percent value = 48,500
scenario PnL = +6,500
```

The positive PnL suggests the portfolio benefits from the market moving down, perhaps because it owns puts or is short calls.

Scenarios are not Greeks. A scenario can contain large simultaneous shocks and captures nonlinear effects. Greeks are local sensitivities around the base state.

### 3. Finite-Difference Greeks

Let `V(S, sigma, r, T)` be the option value.

Central-difference delta:

```text
Delta approximately [V(S + hS) - V(S - hS)] / (2 hS)
```

Central-difference gamma:

```text
Gamma approximately [V(S + hS) - 2V(S) + V(S - hS)] / hS^2
```

Central-difference vega:

```text
Vega approximately [V(sigma + hsigma) - V(sigma - hsigma)] / (2 hsigma)
```

Central-difference rho:

```text
Rho approximately [V(r + hr) - V(r - hr)] / (2 hr)
```

Theta is often quoted as value change as calendar time passes. If `T` is time remaining, one-day theta can be defined as:

```text
Theta_1d = V(max(T - 1/365, epsilon)) - V(T)
```

State the convention in every report. There is no value in printing a number called `theta` if the sign and unit are ambiguous.

### 4. Why Common Random Numbers Matter

Monte Carlo Greek estimates can be noisy because each bumped price is itself an estimate.

Bad comparison:

```text
V(S + h) uses random stream A
V(S - h) uses random stream B
```

The difference includes both sensitivity and unrelated sampling noise.

Better comparison:

```text
V(S + h) uses deterministic Sobol stream A
V(S - h) uses the same deterministic Sobol stream A
```

Much of the pathwise noise cancels. The current deterministic Sobol setup is therefore useful for bump/revalue Greeks.

Common random numbers do not guarantee a stable Greek. You must still study bump size, path count, fixed-point quantization, and regression behavior.

### 5. Latency Versus Throughput

Latency answers:

> How long does one pricing job take?

Throughput answers:

> How many pricing jobs can the system complete per second?

A portfolio risk engine cares strongly about throughput because Greeks and scenarios create many jobs.

Measure at least:

```text
CPU engine time
CPU process-launch overhead
FPGA core cycles / fclk
UART transfer and waiting time
Python orchestration time
total portfolio wall time
```

Never report FPGA core time as end-to-end application time. Report both.

### 6. Amdahl's Law

If only part of the workflow is accelerated, total speedup is limited.

```text
speedup_total = 1 / [(1 - p) + p / speedup_accelerated]
```

If pricing is 80 percent of runtime and hardware makes pricing 10 times faster:

```text
speedup_total = 1 / [0.2 + 0.8/10] = 3.57x
```

This is why parsing, process startup, UART, and reporting must be measured.

## Lab 0: Freeze And Reproduce The Foundation

Working worksheet: [`lab_notes/LAB_00_FOUNDATION_AUDIT.md`](lab_notes/LAB_00_FOUNDATION_AUDIT.md)

### Estimated Time

6-10 hours.

### Learning Objectives

- distinguish inherited behavior from new behavior;
- understand the current data path;
- verify the baseline before adding features;
- practice disciplined Git and experiment recording.

### Important Current Condition

At the time this manual was written, the worktree had uncommitted changes in:

```text
src/helpers/rv_skid_arr_gate.sv
src/steps/GBM.sv
src/steps/sobol.sv
```

Do not overwrite or casually discard them. Inspect, understand, validate, and checkpoint them before beginning product work.

### Tasks

1. Run `git status --short` and `git diff --stat`.
2. Read the diff in each modified RTL file.
3. Write one paragraph explaining what each change appears to do.
4. Build the C++ baseline.
5. Run one known pricing case.
6. Run the smallest numerical parity gate available in your environment.
7. Draw the current path from CLI parameters to final price.

Suggested C++ build:

```powershell
cd baseline\cpp_fixed
g++ -std=c++17 main.cpp pricing.cpp linalg.cpp rtl_math.cpp sobol_wrapper.cpp utils.cpp -o fixed_baseline
cd ..\..
```

Suggested CPU run:

```powershell
.\baseline\cpp_fixed\fixed_baseline.exe --paths 64 --steps 12 --S0 100 --K 100 --r 0.05 --sigma 0.2 --T 1 --option-type 1 --fpga-style --exercise-mode multi --direction-file src\gen\direction.mem --lut-dir src\gen
```

### Explain Before Advancing

Answer without AI:

1. Where does floating-point input become Q16.16?
2. Who owns the `std::vector<Path>` memory?
3. Why is Sobol state constructed per process?
4. What changes between single, multi, and full LSM modes?
5. Why are parity and financial accuracy different tests?
6. What does `core_cycles` include and exclude?

### Deliverables

- baseline command transcript;
- current architecture diagram;
- explanation of the three dirty RTL diffs;
- a checkpoint commit or clearly documented reason not to commit yet.

### Gate

Do not proceed until the baseline result is repeatable and the existing changes are accounted for.

### AI Boundary

AI may explain unfamiliar syntax after your first reading. AI may not summarize the three RTL diffs before you attempt your own explanation.

## Lab 1: Design The Domain Model

### Estimated Time

6-10 hours.

### Learning Objectives

- separate financial concepts from transport formats;
- design small value types with explicit invariants;
- practice API design before implementation.

### Required Types

Design these C++ types on paper first:

```cpp
enum class OptionType { Call, Put };
enum class ExerciseMode { Single, Multi, FullLsm };

struct Contract {
    std::string contract_id;
    std::string underlying_id;
    double spot;
    double strike;
    double risk_free_rate;
    double volatility;
    double maturity_years;
    OptionType option_type;
};

struct EngineConfig {
    int paths;
    int steps;
    ExerciseMode exercise_mode;
    std::string direction_file;
    std::string lut_directory;
};

struct PriceResult {
    int32_t price_q16;
    double price;
    double elapsed_seconds;
    std::string backend;
    uint32_t status_flags;
};
```

This is an example, not a required final answer. Decide whether `spot` belongs in `Contract` or in a separate `MarketState`. For the long-term design, separating them is cleaner:

```cpp
struct ContractTerms {
    std::string contract_id;
    std::string underlying_id;
    double strike;
    double maturity_years;
    OptionType option_type;
};

struct MarketState {
    double spot;
    double risk_free_rate;
    double volatility;
};
```

Recommended choice for learning and future scenarios: separate contract terms from market state.

### Invariants To Define

At minimum:

- `contract_id` is nonempty;
- `underlying_id` is nonempty;
- spot is positive;
- strike is positive;
- volatility is nonnegative and bounded by a documented engine limit;
- maturity is positive;
- paths and steps are within hardware/software limits;
- option type is valid;
- Q16.16 conversion will not overflow.

### Design Exercise

Create a table with one row for each field:

| Field | Meaning | Unit | Valid range | Owned by | Scenario mutable? |
|-------|---------|------|-------------|----------|-------------------|

Example:

| Field | Meaning | Unit | Valid range | Owned by | Scenario mutable? |
|-------|---------|------|-------------|----------|-------------------|
| strike | exercise price | currency/unit | `> 0` and Q16-safe | contract | no |
| spot | current underlying price | currency/unit | `> 0` and Q16-safe | market state | yes |

### Questions To Defend

1. Why use `enum class` instead of integer flags inside the library?
2. Where should validation occur?
3. Should invalid input throw, return an error object, or terminate?
4. Should `PriceResult` contain both raw and floating values?
5. Which types should be immutable after construction?

### Recommended Error Strategy

For this project:

- library programmer errors: assertions only for impossible internal states;
- invalid user or CSV input: structured validation errors;
- backend failures: result or exception with context;
- CLI boundary: catch errors, print a concise message, and return nonzero.

Do not let the core library call `std::exit`.

### Deliverables

- a one-page API proposal;
- the field/invariant table;
- five example valid contracts;
- ten invalid-input cases;
- written answers to the defense questions.

### Gate

Ask another person or AI to review the proposal only after you can defend every field.

### AI Boundary

AI may review your proposal and identify missing invariants. AI may not create the first proposal.

## Lab 2: Extract A Reusable C++ Pricing API

### Estimated Time

12-20 hours.

### Learning Objectives

- turn a monolithic CLI flow into a reusable library boundary;
- practice value semantics and resource ownership;
- preserve bit-exact behavior during refactoring;
- make `main.cpp` a thin adapter.

### Current Problem

Today `main.cpp` performs all of these jobs:

1. parse CLI arguments;
2. convert doubles to Q16.16;
3. configure LUT paths;
4. construct the Sobol generator;
5. allocate path storage;
6. simulate paths;
7. select the induction algorithm;
8. measure elapsed time;
9. print human-readable output.

Only items 1 and 9 fundamentally belong to the CLI.

### Target API

Create `baseline/cpp_fixed/pricing_api.h` and `pricing_api.cpp`.

Conceptual signature:

```cpp
PriceResult priceContract(
    const ContractTerms& contract,
    const MarketState& market,
    const EngineConfig& config);
```

The function should:

- validate inputs;
- convert to Q16.16 exactly once;
- configure deterministic Sobol and LUT inputs;
- allocate required path storage;
- run the selected pricing mode;
- return structured output;
- avoid printing during normal operation.

Tracing may remain an explicit configuration option.

### Refactoring Rule

Do not rewrite the numerical implementation during this lab. The objective is to move orchestration behind an API while preserving behavior.

### Suggested Test Sequence

1. Write a test that calls the current executable and records a known result.
2. Implement `priceContract` by moving the existing orchestration.
3. Write a direct API test for the same contract.
4. Confirm raw Q16.16 equality.
5. Refactor `main.cpp` to call `priceContract`.
6. Confirm CLI output remains compatible with existing Python parsing.
7. Run the existing numerical parity gate.

### Tests To Write

- known multi-date PUT raw result;
- known no-dividend CALL result;
- repeat call produces identical raw price;
- invalid negative spot rejected;
- zero paths rejected;
- zero steps rejected;
- unsupported Q16.16 range rejected;
- single and multi modes select different expected behavior;
- trace disabled does not emit numerical lines.

### Ownership Questions

Answer in comments or design notes, not with unnecessary smart pointers:

- Why can `std::vector<Path>` be a local variable?
- When is it destroyed?
- Does `SobolGenerator` own or borrow its direction data?
- Is the engine thread-safe while trace state is global?
- What would have to change before parallel portfolio pricing?

The global `g_pricing_trace` is a useful discussion point. Do not automatically fix it. First explain why global mutable state complicates reentrancy and concurrency.

### Deliverables

- `pricing_api.h` and `pricing_api.cpp`;
- a thin `main.cpp`;
- direct API tests;
- parity evidence;
- short ownership/reentrancy note.

### Gate

CLI and direct API must return identical raw Q16.16 values for known cases.

### AI Boundary

You write the types and `priceContract`. AI may review the code for lifetime, conversion, and error-handling mistakes after tests pass or fail clearly.

## Lab 3: Introduce A Real Build And Test Boundary

### Estimated Time

8-14 hours.

### Learning Objectives

- understand translation units, static libraries, and linking;
- make tests independent from the CLI;
- improve build reproducibility.

### Recommended Build Products

```text
qmc_pricer_core     static library
fixed_baseline      CLI executable linked to the library
qmc_pricer_tests    test executable linked to the library
```

### Build-System Options

#### Option A: Continue With Raw `g++` Commands

Advantages:

- minimal complexity;
- transparent compiler invocation.

Disadvantages:

- awkward as targets and tests grow;
- weak portability and dependency management;
- less representative of production C++ workflows.

#### Option B: Add CMake

Advantages:

- clear targets and dependencies;
- standard C++ project skill;
- integrates tests through CTest;
- easier future Python binding build.

Disadvantages:

- another tool to learn;
- easy to cargo-cult without understanding.

### Recommendation

Use CMake, but write the first version yourself after manually compiling the library once.

Manual learning sequence:

```powershell
g++ -std=c++17 -c pricing.cpp pricing_api.cpp linalg.cpp rtl_math.cpp sobol_wrapper.cpp utils.cpp
ar rcs libqmc_pricer_core.a pricing.o pricing_api.o linalg.o rtl_math.o sobol_wrapper.o utils.o
g++ -std=c++17 main.cpp -L. -lqmc_pricer_core -o fixed_baseline
```

On Windows, the exact archive tool and executable names may differ. The point is to understand compile versus link stages before CMake hides them.

### Testing Framework Decision

Choices:

- simple in-repo assertion-based test executable;
- Catch2;
- GoogleTest.

Recommendation for v1: use a small assertion-based test executable or an already available framework. Do not spend a week integrating a test framework. The learning target is API behavior.

### Required CMake Concepts

Be able to explain:

- `add_library`;
- `add_executable`;
- `target_include_directories`;
- `target_link_libraries`;
- target-scoped compile features;
- Debug versus Release builds;
- enabling warnings;
- `enable_testing` and `add_test`.

Suggested warning policy:

```text
GCC/Clang: -Wall -Wextra -Wpedantic -Wconversion -Wshadow
MSVC: /W4
```

Do not enable `-Werror` until existing warnings are understood.

### Deliverables

- reproducible build configuration;
- separate core, CLI, and test targets;
- one-command test invocation;
- explanation of compile and link stages.

### Gate

A clean build directory must produce the CLI and tests without relying on stale object files.

### AI Boundary

You write the first CMake target graph. AI may review target scope and portability. AI should not generate the entire build file before you understand the manual compile/link sequence.

## Lab 4: Design The Backend Interface And Batch Strategy

### Estimated Time

6-10 hours.

### Learning Objectives

- separate pricing semantics from execution mechanism;
- compare subprocess, library binding, and service approaches;
- choose based on evidence rather than novelty.

### Backend Contract

Both CPU and FPGA backends should conceptually implement:

```python
class PricingBackend:
    def price_many(self, jobs: list[PricingJob]) -> list[PriceResult]:
        ...
```

The caller should not need to know whether the result came from a C++ process, direct library binding, UART, or simulation.

### C++/Python Integration Options

#### Option 1: One Subprocess Per Contract

Advantages:

- fastest to implement;
- uses the existing executable;
- process isolation makes failures simple.

Disadvantages:

- process startup overhead per job;
- brittle text parsing;
- poor throughput demonstration.

Use only as the first vertical slice.

#### Option 2: One Batch CLI Invocation

Python writes a batch request, C++ prices all jobs, and C++ writes structured results.

Advantages:

- simple language boundary;
- no binding dependency;
- one process startup;
- easy to benchmark.

Disadvantages:

- requires a batch format;
- file or pipe serialization remains.

Recommended V1 choice.

#### Option 3: `pybind11`

Advantages:

- natural Python calls into C++;
- no repeated process startup;
- strong demonstration of language interop.

Disadvantages:

- build and packaging complexity;
- Python interpreter and C++ lifetime issues;
- can distract from the risk engine.

Recommended as a stretch milestone after the batch CLI works.

#### Option 4: C ABI Plus `ctypes`

Advantages:

- no `pybind11` dependency;
- teaches ABI boundaries;
- stable narrow interface.

Disadvantages:

- manual memory and string marshalling;
- less idiomatic for rich C++ types.

Useful for systems learning, but not the fastest project route.

#### Option 5: Long-Running Worker Process

Advantages:

- amortizes startup;
- isolates C++ crashes;
- resembles a pricing service.

Disadvantages:

- IPC framing and lifecycle complexity;
- unnecessary before basic batching.

Do not start here.

### Recommendation

Implement in this order:

1. subprocess for one contract, only to prove the vertical path;
2. C++ batch CLI for the real CPU backend;
3. optional `pybind11` only if profiling shows the boundary matters or you want the interop learning.

### Structured Output

Do not parse prose forever. The batch interface should produce machine-readable fields such as:

```text
job_id
contract_id
price_q16
price
engine_seconds
status
```

If using CSV, document quoting and numeric formats. If using JSON, choose a real JSON library rather than writing string concatenation. A strict CSV schema is sufficient for V1.

### Experiment

Measure 100 tiny pricing jobs using:

1. one process per job;
2. one batch process.

Record:

- total wall time;
- pricing time reported by C++;
- process/orchestration overhead;
- jobs per second.

### Deliverables

- backend interface design;
- decision record comparing integration approaches;
- batch request/result schema;
- process-per-job versus batch benchmark.

### Gate

Choose the next integration mechanism from measurements and project goals, not because it sounds advanced.

### AI Boundary

AI may challenge your tradeoff table. You must write the first recommendation and benchmark plan.

## Lab 5: Build The Python Domain Model And CSV Schema

### Estimated Time

10-16 hours.

### Learning Objectives

- design explicit domain models in Python;
- validate structured input at the boundary;
- keep parsing separate from pricing and aggregation;
- write tests for malformed real-world data.

### Why Python Belongs Here

Portfolio files and scenario definitions are user-facing, variable-sized, and likely to change. Python's standard library provides reliable CSV parsing, dataclasses, enums, paths, and error reporting without pushing dynamic product concerns into RTL.

Python should create valid pricing jobs. It should not silently repair ambiguous financial data.

### Proposed Portfolio Schema

Start with:

```csv
position_id,contract_id,underlying_id,option_type,quantity,multiplier,spot,strike,r,sigma,T,paths,steps,exercise_mode
POS-001,SPY-P-100,SPY,PUT,10,100,100,100,0.05,0.20,1.0,1024,12,multi
POS-002,SPY-C-110,SPY,CALL,-4,100,100,110,0.05,0.20,1.0,1024,12,multi
```

This schema duplicates market state across rows. That is acceptable for the first vertical slice. Later, separate portfolio positions, contract terms, and market data into different files or objects.

### Proposed Scenario Schema

```csv
scenario_id,description,spot_rel,spot_abs,sigma_abs,r_abs,days_forward
BASE,Base market,0.0,0.0,0.0,0.0,0
SPOT_DOWN_10,Spot down 10 percent,-0.10,0.0,0.0,0.0,0
VOL_UP_5PTS,Volatility up 5 points,0.0,0.0,0.05,0.0,0
STRESS_COMBINED,Spot down 15 percent and vol up 10 points,-0.15,0.0,0.10,0.0,0
```

Define transformations explicitly:

```text
new_spot = base_spot * (1 + spot_rel) + spot_abs
new_sigma = base_sigma + sigma_abs
new_r = base_r + r_abs
new_T = max(base_T - days_forward/365, minimum_T)
```

Do not mix relative and absolute volatility bumps without naming them differently.

### Python Types

Suggested starting point:

```python
from dataclasses import dataclass
from enum import Enum

class OptionType(str, Enum):
    CALL = "CALL"
    PUT = "PUT"

@dataclass(frozen=True)
class ContractTerms:
    contract_id: str
    underlying_id: str
    option_type: OptionType
    strike: float
    maturity_years: float

@dataclass(frozen=True)
class MarketState:
    spot: float
    risk_free_rate: float
    volatility: float

@dataclass(frozen=True)
class Position:
    position_id: str
    contract: ContractTerms
    quantity: float
    multiplier: float
```

Use frozen dataclasses for value-like inputs. Scenario functions should return new values instead of mutating shared base objects.

### Validation Cases

Reject or explicitly handle:

- missing required columns;
- duplicate `position_id`;
- unknown option type;
- negative spot or strike;
- negative volatility;
- zero or negative maturity;
- noninteger paths or steps;
- paths outside supported engine limits;
- values that overflow Q16.16;
- blank IDs;
- NaN and infinity;
- negative multiplier;
- zero quantity, depending on your policy.

### Error Reporting Goal

Bad:

```text
ValueError: could not convert string to float
```

Better:

```text
examples/portfolio.csv row 7, field sigma: expected finite nonnegative decimal, got 'high'
```

### Tests

Write table-driven tests. Each invalid fixture should state:

- input row;
- expected error category;
- expected field name;
- expected row number.

### Deliverables

- `python/qmc_risk/models.py`;
- `python/qmc_risk/schema.py`;
- example portfolio and scenario files;
- parser and validation tests;
- schema documentation.

### Gate

No pricing code should run when validation fails. Parsing tests must not require the C++ executable or FPGA.

### AI Boundary

You design the schema and write the first five validation tests. AI may generate additional adversarial rows after your parser works.

## Lab 6: Implement CPU Portfolio Valuation

### Estimated Time

10-16 hours.

### Learning Objectives

- map positions to pricing jobs;
- separate unit price from position value;
- aggregate results without losing provenance;
- implement an end-to-end vertical slice.

### Pricing Job Model

A pricing job should be fully specified and immutable:

```python
@dataclass(frozen=True)
class PricingJob:
    job_id: str
    position_id: str
    contract_id: str
    scenario_id: str
    greek_id: str | None
    spot: float
    strike: float
    risk_free_rate: float
    volatility: float
    maturity_years: float
    option_type: OptionType
    paths: int
    steps: int
    exercise_mode: str
```

Keep `job_id` unique even when several jobs refer to the same position.

### Result Model

```python
@dataclass(frozen=True)
class PriceResult:
    job_id: str
    backend: str
    price: float
    price_q16: int | None
    engine_seconds: float | None
    transport_seconds: float | None
    status: str
```

### First Vertical Slice

1. Parse two positions.
2. Convert each to one base pricing job.
3. Send each job to the existing C++ backend.
4. Parse structured or temporary legacy output.
5. Compute position values.
6. Compute portfolio value.
7. Write `positions.csv` and `summary.md`.

### Aggregation Formula

```text
position_value = price * quantity * multiplier
portfolio_value = sum(position_value)
```

Test long and short positions. Test nonunit multipliers. Never infer exposure sign from option type; use quantity.

### Example Output

```csv
position_id,contract_id,quantity,multiplier,unit_price,position_value,backend,status
POS-001,SPY-P-100,10,100,6.25,6250.00,cpu,OK
POS-002,SPY-C-110,-4,100,2.10,-840.00,cpu,OK
```

Summary:

```text
portfolio_value = 5410.00
successful_positions = 2
failed_positions = 0
```

### Failure Policy

Choose and document one:

- fail the entire portfolio on the first failed job;
- continue and mark portfolio total incomplete;
- continue using a fallback backend.

Recommended V1: continue collecting results, but do not publish a normal portfolio total if any required position failed. Mark the report incomplete.

### Tests

- two long positions aggregate correctly;
- long and short positions aggregate correctly;
- multiplier is applied exactly once;
- duplicate result IDs are rejected;
- missing result IDs are detected;
- failed job makes summary incomplete;
- output ordering is deterministic;
- same input produces byte-stable CSV except timestamps.

### Deliverables

- CPU backend implementation;
- portfolio job generator;
- aggregation module;
- position and summary reports;
- end-to-end smoke fixture.

### Gate

The following conceptual command must work without FPGA hardware:

```powershell
python scripts\portfolio_price.py --portfolio examples\portfolio.csv --output-dir .tmp\portfolio_smoke --target cpu
```

### Explain Before Advancing

1. Why is unit price not portfolio value?
2. Where is quantity applied?
3. How do failed jobs affect totals?
4. Why must result IDs be joined rather than relying on list order?
5. What part of wall time is C++ compute versus process overhead?

### AI Boundary

You implement job generation and aggregation. AI may review error handling and test completeness.

## Lab 7: Implement The Scenario Engine

### Estimated Time

10-16 hours.

### Learning Objectives

- model transformations as pure functions;
- distinguish base state, scenario state, and PnL;
- generate a reproducible job graph;
- test nonlinear portfolio behavior.

### Pure Transformation Design

Preferred:

```python
def apply_scenario(base: MarketState, scenario: Scenario) -> MarketState:
    ...
```

The function must not mutate `base`.

Why pure functions help:

- base data cannot be accidentally contaminated by a prior scenario;
- tests are simple;
- scenario application order does not matter;
- parallel execution becomes possible later.

### Base And Scenario Job Graph

For `P` positions and `S` non-base scenarios:

```text
base jobs = P
scenario jobs = P * S
total jobs = P * (S + 1)
```

For 50 positions and 20 scenarios:

```text
total jobs = 50 * 21 = 1050
```

This multiplication is the beginning of the hardware throughput story.

### Scenario PnL At Two Levels

Position:

```text
position_scenario_pnl = scenario_position_value - base_position_value
```

Portfolio:

```text
portfolio_scenario_pnl = sum(position_scenario_pnl)
```

The sum of position PnLs must equal portfolio scenario value minus base portfolio value, within a documented rounding tolerance.

### Required Scenarios

Create at least:

- spot up 1 percent;
- spot down 1 percent;
- spot down 10 percent;
- volatility up 1 percentage point;
- volatility up 10 percentage points;
- rate up 100 basis points;
- one day forward;
- combined stress: spot down 15 percent, volatility up 10 points;
- invalid stress that would make spot or maturity nonpositive.

### Tests

- base state remains unchanged;
- relative spot shock is multiplicative;
- absolute rate and volatility shocks use correct units;
- days-forward reduces maturity;
- invalid post-shock state is rejected;
- scenario ordering does not change results;
- position PnLs reconcile to portfolio PnL;
- applying BASE produces zero PnL.

### Analysis Exercise

Construct a small portfolio containing:

- one long at-the-money put;
- one short out-of-the-money call;
- one long in-the-money call.

Before running, predict the sign of PnL for spot-down and volatility-up scenarios. Explain errors in your prediction afterward.

### Deliverables

- scenario model and parser;
- pure scenario transformation functions;
- job expansion;
- scenario PnL report;
- written prediction-versus-result analysis.

### Gate

All scenario PnL reconciliation identities pass.

### AI Boundary

AI may review scenario unit conventions. You must make and record the qualitative PnL predictions yourself.

## Lab 8: Design The Greek Methodology

### Estimated Time

8-12 hours before implementation.

### Learning Objectives

- understand finite-difference sensitivity estimation;
- define bump units and sign conventions;
- understand bias, noise, and quantization tradeoffs;
- design experiments before writing code.

### Required Greek Conventions

Write a `GREEKS_METHODOLOGY.md` section or note that defines:

- delta unit: value change per one currency unit of spot;
- gamma unit: delta change per one currency unit of spot;
- vega unit: value change per one volatility point, where one point is `0.01` absolute volatility;
- rho unit: value change per 100 basis points, where 100 bp is `0.01` absolute rate;
- theta unit: one calendar day of time decay.

The raw finite-difference quotient may use different units internally. Convert deliberately for reporting.

### Bump-Size Tradeoff

Too large:

- truncation error and nonlocal behavior dominate;
- gamma may represent a broad scenario rather than local curvature.

Too small:

- Q16.16 input conversion may map both bumps to the same raw value;
- Monte Carlo/regression noise dominates;
- subtractive cancellation amplifies error.

### Q16.16 Minimum Meaningful Bump

One Q16.16 LSB is:

```text
1 / 65536 approximately 0.0000152588
```

But the practical bump must be much larger because the full pricing path quantizes and regresses values.

Start experiments with:

```text
spot bump: max(0.01 * S, 0.50)
vol bump: 0.01 absolute
rate bump: 0.001 or 0.01 absolute, compare both
theta: 1/365 year
```

These are starting points, not universal truths.

### Common Random Numbers

Every bump pair should use the same Sobol direction data and starting index. Verify this rather than assuming it.

### Greek Job IDs

Use explicit identifiers:

```text
POS-001|BASE
POS-001|DELTA|UP
POS-001|DELTA|DOWN
POS-001|GAMMA|UP
POS-001|GAMMA|DOWN
POS-001|VEGA|UP
POS-001|VEGA|DOWN
```

Delta and gamma can share spot-up and spot-down valuations if bump sizes match.

### Bump-Reuse Exercise

Without reuse, base plus five central-difference Greeks can require:

```text
1 base + 2 delta + 2 gamma + 2 vega + 2 rho + 1 theta = 10 jobs
```

With delta/gamma spot bump reuse:

```text
1 base + 2 spot + 2 vega + 2 rho + 1 theta = 8 jobs
```

For 100 positions, that saves 200 pricing jobs.

### Required Experiment Plan

For one representative PUT and CALL, sweep:

- paths: `256, 1024, 4096, 8192`;
- spot bump: `0.25%, 0.5%, 1%, 2%`;
- volatility bump: `0.5, 1, 2` volatility points;
- rate bump: `10, 50, 100` basis points.

Record price and Greek stability.

### Deliverables

- Greek definitions and units;
- bump policy;
- job-reuse plan;
- convergence experiment table design;
- qualitative expected signs for test contracts.

### Gate

Another reader must be able to interpret every Greek column without asking about sign or units.

### AI Boundary

AI may challenge your methodology after it is written. AI may not choose bump sizes without your experiment plan.

## Lab 9: Implement Greeks And Stability Studies

### Estimated Time

15-24 hours.

### Learning Objectives

- implement job expansion and result reduction;
- reuse valuations correctly;
- evaluate numerical stability rather than trusting one output;
- compare against qualitative and analytic expectations.

### Implementation Separation

Split into two layers:

```text
Greek job generation
    Contract + market + bump policy -> PricingJobs

Greek result reduction
    PriceResults + bump policy -> GreekResult
```

Neither layer should directly invoke the backend. This makes both independently testable.

### Result Type

```python
@dataclass(frozen=True)
class GreekResult:
    position_id: str
    delta: float | None
    gamma: float | None
    vega_1pct: float | None
    rho_100bp: float | None
    theta_1d: float | None
    bump_metadata: dict[str, float]
    status: str
```

Avoid an untyped metadata dictionary in a final design if it becomes complex. It is acceptable for an early prototype, but explicit fields improve reliability.

### Qualitative Sanity Checks

For ordinary no-dividend options:

- CALL delta should usually be between 0 and 1;
- PUT delta should usually be between -1 and 0;
- gamma should usually be nonnegative;
- vega should usually be nonnegative;
- theta is often negative for long options, but American exercise can complicate behavior;
- CALL and PUT rho often have opposite signs under standard conventions.

These are sanity checks, not proofs. Investigate violations.

### Reference Comparisons

For no-dividend CALLs, compare against Black-Scholes European Greeks because early exercise is suppressed. This gives a valuable reference for the finite-difference machinery.

For American PUTs, use a high-step binomial tree with finite differences or extend `scripts/financial_reference.py` carefully.

### Stability Metrics

For each Greek across path counts or bump sizes, record:

- absolute change from previous configuration;
- relative change when meaningful;
- sign stability;
- CPU fixed-point versus higher-precision reference;
- FPGA versus C++ raw parity for component prices;
- number of regression fallbacks.

### Tests

- exact synthetic quadratic price function produces expected delta/gamma;
- job reuse does not omit required valuations;
- missing bump result produces incomplete status;
- unit conversions for vega/rho are correct;
- quantity and multiplier scale position Greeks exactly once;
- portfolio Greeks equal sum of position Greeks;
- deterministic rerun returns identical fixed-point component prices.

### Synthetic Function Test

Before using the pricing engine, test the reducer with:

```text
V(S) = 2 + 3S + 4S^2
```

Then:

```text
Delta = 3 + 8S
Gamma = 8
```

Central differences should recover these values up to floating arithmetic. This isolates formula bugs from pricing noise.

### Deliverables

- Greek job generator;
- Greek reducer;
- bump-reuse logic;
- Greek report;
- stability study outputs;
- reference comparison note.

### Gate

No Greek is accepted based on one bump size and one path count. You need a stability table.

### AI Boundary

You implement formulas and unit conversions. AI may review the stability study and point out suspicious patterns.

## Lab 10: Build A Layered Validation Strategy

### Estimated Time

10-16 hours.

### Learning Objectives

- separate unit, integration, numerical, parity, and performance tests;
- understand what each test can and cannot prove;
- build evidence that survives interview scrutiny.

### Test Pyramid For This Project

#### Layer 1: Pure Unit Tests

- CSV parsing;
- validation;
- scenario transformations;
- job ID generation;
- Greek formulas;
- aggregation.

Fast, deterministic, no C++ process, no FPGA.

#### Layer 2: C++ API Tests

- known raw Q16.16 outputs;
- input validation;
- pricing mode selection;
- repeated-call determinism;
- batch behavior.

#### Layer 3: Python/C++ Integration Tests

- Python request becomes correct C++ inputs;
- structured result fields parse correctly;
- multiple jobs preserve IDs and ordering guarantees.

#### Layer 4: Financial Reference Tests

- no-dividend CALL versus Black-Scholes;
- American PUT versus high-step CRR;
- finite-difference Greeks versus reference Greeks;
- convergence with paths and steps.

#### Layer 5: C++/RTL Parity Tests

- same normalized job;
- same Sobol stream;
- same Q16.16 parameters;
- raw price delta within contract;
- status flags compared.

#### Layer 6: System Tests

- portfolio CSV through final report;
- scenario and Greek job counts;
- failures and incomplete summaries;
- persistent serial reconnect behavior.

#### Layer 7: Performance Tests

- CPU engine only;
- C++ batch wall time;
- Python overhead;
- FPGA core time;
- UART time;
- end-to-end portfolio time.

### Golden Fixture

Create a small fixture with:

- three positions;
- two scenarios plus BASE;
- delta and vega;
- fixed paths and steps;
- expected job IDs;
- expected raw component prices where stable;
- expected aggregation relationships.

Do not hard-code only final portfolio value. Intermediate expected values make failures diagnosable.

### Property-Based Thinking Without A Framework

Generate loops over representative inputs and assert properties:

- CALL price nondecreasing in spot;
- PUT price nonincreasing in spot;
- option price nonnegative;
- portfolio value linear in quantity;
- BASE scenario PnL is zero;
- duplicate execution order does not change aggregation;
- same deterministic job gives same raw price.

Properties may fail at extreme fixed-point or low-path settings. If so, characterize the boundary instead of deleting the test.

### Failure Injection

Test:

- missing executable;
- malformed C++ result;
- UART timeout;
- unexpected marker;
- singular regression flag;
- one failed job among many;
- duplicate job result;
- stale result from a previous job.

### Deliverables

- documented test matrix;
- automated unit/integration suite;
- golden fixture;
- failure-injection results;
- clear definition of acceptable parity and accuracy.

### Gate

You must be able to answer: "What bug would this test miss?" for every major test layer.

### AI Boundary

AI may propose missing failure cases after your test matrix exists. You own the expected behavior and acceptance thresholds.

## Lab 11: Profile Before Changing Hardware

### Estimated Time

10-16 hours.

### Learning Objectives

- build an honest timing model;
- distinguish useful acceleration from benchmark theater;
- identify the actual bottleneck;
- apply Amdahl's law to a real system.

### Timing Instrumentation

Measure these separately:

```text
portfolio_parse_s
job_generation_s
cpu_process_startup_s
cpu_engine_s
fpga_uart_tx_s
fpga_core_s
fpga_uart_rx_s
aggregation_s
report_write_s
total_wall_s
```

Some values may be combined initially, but `fpga_core_s`, UART round-trip, and total wall time must remain distinct.

### Benchmark Matrix

Vary:

- positions: `1, 10, 50, 100`;
- scenarios: `0, 5, 20`;
- Greek set: none, delta only, all five;
- paths: `256, 1024, 4096`;
- backend: CPU process-per-job, CPU batch, FPGA current UART;
- option mix: PUT-heavy, CALL-heavy, mixed.

### Job Count Prediction

Before every run, compute expected jobs:

```text
jobs = positions * scenario_states * valuations_per_state
```

If all five Greeks use eight total valuations including base and scenarios are independent:

```text
jobs = positions * (1 + scenario_count) * 8
```

For 50 positions and 20 non-base scenarios:

```text
jobs = 50 * 21 * 8 = 8400
```

This calculation should influence batching and timeout design.

### Throughput Metrics

Report:

```text
jobs_per_second
positions_per_second for a stated risk request
portfolio_requests_per_second for a stated portfolio
```

"FPGA is 10x faster" is incomplete unless you say which timing boundary and workload.

### Statistical Discipline

- perform warm-up runs;
- run multiple repetitions;
- report median and at least min/max or percentile range;
- keep input job ordering deterministic;
- record compiler optimization level;
- record FPGA clock;
- record UART baud;
- record machine and board;
- avoid comparing Debug C++ against hardware.

### Questions

1. Does C++ process startup dominate small jobs?
2. Does UART dominate CALL fast-path jobs?
3. At what path count does FPGA core time dominate transport?
4. Does batching improve CPU, FPGA, or both?
5. What fraction of total time is actually accelerable?
6. Is throughput limited by compute, serial bandwidth, or orchestration?

### Deliverables

- benchmark harness;
- raw CSV measurements;
- timing breakdown charts or tables;
- Amdahl analysis;
- written recommendation for the next hardware step.

### Gate

Do not modify the UART protocol until the report demonstrates why the current protocol is inadequate.

### AI Boundary

AI may review experimental controls. You must gather the data and write the first interpretation.

## Lab 12: Refactor The FPGA Backend Into A Persistent Session

### Estimated Time

12-20 hours.

### Learning Objectives

- understand serial-port lifecycle and framing;
- separate connection management from job execution;
- handle timeouts and stale data safely;
- improve throughput without RTL changes.

### Current Limitation

The current `send_params_uart(...)` function opens and closes `serial.Serial` for every valuation.

That is simple for one benchmark, but portfolio risk creates many jobs. Reopening the port can add operating-system overhead, reset assumptions, and complicate throughput measurement.

### Target Design

```python
class FpgaSession:
    def __enter__(self): ...
    def __exit__(self, exc_type, exc, tb): ...
    def price(self, job: PricingJob) -> PriceResult: ...
    def price_many(self, jobs: list[PricingJob]) -> list[PriceResult]: ...
```

Responsibilities:

- open port once;
- validate configuration;
- send one request at a time under the existing protocol;
- validate echoes and marker;
- attach job ID on the host side;
- recover or fail clearly on timeout;
- close port reliably.

### Protocol Questions

Answer from RTL and host code:

1. How does the FPGA know a new packet starts?
2. Does it require idle cycles between jobs?
3. Can a new request arrive before the previous result is fully transmitted?
4. What state is reset between jobs?
5. What happens after malformed or partial input?
6. Can stale UART bytes be mistaken for a new response?

### Safe First Version

Keep one job in flight:

```text
send job
wait for complete validated result
send next job
```

This is not high-performance batching yet, but it amortizes port setup and proves repeated-job correctness.

### Tests

- two jobs in one session;
- 100 repeated deterministic jobs;
- alternating PUT/CALL jobs;
- alternating path counts;
- timeout on one job;
- unexpected marker;
- session closes after exception;
- result IDs remain aligned;
- no stale bytes remain after a successful result.

### Measurement

Compare:

- open/close per job;
- persistent session;
- FPGA core total;
- UART total;
- end-to-end jobs per second.

### Deliverables

- persistent session class;
- backend adapter;
- repeated-job tests;
- before/after benchmark;
- protocol behavior note.

### Gate

At least 100 sequential jobs must complete with correct IDs and no stale response data.

### AI Boundary

You implement framing and lifecycle after reading the UART RTL. AI may review timeout and cleanup behavior.

## Lab 13: Decide Whether To Build An RTL Batch Protocol

### Estimated Time

8-12 hours for specification only.

### Learning Objectives

- translate performance evidence into a hardware requirement;
- write a protocol specification before RTL;
- reason about backpressure, buffering, and failure recovery.

### Go/No-Go Criteria

Build a new RTL batch path only if at least one is true:

- UART handshaking or per-job state transitions materially limit throughput;
- persistent host sessions still leave the FPGA idle between jobs;
- product workloads require queued jobs;
- measurements show host-driven one-at-a-time scheduling is the dominant overhead;
- the RTL work is intentionally chosen as a learning objective and scoped safely.

Do not build it merely because batching sounds impressive.

### Protocol Design Alternatives

#### Alternative A: Existing Fixed Packet, Repeated

Host sends eight words and waits for one result.

Best when kernel compute dominates and simplicity matters.

#### Alternative B: Counted Batch

```text
BATCH_START
job_count
job_0 fields
job_1 fields
...
```

FPGA processes jobs sequentially and returns counted results.

Advantages:

- simple amortization;
- deterministic batch length.

Risks:

- partial batch handling;
- storage requirements if host sends faster than processing.

#### Alternative C: Streaming Job/Result Queues

Host may stream jobs while FPGA returns prior results.

Advantages:

- overlaps communication and compute;
- highest throughput potential.

Risks:

- full-duplex framing;
- FIFO sizing;
- backpressure;
- job/result ID alignment;
- much harder verification.

### Recommendation

If hardware batching is justified, implement Alternative B first. A counted batch is enough to demonstrate protocol design without turning the project into a transport system.

### Required Packet Fields

Consider:

```text
protocol_version
message_type
batch_id
job_count
job_id
paths
steps
S0_q16
K_q16
r_q16
sigma_q16
T_q16
option_type
exercise_mode if runtime-selectable
```

Results:

```text
batch_id
job_id
price_q16
core_cycles_low
core_cycles_high
status_flags
```

### Versioning

Never change packet interpretation without a version or unambiguous marker. Host and bitstream mismatches should fail loudly.

### Backpressure Primer

For a ready/valid interface:

- transfer occurs only when `valid && ready` is true in a cycle;
- producer holds `valid` and data stable until accepted;
- consumer may deassert `ready` when full;
- data must not be dropped or counted twice.

The UART receiver and pricing core operate at different rates. A FIFO decouples them.

### FIFO Sizing Exercise

Given:

- UART at 115200 baud;
- approximately 10 serial bits per byte including framing;
- 4 bytes per word;
- 10-14 words per job;
- kernel time from measured core cycles;

Estimate whether UART can deliver a new job before the kernel finishes the current job. This determines whether a deep input FIFO helps.

### State-Machine Deliverable Before RTL

Write:

- state list;
- state-transition table;
- accepted input condition;
- output-valid condition;
- timeout/error behavior;
- reset behavior;
- FIFO overflow policy;
- batch completion rule.

### Gate

No RTL begins until the protocol, state table, and test plan are reviewed.

### AI Boundary

You write the first protocol and state table. AI may perform a design review and identify ambiguous states.

## Lab 14: Implement And Verify RTL Batching

### Estimated Time

35-70 hours. Optional for V1.

### Learning Objectives

- implement a protocol-driven FSM;
- use ready/valid and FIFOs correctly;
- write assertions and self-checking testbenches;
- connect hardware changes to measurable system behavior.

### Recommended Scope

Implement a counted batch with sequential pricing jobs. Do not add multi-lane pricing, new payoff logic, or new numerical math in the same milestone.

### Suggested Blocks

```text
UART RX32
    -> packet decoder
    -> job FIFO
    -> pricing dispatch FSM
    -> existing pricing core
    -> result FIFO
    -> packet encoder
    -> UART TX32
```

Keep packet decode, dispatch, and result encode conceptually separate even if initially placed in one file.

### Assertions To Add

Examples:

```systemverilog
assert property (@(posedge clk) valid && !ready |=> valid && $stable(data));
assert property (@(posedge clk) result_valid && !result_ready |=> result_valid && $stable(result_data));
```

Additional properties:

- accepted jobs equal completed plus in-flight jobs;
- result job IDs preserve input order for a sequential core;
- FIFO count never exceeds depth;
- batch completion occurs after exactly `job_count` results;
- core start does not pulse while busy;
- reset clears partial packet state;
- status flags belong to the correct job.

Syntax may need adjustment for the simulator. Understand each property before using it.

### Testbench Cases

1. batch of one;
2. batch of two different option types;
3. batch of maximum chosen count;
4. host pauses mid-packet;
5. transmitter backpressure;
6. core completion and UART activity in the same cycle;
7. reset mid-batch;
8. malformed version or marker;
9. timeout or core error;
10. repeated batches without reset.

### Debugging Method

When a mismatch appears:

1. count accepted jobs;
2. count core starts;
3. count core completions;
4. count encoded results;
5. compare job IDs at each boundary;
6. find the first boundary where counts or IDs diverge.

Do not begin by reading every RTL file. Instrument the transaction flow.

### Synthesis And Timing

After simulation parity:

- synthesize;
- inspect FIFO inference;
- inspect added LUT, FF, and BRAM usage;
- rerun 100 MHz timing;
- identify the new critical path;
- compare throughput before and after.

### Deliverables

- protocol RTL;
- self-checking testbench;
- assertions;
- C++/Python host support;
- resource/timing report;
- measured throughput improvement or honest no-improvement result.

### Gate

Do not claim improvement unless end-to-end portfolio wall time improves for a defined workload.

### AI Boundary

You implement the dispatch FSM and at least the first testbench. AI may review ready/valid correctness after you provide waveforms and failing evidence.

## Lab 15: Produce The Final Benchmark And Technical Report

### Estimated Time

12-20 hours.

### Learning Objectives

- tell an honest systems story;
- connect architecture to measured outcomes;
- distinguish core speedup from application speedup;
- present limitations as engineering judgment.

### Required Benchmark Workloads

Define at least three named workloads:

#### Small Interactive

```text
10 positions
base plus 5 scenarios
delta and vega
1024 paths
```

#### Medium Risk Run

```text
50 positions
base plus 20 scenarios
all five Greeks
1024 or 4096 paths
```

#### Accuracy-Oriented

```text
10 representative positions
base plus stress scenarios
all five Greeks
8192 or more paths
```

### Required Comparisons

- CPU process-per-job;
- CPU batch;
- FPGA existing persistent session;
- FPGA batch protocol if implemented;
- C++/RTL price parity;
- financial reference error for representative cases.

### Required Charts Or Tables

- jobs per second versus path count;
- end-to-end time by component;
- CPU versus FPGA core time;
- transport fraction of total time;
- Greek stability versus bump size/path count;
- FPGA resource utilization and timing;
- price/Greek accuracy for representative contracts.

### Report Structure

1. problem and motivation;
2. scope and constraints;
3. architecture;
4. financial methodology;
5. C++ and Python design;
6. FPGA integration;
7. validation strategy;
8. benchmark methodology;
9. results;
10. limitations;
11. future work;
12. lessons learned.

### Claims Discipline

Good:

> The FPGA kernel completed the defined 1024-path PUT jobs in X ms of core time, while the complete persistent-UART portfolio workflow completed Y jobs/s. UART and host orchestration accounted for Z percent of wall time.

Bad:

> The FPGA is 50x faster than CPU.

The good claim defines the boundary and workload.

### Deliverables

- raw benchmark data;
- reproducible commands;
- technical report;
- architecture diagram;
- short demo script;
- limitations section.

### Gate

Every performance or accuracy number in the README must be traceable to a command and output artifact.

### AI Boundary

AI may edit prose for clarity after you write the technical interpretation. AI may not invent explanations for results you have not investigated.

## Lab 16: Prepare For Interviews And Resume Use

### Estimated Time

6-10 hours.

### Learning Objectives

- translate work into defensible evidence;
- practice explaining design decisions under pressure;
- avoid overstating results.

### Highest-Signal Skills This Project Can Show

- modern C++ API and build design;
- deterministic numerical computing;
- Monte Carlo and Longstaff-Schwartz methods;
- fixed-point arithmetic and parity validation;
- Python research/risk infrastructure;
- finite-difference Greeks and numerical stability;
- serial protocol and hardware/software integration;
- ready/valid, FIFOs, backpressure, and RTL verification;
- performance profiling and Amdahl's law;
- disciplined benchmark methodology.

### Resume Bullet Templates

Use only after substituting measured values.

```text
Built a C++/Python portfolio risk engine around a fixed-point FPGA QMC-LSM accelerator, supporting N positions, S named scenarios, and delta/gamma/vega/rho/theta through deterministic bump/revalue scheduling.
```

```text
Designed a versioned UART batch protocol and SystemVerilog job controller with ready/valid backpressure and self-checking verification, improving end-to-end throughput from X to Y jobs/s at 100 MHz.
```

```text
Established bit-exact C++/RTL parity and financial validation against Black-Scholes/CRR references; characterized pricing and Greek error across path count, bump size, and fixed-point quantization.
```

```text
Profiled CPU compute, process startup, FPGA core cycles, UART transport, and orchestration overhead, identifying Z percent of portfolio wall time as the acceleration bottleneck.
```

Do not use all four bullets. Select the two or three strongest measured outcomes.

### Interview Questions You Must Be Able To Answer

#### Finance And Numerical Methods

1. Why use LSM for American options?
2. Why is a vanilla American PUT not the strongest FPGA use case?
3. How does QMC differ from pseudorandom Monte Carlo?
4. Why do common random numbers help Greeks?
5. How did you choose bump sizes?
6. Why can gamma be unstable?
7. How did you validate American PUT Greeks?
8. Why suppress no-dividend CALL early exercise?

#### C++

1. How did you separate the library from the CLI?
2. Who owns path memory and when is it released?
3. Why use value types or immutable request objects?
4. How are errors represented across library and CLI boundaries?
5. What prevents repeated process startup in batch mode?
6. Is the pricing library thread-safe?
7. Where can integer overflow occur?
8. Why keep raw Q16.16 in results?

#### Python

1. Why is scenario transformation pure?
2. How are jobs joined to results safely?
3. How do failures affect portfolio totals?
4. What data belongs in Python versus C++?
5. How do you guarantee reproducibility?

#### RTL And Systems

1. Explain ready/valid in one minute.
2. What happens when valid is high and ready is low?
3. How did you size the job FIFO?
4. What is the difference between latency and throughput?
5. Why did UART matter to end-to-end speedup?
6. How are job IDs kept aligned with results?
7. How did you test reset mid-batch?
8. What was the post-route critical path?

#### Judgment

1. What did you deliberately not put in hardware?
2. Which optimization did measurement cause you to reject?
3. What would you redesign for PCIe instead of UART?
4. What is required before calling this production-ready?
5. What limitation most affects financial usefulness?

### Whiteboard Exercises

Practice without notes:

- derive central-difference delta and gamma;
- calculate job count for a portfolio/scenario/Greek request;
- draw the host-to-FPGA dataflow;
- draw a ready/valid FIFO boundary;
- estimate UART transfer time for one job;
- explain Q16.16 range and resolution;
- explain one parity bug and how stage-level traces found it.

### Final Deliverables

- two-minute explanation;
- ten-minute deep technical walkthrough;
- one-page architecture diagram;
- benchmark table;
- two or three measured resume bullets;
- answers to the interview question set.

## Advanced Phase A: Asian Options

Do not begin until V1 is complete.

### Why Asian Options Matter

Asian payoffs depend on an average over the path:

```text
arithmetic_average = (1/M) * sum(S_t)
```

Example fixed-strike Asian call payoff:

```text
max(arithmetic_average - K, 0)
```

This demonstrates a path-dependent state variable and gives simulation a stronger reason to exist.

### Recommended Sequence

1. Implement a double-precision Python or C++ reference.
2. Add arithmetic-average state to the C++ engine.
3. Validate European-style Asian payoff first.
4. Define what early exercise means for the Asian contract.
5. Study LSM basis choices including spot and running average.
6. Only then design RTL state changes.

### New LSM State

Continuation may depend on both current spot and running average:

```text
X1 = S/K - 1
X2 = A/K - 1
```

Potential basis:

```text
[1, X1, X2, X1^2, X1*X2, X2^2]
```

This changes regression size and hardware cost substantially. It is not a payoff-only modification.

### Learning Value

- path-dependent state;
- multidimensional regression basis;
- memory/compute tradeoffs;
- stronger justification for Monte Carlo acceleration.

### Estimated Effort

- software/reference: 30-60 hours;
- RTL and validation: 80-150 hours.

## Advanced Phase B: Basket Options And Correlation

### Why This Is A Major Expansion

A basket option uses multiple asset paths. Correlated normal shocks can be produced through:

```text
z_correlated = L * z_independent
```

where `L` is a Cholesky factor of the correlation matrix.

New concerns:

- multidimensional Sobol mapping;
- correlation matrix validation;
- Cholesky factor input or computation;
- multiple GBM states per path;
- basket payoff definition and weights;
- larger regression state;
- DSP, BRAM, and bandwidth growth.

### Recommended Boundary

Compute correlation/Cholesky on the host and send the factor to hardware. Do not implement a general Cholesky decomposition in RTL unless that becomes a separate learning objective.

### Estimated Effort

- robust software model: 50-100 hours;
- RTL architecture and validation: 120-250 hours.

This is a second project phase, not a V1 feature.

## Approaches Deliberately Rejected For V1

### All-SystemVerilog Risk Engine

Rejected because:

- CSV/report logic is dynamic and control-heavy;
- scenarios and bump conventions change frequently;
- it hides systems judgment behind unnecessary RTL;
- it would consume time without improving the core acceleration story.

### Python-Only Pricing Engine

Rejected as the main implementation because:

- it weakens the C++ systems signal;
- it avoids the reusable fixed-point mirror already present;
- Python orchestration plus C++ pricing is a stronger architecture.

Python references remain valuable.

### Immediate `pybind11` Integration

Deferred because:

- a clean C++ API must exist first;
- batch CLI gives a simpler measurable improvement;
- bindings should solve measured friction, not postpone core design.

### Immediate Multi-Lane Or Higher-Frequency RTL

Deferred because:

- product workloads have not yet been measured;
- UART and scheduling may dominate;
- existing 100 MHz timing is already a credible foundation;
- batching and workflow improvements may have higher payoff.

### Sentiment Or Live Market Data As The Main Story

Deferred because:

- it distracts from the pricing/risk system;
- forecast value must be proven out of sample;
- static reproducible fixtures are better for validation.

## Milestone Acceptance Checklist

### Milestone 1: C++ Engine API

- [ ] CLI is a thin wrapper.
- [ ] Direct API returns known raw Q16.16 results.
- [ ] Invalid inputs fail clearly.
- [ ] Core, CLI, and tests are separate build targets.
- [ ] Existing parity gate still passes.
- [ ] You can explain ownership and reentrancy.

### Milestone 2: CPU Portfolio Engine

- [ ] Portfolio CSV validates with row/field errors.
- [ ] Contract, position, and market state are distinct.
- [ ] Long/short quantities aggregate correctly.
- [ ] Failed jobs make totals visibly incomplete.
- [ ] Output is deterministic and machine-readable.
- [ ] Batch execution outperforms process-per-job for many small jobs.

### Milestone 3: Scenarios And Greeks

- [ ] Scenario transformations are pure.
- [ ] BASE PnL is zero.
- [ ] Position PnLs reconcile to portfolio PnL.
- [ ] Greek units and signs are documented.
- [ ] Delta/gamma bump jobs are reused.
- [ ] Greeks have path-count and bump-size stability studies.
- [ ] Reference comparisons exist.

### Milestone 4: FPGA Integration

- [ ] Persistent session runs at least 100 jobs.
- [ ] Echoes, markers, status, and IDs are validated.
- [ ] FPGA core and UART times are separate.
- [ ] CPU/FPGA raw parity is checked for component prices.
- [ ] End-to-end jobs/s is reported.

### Milestone 5: Optional RTL Batch Path

- [ ] Protocol is versioned and documented.
- [ ] FSM/state table existed before RTL.
- [ ] Ready/valid stability is asserted.
- [ ] Repeated batches work without reset.
- [ ] Resource and timing reports pass acceptance criteria.
- [ ] Defined portfolio workload improves end-to-end.

### Milestone 6: Project Presentation

- [ ] README explains scope and limitations.
- [ ] Commands reproduce major results.
- [ ] Raw benchmark data is preserved.
- [ ] No speedup claim mixes timing boundaries.
- [ ] Resume bullets contain measured values.
- [ ] You can answer the interview question set unaided.

## Weekly Self-Assessment Rubric

Score each category from 0 to 3.

| Score | Meaning |
|------:|---------|
| 0 | I cannot explain or reproduce it |
| 1 | I recognize it but need substantial help |
| 2 | I can implement and explain it with documentation |
| 3 | I can derive, debug, and defend it under questioning |

Categories:

- financial model;
- numerical method;
- C++ ownership/API;
- Python data flow;
- fixed-point reasoning;
- RTL handshake/state;
- verification;
- performance interpretation.

The goal is not to score 3 immediately. The goal is to watch weak areas move.

## Stop Rules

Stop adding features when:

- existing validation is red;
- you cannot explain the last generated code;
- benchmark boundaries are unclear;
- reports contain ambiguous units;
- a new abstraction has no test;
- an RTL change is motivated only by aesthetics;
- the project begins expanding faster than your understanding.

When a stop rule triggers, return to the smallest failing layer.

## Recommended Final Scope For Maximum Career Value

The highest-return finished version is not the version with the most derivatives.

Recommended final scope:

1. clean C++ pricing library;
2. Python portfolio/scenario/Greek engine;
3. deterministic validation against references;
4. persistent FPGA backend;
5. optional, measured counted-batch RTL protocol;
6. excellent benchmark report and interview defense.

This combination demonstrates systems depth, quantitative judgment, C++, Python, RTL, and performance engineering without diluting the project into an unfinished derivatives platform.

Asian options are the best next extension after that. Basket/correlation support should follow only if the first system is already polished.

## First Three Work Sessions

### Session 1

- inspect the three current RTL diffs;
- reproduce one CPU case;
- reproduce one parity case if tools are available;
- draw the current architecture;
- answer Lab 0 questions.

### Session 2

- write the domain field/invariant table;
- draft `ContractTerms`, `MarketState`, `EngineConfig`, and `PriceResult`;
- list invalid inputs;
- request review only after the draft is complete.

### Session 3

- write the first direct API test using a known raw price;
- create `pricing_api.h`;
- move the smallest possible orchestration into `priceContract`;
- confirm CLI and API equality.

Do not begin with the portfolio CSV. A clean pricing boundary makes every later phase easier and gives you the C++ learning you explicitly want.

## Final Advice

The project is feasible. The danger is not technical impossibility. The danger is dilution and outsourced understanding.

Use Python to move quickly where flexibility matters. Use C++ where ownership, deterministic performance, and interface design matter. Use SystemVerilog where measured hardware service behavior matters. Keep those boundaries clear.

The most valuable outcome is being able to say:

> I designed the software/hardware boundary, implemented the reusable pricing API and risk job graph, validated the numerical behavior, measured the real bottleneck, and then changed the hardware only where the data justified it.

That is a stronger engineering story than simply adding more RTL.
