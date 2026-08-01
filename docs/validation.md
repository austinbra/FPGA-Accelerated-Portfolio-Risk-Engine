# Validation and Evidence Guide

This project treats validation as a stack. A passing simulation is necessary,
but it does not prove arithmetic parity, routed timing, physical-board function,
or a fair CPU comparison.

## Evidence Levels

| Level | Question answered | Current corrected status |
|---:|---|---|
| 1 | Does the C++ model satisfy focused numerical tests? | complete |
| 2 | Does divider and arithmetic RTL obey the vendor contract? | complete |
| 3 | Does the full RTL match C++ with a calibrated fast model? | complete |
| 4 | Does the full RTL match C++ with generated Vivado IP? | complete |
| 5 | Does each board configuration fit, route, and meet timing? | complete for two canonical projects |
| 6 | Does the corrected bitstream match C++ on a physical board? | complete for S7 |
| 7 | Are repeated physical transport statistics stable? | complete for S7, 30 repetitions |

Do not promote a Level 4 or 5 result to "measured on physical FPGA" without
Level 6.

## Correction Under Test

The generated signed 48/32 Xilinx divider output is:

```text
bits 79:32  quotient
bits 31:0   remainder
```

The wrapper must select quotient bits `[63:32]` for a 32-bit Q16.16 result. The
vendor core also imposes a 32-cycle response contract. The validation flow now
checks both content and latency.

## Divider Unit Gate

`tb/tb_fxDiv.sv` covers:

- `6.0 / 2.0 = 3.0`;
- `-7.5 / 2.5 = -3.0`;
- Q16.16 truncation for `1.0 / 3.0`;
- `5.5 / -2.0 = -2.75`;
- divide-by-zero bypass;
- ready/valid request and response behavior;
- exact wait-cycle reporting.

The test has been run against both:

- `src/sim/fxDiv_core_stub.sv`;
- generated `generated_ip/fxDiv_core/fxDiv_core/sim/fxDiv_core.vhd`.

Both models return the same five values. Accepted nonzero requests report 32
wait cycles. This focused gate would have caught both historical defects before
a full pricing run.

## Full-Core Vendor-Model Gate

Claim-grade RTL uses the generated VHDL model from the retained A7 build:

```text
vivado_build/arty_a7_100_multi_lanes4_9p5ns_rowopt/generated_ip/fxDiv_core/fxDiv_core/sim/fxDiv_core.vhd
```

Validated results:

| Case | C++ raw | RTL raw | Delta | Core cycles |
|---|---:|---:|---:|---:|
| intrinsic PUT, 4 paths x 4 steps | 3,276,800 | 3,276,800 | 0 | 1,966 |
| multi PUT, 1,024 paths x 4 steps | 391,343 | 391,343 | 0 | 91,302 |
| multi PUT, 1,024 paths x 12 steps | 428,757 | 428,757 | 0 | 293,790 |

The calibrated stub produces the same canonical four-lane price and cycle
counts. That agreement allows faster regression sweeps while the evidence
collector still requires the vendor model for a claim-ready report.

Run the complete evidence simulation path with:

```powershell
python scripts\reproduce_claims.py `
  --cpp-mode run `
  --xsim-mode run `
  --benchmark-mode run `
  --vivado-mode run `
  --require-complete
```

This collector fingerprints the exact generated divider model and the
implementation/simulation/C++ source sets.

## Board-Configuration Gate

Only results rerun with corrected generated divider IP are current evidence:

| Board configuration | Workload | Expected raw | Expected cycles |
|---|---|---:|---:|
| A7, 4 lanes | 1,024 x 4 multi PUT | 391,343 | 91,302 |
| A7, 4 lanes | 1,024 x 12 multi PUT | 428,757 | 293,790 |
| S7, 2 lanes | 1,024 x 4 multi PUT | 391,343 | 159,398 |

The scripts still accept A7 lane counts 1/2/4 and S7 lane counts 1/2, but a
legal parameter is not a validated performance row. Simulate each new
lane/workload pair before citing its price or cycles. The path count must be
divisible by the selected lane count.

## C++ Parity Gate

Build the mirror:

```powershell
cd baseline\cpp_fixed
g++ -std=c++17 -O3 -DNDEBUG main.cpp pricing.cpp linalg.cpp rtl_math.cpp sobol_wrapper.cpp utils.cpp -o fixed_baseline
cd ..\..
```

Canonical runs:

```powershell
.\baseline\cpp_fixed\fixed_baseline.exe `
  --input-file baseline\cpp_fixed\params_latency_1024x4.txt `
  --fpga-style `
  --exercise-mode multi

.\baseline\cpp_fixed\fixed_baseline.exe `
  --input-file baseline\cpp_fixed\params_monthly_1024x12.txt `
  --fpga-style `
  --exercise-mode multi
```

Expected raw outputs are 391,343 and 428,757. Raw Q16.16 equality is the parity
criterion; a close decoded decimal is not enough.

## Financial-Accuracy Gate

Bit-exact parity proves that C++ and RTL implement the same arithmetic. It does
not prove that the shared method is a sufficiently accurate option model.

Use the independent reference studies:

```powershell
python scripts\accuracy_study.py --preset smoke --build-cpu --attribution
python scripts\accuracy_study.py --preset default --exercise-mode both --build-cpu --attribution --health-metrics --output-dir .tmp\accuracy_default_health
```

The canonical 1,024 x 4 CRR comparison in the generated evidence is
`-11.8765` basis points of spot. It is one workload/reference comparison, not a
global error guarantee. See [`accuracy.md`](accuracy.md).

## Routed Implementation Gate

A passing board build requires all of the following:

- correct part and top;
- requested generated core period in Clock Summary;
- complete route;
- WNS >= 0;
- TNS = 0;
- setup failing endpoints = 0;
- WHS >= 0;
- THS = 0;
- hold failing endpoints = 0;
- no failed, unrouted, partial, or overlapping nets;
- bitstream generated only after those checks;
- manifest and report hashes retained.

### A7-100T canonical

```text
Project: vivado_build/arty_a7_100_multi_lanes4_9p5ns_rowopt/gui_post_synth/arty_a7_qmc_post_synth.xpr
Part: xc7a100tcsg324-1
Mode/lanes: multi / 4
Core: 9.500 ns, 105.263158 MHz
WNS/TNS: +0.121 ns / 0.000 ns
WHS/THS: +0.008 ns / 0.000 ns
LUT: 44,768 / 63,400
Registers: 49,241 / 126,800
DSP: 180 / 240
BRAM: 66 / 135
Bit SHA-256: 708C312F611909598B9B509B57F08D07C3A247CB9FC0C15820CAD5B7557CE8EF
Adjacent faster build: 9.375 ns, WNS -0.153 ns, no bitstream
```

### S7-50 canonical

```text
Project: vivado_build/arty_s7_50_multi_lanes2_10p5ns_rowopt/gui_post_synth/arty_s7_qmc_post_synth.xpr
Part: xc7s50csga324-1
Mode/lanes: multi / 2
Core: 10.500 ns, 95.238095 MHz
WNS/TNS: +0.013 ns / 0.000 ns
WHS/THS: +0.013 ns / 0.000 ns
LUT: 30,310 / 32,600
Registers: 36,816 / 65,200
DSP: 116 / 120
BRAM: 65 / 75
Bit SHA-256: 575EFA8E2EB164471E861DF37887BCB30D877609D557B34B5EB39BAA3731A874
Adjacent faster build: 10.375 ns, WNS -0.228 ns, no bitstream
```

Build commands:

```powershell
.\scripts\run_vivado_build_arty_a7.ps1 -MultiExercise -NumLanes 4 -ClockPeriodNs 9.5 -TimeoutSeconds 21600
.\scripts\run_vivado_build_arty_s7.ps1 -MultiExercise -NumLanes 2 -ClockPeriodNs 10.5 -TimeoutSeconds 21600
```

## Freshness and Provenance Gate

`results/claims/claim_evidence.json` records:

- git commit and dirty-worktree state;
- implementation, simulation, and C++ source hashes;
- generated divider-model hash;
- compiler and CPU identity;
- Vivado version, device, top, core, lanes, and routed clock source;
- input report paths and hashes;
- raw prices, cycles, and benchmark aggregates;
- every reason a report is or is not claim-ready.

The current combined source fingerprint is:

```text
dbe34c6eb5503063ca63551f817a0fe27e7128686a08d2bac4e8251b7eb2ea35
```

A dirty worktree is acceptable only because the fingerprint binds the evidence
to exact contents. A polished release should commit the verified source and
regenerate evidence so commit and source state agree cleanly.

## CPU Benchmark Gate

Google Benchmark acceptance requires:

- Release mode;
- all three named complete-pricing boundaries;
- exact 1,024 x 4 and 1,024 x 12 workloads;
- at least 15 repetitions;
- expected raw-price checks inside timed fixtures;
- machine-readable JSON;
- recorded compiler and CPU;
- no substitution of process-startup timing for a kernel boundary.

The corrected means are in [`performance.md`](performance.md) and the generated
claim report. Do not compare Google Benchmark to UART round-trip and call the
ratio a core speedup.

## UART Protocol Gate

For one hardware job:

1. host packs eight 32-bit parameter words;
2. FPGA echoes all eight;
3. FPGA sends marker `0xABCD0001`;
4. FPGA sends signed Q16.16 raw price;
5. FPGA sends low and high cycle words;
6. host verifies exercise mode and lane assertion;
7. `--target both` requires exact CPU/FPGA raw parity.

Correct S7 command:

```powershell
python src\uart_host.py `
  --mode benchmark `
  --target both `
  --param-file baseline\cpp_fixed\params_latency_1024x4.txt `
  --exercise-mode multi `
  --num-lanes 2 `
  --port COM4 `
  --fpga-fclk-hz 95238095 `
  --fpga-repetitions 100 `
  --build-cpu
```

Acceptance values are raw price 391,343 and 159,398 cycles. Record the physical
return rather than silently replacing it with the model.

## Current Physical Status

The checked programmer detected `xc7s50` and loaded the retained S7 image. All
100 repetitions returned raw price 391,343 and 159,398 cycles. The physical core
interval is 1.673679 ms; zero-gap UART transport p50/p95/p99 is
15.974/16.147/16.240 ms.

The UART receiver now uses a two-stage asynchronous synchronizer and rejects bad
stop bits. The host now sends one 32-byte request write. Earlier unpaced failures
were caused by `_read_exact()` mutating pyserial's `timeout` after transmit and
thereby reconfiguring the Windows COM handle, not by a cable defect or a UART
requirement for millisecond gaps. The earlier zero-price image remains excluded.

## Automated Python Regression

Run all repository tests:

```powershell
python -m unittest discover -s tests -v
```

Focused evidence tests:

```powershell
python -m unittest tests.test_reproduce_claims -v
python -m unittest tests.test_uart_host -v
```

The test suite checks parsers, provenance rules, cycle expectations, UART
framing/error behavior, and evidence-report requirements. It does not replace
xsim or Vivado; it protects the tooling around them.

## Release Decision

A corrected release is ready for source-level and routed claims when Levels 1
through 5 pass and the tracked evidence says `CLAIM-READY`. S7 physical and
transport claims are ready after Levels 6 and 7; A7 physical claims remain
pending.

When a defect changes a vendor-IP contract, invalidate every downstream artifact
instead of updating only the final table. That is the central lesson of this
validation pass.
