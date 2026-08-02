# FPGA QMC-LSM Risk Engine

This fork extends the original FPGA-accelerated option pricer toward a queued,
multi-mode pricing and risk fabric. The implemented core is still a
single-contract QMC-LSM accelerator. Shared-path scenario evaluation, Asian
state, randomized-QMC uncertainty, and multi-context execution are roadmap
items rather than implemented claims.

The project is useful as a hardware/software co-design case study: a Sobol QMC
path generator, fixed-point GBM, discrete-date Longstaff-Schwartz exercise,
bit-exact C++ validation, SystemVerilog RTL, UART control, routed FPGA builds,
and boundary-explicit performance measurement all live in one reproducible flow.

## Important Measurement Correction

A July 2026 audit found two problems in the earlier hardware evidence:

1. Xilinx `div_gen` packs the 48-bit quotient in output bits `[79:32]` and the
   32-bit remainder in `[31:0]`. `src/math/fxDiv.sv` had selected `[47:16]`.
2. The simulation-only divider stub returned in one cycle, while the generated
   Vivado divider has a 32-cycle request-to-response contract.

The RTL slice, calibrated stub, and divider unit test are now corrected. Both
canonical full-core workloads were rerun with the generated `div_gen`
behavioral VHDL model, and both FPGA targets were synthesized, placed, routed,
and written as new bitstreams from the corrected RTL.

Consequences:

- Old FPGA cycle counts, utilization, routed timing, bitstreams, and any ratios
  derived from them are invalid for the corrected kernel.
- The earlier S7 board response with price zero is not pricing parity. It showed
  that programming worked, but it used the bad divider image.
- The rebuilt S7 image now has 100-run physical raw-price and cycle parity; its
  measured UART transport distribution is reported separately from core time.
- C++ raw prices, the independent financial-reference study, Sobol data, UART
  packet format, and algorithm-level work that did not depend on the bad RTL
  divider slice remain useful.

Use only the results and project paths in this document or in
[`results/claims/claim_evidence.md`](results/claims/claim_evidence.md).

## Implemented Scope

Implemented now:

- signed Q16.16 arithmetic;
- Sobol QMC paths from `src/gen/direction.mem`;
- geometric Brownian motion under constant `r` and `sigma`;
- multi-date PUT exercise on simulated dates `1..M-1`;
- terminal-only no-dividend CALL handling;
- valuation-time intrinsic-value floor;
- up to 1,024 paths and 50 dates in the stored-path RTL;
- 1, 2, or 4 simulated lanes, with board-specific fit limits;
- exact C++/RTL raw-price checks;
- routed A7-100T and S7-50 bitstreams;
- UART parameter/result framing and a persistent host session;
- a five-job common-random-number bump/revalue runner for delta, gamma, and
  vega experiments.

Not implemented yet:

- portfolio CSV ingestion and aggregation;
- scenario cubes or batched hardware queues;
- multi-asset correlation or path-dependent payoffs;
- dividend yield, calibration, or live market data;
- PCIe, Ethernet, or AXI host transport;
- randomized Sobol scrambles, independent replicas, or confidence intervals;
- Brownian-bridge/PCA dimension reduction;
- saturation-safe wider or block-normalized regression beyond the current
  Q16.16 solver boundary;
- shared normal/path reuse across related base and bumped jobs;
- Asian running-average state or multivariable continuation regression;
- overlapping job contexts or queued mixed-product execution;
- production risk controls or production trading guarantees.

## Corrected FPGA Builds

The board oscillator remains 100 MHz. Each wrapper uses a 7-series MMCM to
create the requested core period, and the UART divider is parameterized with
the matching generated frequency. The XDC therefore always constrains the
physical input clock to 10.000 ns; changing the XDC to 10.5 ns does not create a
95.238 MHz clock.

| Canonical project | Device/configuration | Core clock | WNS | WHS | LUT | Registers | DSP | BRAM |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| `arty_a7_100_multi_lanes4_9p5ns_rowopt` | XC7A100T, multi, 4 lanes | 105.263 MHz | +0.121 ns | +0.008 ns | 44,768 (70.61%) | 49,241 (38.83%) | 180 (75.00%) | 66 (48.89%) |
| `arty_s7_50_multi_lanes2_10p5ns_rowopt` | XC7S50, multi, 2 lanes | 95.238 MHz | +0.013 ns | +0.013 ns | 30,310 (92.98%) | 36,816 (56.47%) | 116 (96.67%) | 65 (86.67%) |

Both have TNS = 0, THS = 0, zero setup/hold failing endpoints, and a complete
routed design. They are the only canonical GUI projects for this release.

Period-search conclusions apply to the tested Vivado 2025.1 strategy and seed:

- S7 2-lane at 10.375 ns routed with WNS = -0.228 ns, so 10.5 ns is the
  fastest passing legal 0.125 ns step tested.
- A7 4-lane at 9.500 ns passes with WNS = +0.121 ns. The adjacent 9.375 ns
  build fails with WNS = -0.153 ns, so 9.500 ns is the selected boundary.

These are characterized operating points, not universal silicon fmax claims.
Process, voltage, temperature, Vivado version, strategy, and seed still matter.

### Retained GUI projects

Open only these `.xpr` files:

```text
vivado_build/arty_a7_100_multi_lanes4_9p5ns_rowopt/gui_post_synth/arty_a7_qmc_post_synth.xpr
vivado_build/arty_s7_50_multi_lanes2_10p5ns_rowopt/gui_post_synth/arty_s7_qmc_post_synth.xpr
```

Each is a gate-level project created from a complete synthesis checkpoint. Its
lane count and period are already baked into that checkpoint. To try another
configuration, rerun the parameterized build script; do not edit top-level
parameter defaults inside an existing generated project.

## Corrected Functional Evidence

The generated Vivado divider model and the calibrated simulation stub agree on
five signed and divide-by-zero unit cases, with exactly 32 wait cycles for each
accepted nonzero request.

Canonical four-lane A7 simulations and routed-clock conversions:

| Workload | Raw Q16.16 price | C++/RTL parity | Core cycles | Time at 105.263 MHz |
|---|---:|---|---:|---:|
| 1,024 paths x 4 steps | 391,343 | bit-exact | 91,302 | 0.867369 ms |
| 1,024 paths x 12 steps | 428,757 | bit-exact | 293,790 | 2.791005 ms |

The S7 2-lane 1,024 x 4 generated-IP simulation and physical board both return
raw price 391,343 and 159,398 cycles, or 1.673679 ms at 95.238 MHz. This is a
physical core-latency measurement for the retained S7 bitstream. Other
lane/workload cycle rows from the stale divider binding were removed rather
than extrapolated; the A7 rows remain post-route, cycle-derived intervals.

## CPU Comparison

Google Benchmark was built in Release mode with MinGW g++ 14.2.0 and run for 15
repetitions on the recorded Intel Family 6 Model 186 host. Each ratio is exactly
`CPU mean real time / FPGA core time` for the named boundary.

| Workload | CPU boundary | CPU mean | FPGA 4-lane core | CPU/FPGA ratio |
|---|---|---:|---:|---:|
| 1,024 x 4 | end to end | 0.889880 ms | 0.867369 ms | 1.026x |
| 1,024 x 4 | pricing core | 0.551170 ms | 0.867369 ms | 0.635x |
| 1,024 x 4 | hot kernel | 0.485392 ms | 0.867369 ms | 0.560x |
| 1,024 x 12 | end to end | 1.611681 ms | 2.791005 ms | 0.577x |
| 1,024 x 12 | pricing core | 1.208134 ms | 2.791005 ms | 0.433x |
| 1,024 x 12 | hot kernel | 1.187450 ms | 2.791005 ms | 0.425x |

A ratio above 1 means the FPGA core interval is shorter than that named CPU
boundary. A ratio below 1 means the CPU boundary is shorter. UART and Python are
excluded from FPGA core time and reported separately, so this repository does
not state a generic CPU-versus-FPGA speedup.

## Build and Verify

### C++ fixed-point mirror

```powershell
cd baseline\cpp_fixed
g++ -std=c++17 -O3 -DNDEBUG main.cpp pricing.cpp linalg.cpp rtl_math.cpp sobol_wrapper.cpp utils.cpp -o fixed_baseline
cd ..\..
.\baseline\cpp_fixed\fixed_baseline.exe --input-file baseline\cpp_fixed\params_latency_1024x4.txt --fpga-style --exercise-mode multi
```

### Claim-grade RTL simulation

The `-VendorDividerModel` option compiles the generated behavioral VHDL model,
not the convenience stub:

```powershell
.\scripts\run_tb_top_uart_safe.ps1 -MultiExercise -NumLanes 4 -VendorDividerModel vivado_build\arty_a7_100_multi_lanes4_9p5ns_rowopt\generated_ip\fxDiv_core\fxDiv_core\sim\fxDiv_core.vhd -TestPlusargs "paths=1024,steps=4,S0=6553600,K=6553600,r=3277,sigma=13107,T=65536,opt=1,expected_price=391343"
```

The evidence collector locates and fingerprints the generated model
automatically:

```powershell
python scripts\reproduce_claims.py --cpp-mode run --xsim-mode run --benchmark-mode run --vivado-mode run --require-complete
```

### Parameterized Vivado builds

```powershell
.\scripts\run_vivado_build_arty_a7.ps1 -MultiExercise -NumLanes 4 -ClockPeriodNs 9.5 -TimeoutSeconds 21600
.\scripts\run_vivado_build_arty_s7.ps1 -MultiExercise -NumLanes 2 -ClockPeriodNs 10.5 -TimeoutSeconds 21600
```

The build scripts validate legal board lane counts and legal 7-series MMCM
period increments, run synthesis through route, reject negative setup or hold
slack before bitstream creation, write reports and `build_manifest.json`, and
create one GUI project per exact configuration.

### Program the corrected S7 image

Close the obsolete Hardware Manager target first if Vivado says the target is
owned by another client, then run:

```powershell
.\scripts\program_arty_s7.ps1 -TimeoutSeconds 600
python src\uart_host.py --mode benchmark --target both --param-file baseline\cpp_fixed\params_latency_1024x4.txt --exercise-mode multi --num-lanes 2 --port COM4 --fpga-fclk-hz 95238095 --fpga-repetitions 100 --build-cpu
```

The physical S7 run returned raw price `391343` and `159398` core cycles in all
100 repetitions. Core time is `1.673679 ms`; zero-gap transport p50/p95/p99 was
`15.974/16.147/16.240 ms`. The host sends the complete 32-byte request in one
write. Earlier framing symptoms came from `_read_exact()` assigning pyserial's
`timeout` immediately after transmit, which reconfigured the Windows COM handle
while the FTDI could still be shifting data. The fixed host configures its read
timeout only when opening the port; no inter-word guard is required. Treat a
different raw price or cycle count as a failed physical parity check.

The FPGA sends eight echoed parameter words followed by four result words:

```text
word 0: 0xABCD0001 completion marker
word 1: signed Q16.16 price
word 2: core_cycles[31:0]
word 3: core_cycles[63:32]
```

UART round-trip starts at the host write and ends after all four result words.
It is transport latency, not core compute latency.

## Why This Matters for the Fork

The corrected kernel is a trustworthy starting point, but a low-dimensional
vanilla American option is not its most defensible final target: trees and PDEs
are strong competitors, and many European vanillas have closed forms. The
project becomes more interesting when one FPGA can keep reusable stochastic
work resident, route mixed requests, bypass unnecessary stages, and share paths
across related payoffs, scenarios, or risk calculations.

The roadmap therefore uses a hybrid fabric:

```text
tagged request -> classifier and queues
                  |-> analytic/interpolation fast lane
                  `-> shared Sobol/model path pipeline
                       -> configurable state/payoff
                          |-> European reduction
                          `-> stored-state LSM exercise
```

European jobs should not allocate path storage or regression resources unless
their payoff needs simulation. A European arithmetic-Asian job can use the
shared path generator and running-average state, then bypass LSM. A Bermudan
Asian job can reuse that forward infrastructure and regress continuation on
spot and average at the permitted exercise dates.

This does not imply one completed LSM contract per clock. Forward arithmetic
can be deeply pipelined, but LSM has population-wide regression barriers and
backward dependencies between exercise dates. Useful job overlap requires
tagged transactions, FIFOs, multiple memory contexts, and scheduling.

The FPGA remains the future implementation target. The existing fixed-point
C++ mirror stays as a bit-exact regression oracle; new C++ references should be
clear double-precision implementations that use the CPU's floating-point
strengths for rapid accuracy validation, not mandatory optimized CPU
competitors. Python remains the orchestration and reporting layer.

The gated sequence is in [`docs/roadmap.md`](docs/roadmap.md). Numerical range,
uncertainty, and Greek validation come before wider transport or a larger
device.

## Repository Map

```text
baseline/cpp_fixed/       bit-exact C++ mirror and Google Benchmark target
constraints/              physical board pin and 100 MHz input constraints
docs/                     build lab, accuracy, performance, and validation notes
fpga/                     A7/S7 wrappers and MMCM-based core clocks
results/claims/           tracked machine- and human-readable evidence
scripts/                  build, simulation, benchmark, programming, and risk tools
src/                      pricing RTL, generated tables, UART host, and sim model
tb/                       focused and full-system testbenches
vivado_build/             ignored generated projects for validated configurations
```

## Documentation

- [`PROJECT_REPORT.md`](PROJECT_REPORT.md): design history, correction, and extension direction.
- [`docs/fpga-build.md`](docs/fpga-build.md): step-by-step Vivado and board lab manual.
- [`docs/performance.md`](docs/performance.md): corrected timing and benchmark interpretation.
- [`docs/validation.md`](docs/validation.md): evidence hierarchy and release gates.
- [`docs/accuracy.md`](docs/accuracy.md): financial-reference methodology.
- [`docs/roadmap.md`](docs/roadmap.md): numerical gates and multi-mode FPGA architecture.
- [`docs/waveform-debugging.md`](docs/waveform-debugging.md): GTKWave UART lab and physical ILA guidance.
- [`baseline/cpp_fixed/README.md`](baseline/cpp_fixed/README.md): C++ mirror and Google Benchmark guide.
- [`results/claims/README.md`](results/claims/README.md): reproducible evidence collector.

## Claim Boundary

This is not a production trading engine and not a universal FPGA speedup claim.
It is a reproducible pricing-kernel prototype with corrected divider semantics,
bit-exact reference validation, implementation-clean A7/S7 configurations, and
an explicit path toward a saturation-safe, shared-stage FPGA pricing fabric. It
does not yet prove the usefulness or performance of that future architecture.
