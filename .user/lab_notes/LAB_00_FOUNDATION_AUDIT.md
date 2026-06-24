# Lab 0 Worksheet: Foundation Audit

Last updated: 2026-06-23

Related manual: [`../PORTFOLIO_RISK_ENGINE_LAB_MANUAL.md`](../PORTFOLIO_RISK_ENGINE_LAB_MANUAL.md)

## Purpose

This worksheet is your first active lab. Do not treat it as documentation to skim. Fill it in as you work.

The objective is to prove that you understand the inherited kernel well enough to extend it without turning the project into a stack of code you cannot defend.

By the end of this lab, you should be able to explain:

- how one option-pricing request moves from CLI arguments to a final price;
- where floating-point inputs become Q16.16;
- how Sobol values become GBM paths;
- how LSM decides between exercise and continuation;
- how the CPU mirror and RTL parity contract fit together;
- what the current uncommitted RTL changes do;
- which timing measurements are core-only and which are end to end.

## Rules

1. Fill in predictions before running commands.
2. Do not paste AI summaries into answer sections.
3. If you ask AI a question, record the exact question and what you learned.
4. Do not modify RTL during this lab.
5. Do not discard the existing working-tree changes.
6. Preserve raw command output in a local note or `.tmp/lab_00/`.
7. Mark uncertainty honestly. An unanswered question is more useful than a guessed answer.

## Estimated Schedule

| Session | Focus | Suggested time |
|---------|-------|---------------:|
| 1 | Git forensics and architecture map | 2 hours |
| 2 | C++ build and pricing trace | 2-3 hours |
| 3 | Fixed-point, Sobol, and GBM reasoning | 2 hours |
| 4 | LSM, UART, and validation reasoning | 2-3 hours |
| 5 | Oral defense and corrections | 1 hour |

## Completion Metadata

```text
Student:
Start date:
Completion date:
Branch:
Starting commit:
Vivado version:
Compiler version:
Python version:
FPGA board available: yes / no
```

## Part A: Establish The Working-Tree State

### A1. Predict

Before running anything, answer:

```text
What do I expect `git status --short` to show?


Which files do I believe are my current uncommitted work?


What would be dangerous about starting a large refactor now?

```

### A2. Run

```powershell
git status --short --untracked-files=all
git diff --stat
git diff -- src/helpers/rv_skid_arr_gate.sv
git diff -- src/steps/GBM.sv
git diff -- src/steps/sobol.sv
```

Do not use `git reset`, `git checkout --`, or another destructive command.

### A3. Record

| File | Lines added | Lines removed | My one-sentence description |
|------|------------:|--------------:|-----------------------------|
| `src/helpers/rv_skid_arr_gate.sv` | | | |
| `src/steps/GBM.sv` | | | |
| `src/steps/sobol.sv` | | | |

### A4. Analyze Each Diff

#### `rv_skid_arr_gate.sv`

```text
What interface contract is this module implementing?


What changed?


Which signal must remain stable under backpressure?


What bug could the change fix?


What bug could the change introduce?


How would I test it?

```

#### `GBM.sv`

```text
What mathematical transformation does this module implement?


What changed?


Did latency, throughput, or only control behavior change?


Which side-channel values must stay aligned with the datapath?


How would a one-cycle misalignment appear in a path trace?

```

#### `sobol.sv`

```text
What changed?


Does it affect sequence values, reset behavior, valid timing, or addressing?


Which C++ behavior should match it?


What is the smallest deterministic test that could catch a mismatch?

```

### A5. Checkpoint Decision

Select one and explain:

```text
[ ] The changes are understood, tested, and ready for a checkpoint commit.
[ ] The changes are understood but testing is incomplete.
[ ] The changes are not understood; product extension work should pause.
```

Explanation:

```text


```

## Part B: Draw The Current Architecture

### B1. Source Map

Fill in each row after locating the implementation.

| Responsibility | File | Main module/function | Inputs | Outputs |
|----------------|------|----------------------|--------|---------|
| CLI parsing | | | | |
| Q16.16 conversion | | | | |
| Sobol generation, C++ | | | | |
| Sobol generation, RTL | | | | |
| inverse normal CDF | | | | |
| GBM step | | | | |
| path simulation | | | | |
| regression accumulation | | | | |
| beta solve | | | | |
| exercise decision | | | | |
| final averaging | | | | |
| UART parameter decode | | | | |
| UART result encode | | | | |
| Python CPU invocation | | | | |
| Python FPGA invocation | | | | |

### B2. Draw By Hand

Draw this twice:

1. software path from CLI to price;
2. hardware path from UART bytes to result bytes.

Your diagram must show:

- data types at boundaries;
- Q16.16 conversion point;
- Sobol direction memory;
- valid/ready boundaries;
- path memory or regeneration;
- regression;
- cycle counter;
- UART timing boundary.

Attach or link the diagram here:

```text

```

### B3. Explain The Boundary

```text
Which behavior is considered the financial model?


Which behavior is considered the fixed-point hardware contract?


Which behavior is only transport/orchestration?


Why should portfolio and scenario logic remain outside RTL?

```

## Part C: Build And Run The C++ Baseline

### C1. Predict

```text
Which translation units will be compiled?


Which file contains `main`?


Which files are likely to contribute symbols used by `main`?


What is the difference between compiling and linking?

```

### C2. Inspect Tool Versions

```powershell
g++ --version
python --version
```

Record:

```text
Compiler:
Python:
```

### C3. Build

```powershell
cd baseline\cpp_fixed
g++ -std=c++17 main.cpp pricing.cpp linalg.cpp rtl_math.cpp sobol_wrapper.cpp utils.cpp -o fixed_baseline
cd ..\..
```

Record all warnings:

```text

```

For every warning, classify it:

| Warning | Harmless, risky, or unknown? | Why? |
|---------|------------------------------|------|
| | | |

### C4. Run A Known Case

Before running, predict whether the PUT price should be above or below its intrinsic value at spot 100 and strike 100.

Prediction:

```text

```

Run:

```powershell
.\baseline\cpp_fixed\fixed_baseline.exe --paths 64 --steps 12 --S0 100 --K 100 --r 0.05 --sigma 0.2 --T 1 --option-type 1 --fpga-style --exercise-mode multi --direction-file src\gen\direction.mem --lut-dir src\gen
```

Record:

```text
Option type:
Pricing mode:
Raw Q16.16 price:
Double price:
Elapsed time:
```

### C5. Verify Raw Conversion

Compute manually:

```text
double_price_from_raw = raw_price / 65536
```

```text
Raw price:
Division work:
My converted value:
Program value:
Difference:
```

### C6. Compare Modes

Run the same contract in:

- single exercise mode;
- multi exercise mode;
- full LSM mode.

| Mode | Raw price | Double price | Time | My explanation of difference |
|------|----------:|-------------:|-----:|------------------------------|
| single | | | | |
| multi | | | | |
| full LSM | | | | |

Questions:

```text
Why can single and multi be bit-exact with RTL but differ financially?


Why might full LSM differ from the RTL mirror?


Which mode should portfolio CPU/FPGA parity use?

```

## Part D: Trace One Request Through C++

### D1. Call Graph

Starting from `main.cpp`, write the call chain for one multi-exercise price.

```text
main
  ->
  ->
  ->
  ->
```

### D2. Data Ownership

```text
Where is `std::vector<Path>` allocated?


How many `Path` objects exist for N paths?


How many spot entries are stored per path for M steps?


When is the memory released?


Which objects own dynamic memory?


Are any pointers borrowed across function boundaries?

```

### D3. Memory Estimate

Ignoring vector bookkeeping, estimate spot and cashflow storage for:

```text
N = 10,000
M = 50
int32_t = 4 bytes
```

Show work:

```text
spot bytes =
cashflow bytes =
total approximate bytes =
```

Then explain why RTL does not simply store the same full path grid.

### D4. Global State

Locate mutable global or static state in the C++ pricing path.

| State | File | Purpose | Thread-safety concern |
|-------|------|---------|-----------------------|
| | | | |

Question:

```text
If two Python threads called a future C++ binding simultaneously, what could go wrong?

```

## Part E: Fixed-Point Reasoning

### E1. Q16.16 Basics

Fill in:

```text
Total bits:
Fractional bits:
Resolution:
Minimum signed value:
Maximum signed value:
Raw representation of 1.0:
Raw representation of 0.5:
Raw representation of -1.0:
```

### E2. Manual Conversions

Convert without running code first:

| Decimal | Expected raw Q16.16 | Work |
|---------|---------------------|------|
| `100.0` | | |
| `0.05` | | |
| `0.20` | | |
| `1.0` | | |
| `-0.10` | | |

Then verify with a small calculation or debugger.

### E3. Multiply

Explain why Q16.16 multiplication needs a 64-bit intermediate.

```text

```

Calculate conceptually:

```text
raw_product = raw_a * raw_b
scaled_result = raw_product >> 16
```

Where is rounding added in C++ and RTL?

```text

```

### E4. Overflow Audit

List five places where fixed-point or accumulator overflow could occur.

| Location | Width | Worst-case input | Existing protection |
|----------|------:|------------------|---------------------|
| | | | |

## Part F: Sobol And Inverse CDF

### F1. Explain Sobol In Your Own Words

```text
How is a low-discrepancy sequence different from pseudorandom samples?


Why is determinism useful for parity?


Why is determinism useful for finite-difference Greeks?

```

### F2. Boundary Handling

```text
Why is Sobol index 0 skipped?


How can truncation still produce Q16.16 zero?


Why is zero invalid for inverse CDF?


What value replaces zero?

```

### F3. First Values

Use the existing testbench, trace mode, or a minimal diagnostic to record the first eight accepted Sobol values in both C++ and RTL.

| Index | C++ raw | RTL raw | Match? |
|------:|--------:|--------:|--------|
| 1 | | | |
| 2 | | | |
| 3 | | | |
| 4 | | | |
| 5 | | | |
| 6 | | | |
| 7 | | | |
| 8 | | | |

Do not change RTL to produce this table unless existing trace hooks are insufficient.

### F4. Inverse-CDF Pipeline

Write the stages in order:

```text
uniform u
  ->
  ->
  ->
  -> normal z
```

Identify where sign information is stored and how it stays aligned.

```text

```

## Part G: GBM Path Generation

### G1. Formula

Write the GBM update:

```text
S_next =
```

Define every variable and unit.

### G2. Precomputed Terms

Locate and explain:

```text
dt =
drift_const =
vol_sqrt_dt =
discount =
```

### G3. Qualitative Predictions

For each change, predict the path distribution effect before running:

| Change | Expected effect on mean | Expected effect on dispersion |
|--------|-------------------------|-------------------------------|
| increase `r` | | |
| increase `sigma` | | |
| increase `T` | | |
| set `sigma = 0` | | |

### G4. Handshake Reasoning

```text
When may GBM accept a new input?


What must remain stable if downstream is not ready?


What metadata must stay aligned with the computed `S_next`?


What symptom would a duplicate valid pulse cause?

```

## Part H: Longstaff-Schwartz Reasoning

### H1. Exercise Versus Continuation

Define:

```text
immediate payoff =
continuation estimate =
exercise rule =
```

### H2. Regression Data

```text
Which paths enter PUT regression?


What is the regression target Y?


What is the centered state variable x?


What basis functions are used?

```

### H3. Why Center The Basis?

Explain why:

```text
[1, S/K - 1, (S/K - 1)^2]
```

is numerically preferable to raw powers of spot in Q16.16.

```text

```

### H4. Fallbacks

```text
When does singular fallback occur?


What is mean continuation fallback?


What is the beta magnitude cap?


Why should fallback count appear in a risk-engine report or diagnostic?

```

### H5. CALL Behavior

```text
Why is early exercise suppressed for no-dividend CALLs?


What model assumption makes that valid?


What new input would force the policy to be revisited?

```

## Part I: UART And Timing Boundaries

### I1. Request Packet

Fill in order and representation:

| Word | Field | Representation |
|-----:|-------|----------------|
| 0 | | |
| 1 | | |
| 2 | | |
| 3 | | |
| 4 | | |
| 5 | | |
| 6 | | |
| 7 | | |

### I2. Result Packet

| Word | Field | Meaning |
|-----:|-------|---------|
| 0 | | |
| 1 | | |
| 2 | | |
| 3 | | |
| 4 | | |

### I3. Timing Definitions

```text
FPGA core time =

UART round-trip time =

End-to-end portfolio time =

CPU engine time =

CPU process wall time =
```

### I4. Transfer-Time Estimate

Assume:

```text
baud = 115200 bits/s
10 serial bits per byte
4 bytes per word
8 request words
5 result words
8 echo words if enabled
```

Estimate minimum wire time:

```text
total words =
total bytes =
total serial bits =
ideal wire seconds =
```

Compare the estimate with measured UART round-trip time.

## Part J: Validation Layers

For each test, state what it proves and what it does not prove.

| Test | Proves | Does not prove |
|------|--------|----------------|
| C++/RTL raw price parity | | |
| CRR accuracy comparison | | |
| Black-Scholes CALL comparison | | |
| post-route timing | | |
| xsim cycle count | | |
| physical UART run | | |
| regression health metrics | | |

### J1. Run Documentation Hygiene

```powershell
git diff --check
```

Result:

```text

```

### J2. Run Python Syntax Checks

```powershell
python -m py_compile scripts\validate_numerical.py scripts\diagnose_numerical.py scripts\accuracy_study.py scripts\financial_reference.py scripts\vivado_build_runner.py src\uart_host.py
```

Result:

```text

```

### J3. Run Available Kernel Gate

Choose the smallest appropriate gate supported by your environment. Record the exact command, runtime, and result.

```text
Command:

Runtime:

Result:

Failure or limitation:
```

## Part K: Oral Defense

Record yourself answering each question in no more than 90 seconds.

1. What problem does this kernel solve?
2. Why Sobol instead of ordinary pseudorandom Monte Carlo?
3. Why Longstaff-Schwartz?
4. Why is Q16.16 both useful and dangerous?
5. Explain ready/valid and backpressure.
6. Why are portfolio scenarios generated on the host?
7. Why will Greeks create a throughput problem?
8. What is the difference between FPGA core speed and application speed?
9. Which existing limitation matters most financially?
10. What is the first C++ refactor and why?

For each answer, score:

```text
0 = could not answer
1 = vague recognition
2 = correct with notes
3 = clear and defensible without notes
```

| Question | First score | Final score | Weak point |
|---------:|------------:|------------:|------------|
| 1 | | | |
| 2 | | | |
| 3 | | | |
| 4 | | | |
| 5 | | | |
| 6 | | | |
| 7 | | | |
| 8 | | | |
| 9 | | | |
| 10 | | | |

## Part L: Lab Exit Report

### What I Can Now Explain

```text


```

### What I Still Do Not Understand

```text


```

### The Most Important Incorrect Prediction I Made

```text


```

### Existing Changes Decision

```text
Are the three RTL changes ready to checkpoint?

What evidence supports the decision?

```

### Readiness For Lab 1

Check every item:

- [ ] I can reproduce a known CPU price.
- [ ] I can explain raw Q16.16 conversion.
- [ ] I can draw the C++ and RTL data paths.
- [ ] I understand the three current RTL diffs at a high level.
- [ ] I can explain Sobol boundary handling.
- [ ] I can explain the centered LSM basis.
- [ ] I can distinguish parity, accuracy, timing, and end-to-end performance.
- [ ] I have not discarded existing work.
- [ ] I recorded unresolved questions.

Do not begin the C++ API extraction until all required items are checked or an unresolved item is explicitly documented.

## Allowed AI Check-In Prompt

After completing the worksheet, use a prompt like:

```text
I completed Lab 0. Here are my own answers to the architecture, fixed-point,
Sobol, LSM, UART, and validation questions. Review them like an oral examiner.
Do not rewrite my answers. Identify incorrect claims, ask follow-up questions,
and tell me which topics I cannot yet defend.
```

That use of AI tests your understanding instead of replacing it.
