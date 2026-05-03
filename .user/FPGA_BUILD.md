# FPGA Build Notes

This file records how to reproduce the inherited kernel bitstreams and how to interpret the reports. The product fork should keep these flows stable while portfolio, scenario, and Greeks tooling grows around the kernel.

## A7-100T Multi-Date Kernel Build

Command:

```powershell
.\scripts\run_vivado_build_arty_a7.ps1 -MultiExercise -ClockPeriodNs 10 -TimeoutSeconds 21600
```

Artifacts:

```text
vivado_build/arty_a7_100_multi_10ns/timing_post_route.rpt
vivado_build/arty_a7_100_multi_10ns/utilization.rpt
vivado_build/arty_a7_100_multi_10ns/arty_a7_qmc_multi.bit
```

Measured post-route timing:

- clock: 10 ns / 100 MHz
- WNS: `+0.153 ns`
- TNS: `0.000 ns`
- setup failing endpoints: `0`
- hold WNS: `+0.010 ns`

Measured post-route resources:

- Slice LUTs: `23,167 / 63,400 = 36.54%`
- Slice registers: `27,873 / 126,800 = 21.98%`
- DSP48E1: `80 / 240 = 33.33%`
- RAMB36: `16 / 135 = 11.85%`

## S7-50 Multi-Date Kernel Build

Command:

```powershell
.\scripts\run_vivado_build_arty_s7.ps1 -MultiExercise -ClockPeriodNs 10 -TimeoutSeconds 21600
```

Artifacts:

```text
vivado_build/arty_s7_50_multi_10ns/timing_post_route.rpt
vivado_build/arty_s7_50_multi_10ns/utilization.rpt
vivado_build/arty_s7_50_multi_10ns/arty_s7_qmc_multi.bit
```

Measured post-route timing:

- clock: 10 ns / 100 MHz
- WNS: `+0.113 ns`
- TNS: `0.000 ns`
- setup failing endpoints: `0`
- hold WNS: `+0.013 ns`

Measured post-route resources:

- Slice LUTs: `23,154 / 32,600 = 71.02%`
- Slice registers: `27,873 / 65,200 = 42.75%`
- DSP48E1: `80 / 120 = 66.67%`
- RAMB36: `16 / 75 = 21.33%`

## What Changed To Reach 100 MHz

The old multiplier latency setting delayed a result after the full combinational multiply and Q-format scaling had already happened. That did not truly shorten the path.

The final `fxMul` splits the path:

```text
operands -> raw 64-bit product register -> Q16.16 round/shift register -> output
```

Then the multi-date final divider was split so the quotient update and `result_price` saturation/writeback happen in separate cycles.

Files:

- `src/math/fxMul.sv`
- `src/fpga_cfg_pkg.sv`
- `src/steps/GBM.sv`
- `src/top/top_option_pricer_multi.sv`

## Product-Layer Rule

Do not change RTL first. Build portfolio, scenario, and Greeks flows against the current C++ mirror and UART path, then profile:

- CPU mirror runtime,
- FPGA `core_cycles / fclk`,
- UART round-trip time,
- batch scheduling overhead.

Only change RTL when those measurements show a concrete bottleneck.

## Single-Date Build

The historical single-date build remains available:

```powershell
.\scripts\run_vivado_build_arty_a7.ps1 -TimeoutSeconds 14400
```

The product fork should use the multi-date build for the current American PUT foundation.

## Program A7 Hardware

```powershell
.\scripts\program_arty_a7.ps1 -Bit vivado_build\arty_a7_100_multi_10ns\arty_a7_qmc_multi.bit
```

Then run:

```powershell
python src\uart_host.py --mode benchmark --target both --param-file baseline\cpp_fixed\params_example.txt --port COM4 --fpga-fclk-hz 100000000 --build-cpu
```

## Program S7 Hardware

Use Vivado Hardware Manager or a board-specific programming script with:

```text
vivado_build/arty_s7_50_multi_10ns/arty_s7_qmc_multi.bit
```

Then use the same `uart_host.py` flow with the S7 COM port.

## Virtual Benchmark

No-board benchmark:

```powershell
.\scripts\run_virtual_a7_benchmark.ps1 -ParamFile baseline\cpp_fixed\params_example.txt -NumLanes 1 -FclkHz 100000000
```

This runs RTL simulation, reads the DUT `core_cycles`, and reports:

```text
compute_seconds = core_cycles / FclkHz
```

It is a cycle-accurate core estimate at the implemented clock, not a physical UART round-trip measurement.

## Build Script Notes

The multi-date A7 flow uses in-process Vivado implementation instead of `launch_runs` because the Windows WMI/JScript run wrapper previously hung. The in-process sequence is:

```text
synth_design
opt_design
place_design
phys_opt_design -directive Explore
route_design
report_timing_summary
report_utilization
write_bitstream
```

The S7 flow uses the same hardened approach for multi-date builds.

## Board Resource Interpretation

S7-50 is the tighter foundation target:

- LUT: 71.02%, close enough to be meaningful but not over budget.
- DSP: 66.67%, also meaningful.
- BRAM: 21.33%, not the limiting resource.

A7-100T has comfortable headroom:

- LUT: 36.54%.
- DSP: 33.33%.
- BRAM: 11.85%.

This is why path batching is deferred. The final architecture does not have a BRAM overflow problem at current `MAX_PATHS`.
