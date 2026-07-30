# FPGA Build Notes

This file records how to reproduce the pricing-kernel bitstreams and interpret
the reports. The continued project keeps these flows stable while validation
and the narrow bump/revalue workflow evolve.

## Active A7-100T Four-Lane Multi-Date Build

This is the current headline implementation. The measurements below are from
the routed July 29, 2026 build of `arty_a7_option_pricer_top` for
`xc7a100tcsg324-1` with Vivado 2025.1.

Command:

```powershell
.\scripts\run_vivado_build_arty_a7.ps1 -MultiExercise -NumLanes 4 -ClockPeriodNs 10 -TimeoutSeconds 21600
```

Artifacts:

```text
vivado_build/arty_a7_100_multi_lanes4_10ns/timing_post_route.rpt
vivado_build/arty_a7_100_multi_lanes4_10ns/utilization.rpt
vivado_build/arty_a7_100_multi_lanes4_10ns/arty_a7_qmc_multi.bit
```

Measured post-route timing:

- clock: 10 ns / 100 MHz
- WNS: `+0.139 ns`
- TNS: `0.000 ns`
- setup failing endpoints: `0`
- hold WNS: `+0.014 ns`

Measured post-route resources:

- Slice LUTs: `45,955 / 63,400 = 72.48%`
- Slice registers: `46,905 / 126,800 = 36.99%`
- DSP48E1: `180 / 240 = 75.00%`
- Block RAM tiles: `66 / 135 = 48.89%`
- Slice sites: `14,483 / 15,850 = 91.38%`

## Historical and Pre-Hardening Routed Builds

These routes are retained as provenance for the architecture's development.
They predate the current four-lane A7 valuation-boundary hardening and are not
the source of the headline timing or utilization numbers.

### A7-100T Foundation / One Lane - May 3, 2026

Artifacts:

```text
vivado_build/arty_a7_100_multi_10ns/timing_post_route.rpt
vivado_build/arty_a7_100_multi_10ns/utilization.rpt
vivado_build/arty_a7_100_multi_10ns/arty_a7_qmc_multi.bit
```

- clock: 10 ns / 100 MHz
- WNS: `+0.153 ns`; TNS: `0.000 ns`; setup failing endpoints: `0`
- hold WNS: `+0.010 ns`
- Slice LUTs: `23,167 / 63,400 = 36.54%`
- Slice registers: `27,873 / 126,800 = 21.98%`
- DSP48E1: `80 / 240 = 33.33%`
- Block RAM tiles: `16 / 135 = 11.85%`

### S7-50 Foundation / One Lane

Artifacts:

```text
vivado_build/arty_s7_50_multi_10ns/timing_post_route.rpt
vivado_build/arty_s7_50_multi_10ns/utilization.rpt
vivado_build/arty_s7_50_multi_10ns/arty_s7_qmc_multi.bit
```

- clock: 10 ns / 100 MHz
- WNS: `+0.113 ns`; TNS: `0.000 ns`; setup failing endpoints: `0`
- hold WNS: `+0.013 ns`
- Slice LUTs: `23,154 / 32,600 = 71.02%`
- Slice registers: `27,873 / 65,200 = 42.75%`
- DSP48E1: `80 / 120 = 66.67%`
- Block RAM tiles: `16 / 75 = 21.33%`

### S7-50 Stored Paths / One Lane - June 24, 2026

Artifacts:

```text
vivado_build/arty_s7_50_multi_lanes1_10ns/timing_post_route.rpt
vivado_build/arty_s7_50_multi_lanes1_10ns/utilization.rpt
vivado_build/arty_s7_50_multi_lanes1_10ns/arty_s7_qmc_multi.bit
```

- clock: 10 ns / 100 MHz
- WNS: `+0.310 ns`; TNS: `0.000 ns`; setup failing endpoints: `0`
- hold WNS: `+0.014 ns`
- Slice LUTs: `23,399 / 32,600 = 71.78%`
- Slice registers: `28,967 / 65,200 = 44.43%`
- DSP48E1: `84 / 120 = 70.00%`
- Block RAM tiles: `65 / 75 = 86.67%`

### S7-50 Stored Paths / Two Lanes - June 24, 2026

Artifacts:

```text
vivado_build/arty_s7_50_multi_lanes2_10p5ns/timing_post_route.rpt
vivado_build/arty_s7_50_multi_lanes2_10p5ns/utilization.rpt
vivado_build/arty_s7_50_multi_lanes2_10p5ns/arty_s7_qmc_multi.bit
```

- clock: 10.5 ns / 95.24 MHz
- WNS: `+0.083 ns`; TNS: `0.000 ns`; setup failing endpoints: `0`
- hold WNS: `+0.017 ns`
- Slice LUTs: `30,606 / 32,600 = 93.88%`
- Slice registers: `34,855 / 65,200 = 53.46%`
- DSP48E1: `116 / 120 = 96.67%`
- Block RAM tiles: `65 / 75 = 86.67%`

The same two-lane S7 design missed the 10 ns / 100 MHz target by
`-0.180 ns` WNS. The 10.5 ns route above is the timing-clean historical
result.

## Architecture and Timing Evolution

The old multiplier latency setting delayed a result after the full combinational multiply and Q-format scaling had already happened. That did not truly shorten the path.

The final `fxMul` splits the path:

```text
operands -> raw 64-bit product register -> Q16.16 round/shift register -> output
```

Then the multi-date final divider was split so the quotient update and
`result_price` saturation/writeback happen in separate cycles. These were the
foundation timing fixes. The active design subsequently added four-lane,
banked stored-path execution, and the July route includes the valuation-time
intrinsic-value boundary hardening.

Files:

- `src/math/fxMul.sv`
- `src/fpga_cfg_pkg.sv`
- `src/steps/GBM.sv`
- `src/top/top_option_pricer_multi.sv`
- `src/top/top_option_pricer_multi_stored.sv`

## Product-Layer Rule

Do not change RTL first. Exercise the implemented single-contract
bump/revalue flow against the current C++ mirror and UART path, then profile:

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

Current validation should use the multi-date build for the discrete-time
American PUT approximation.

## Program A7 Hardware

```powershell
.\scripts\program_arty_a7.ps1 -Bit vivado_build\arty_a7_100_multi_lanes4_10ns\arty_a7_qmc_multi.bit
```

Then run:

```powershell
python src\uart_host.py --mode benchmark --target both --param-file baseline\cpp_fixed\params_latency_1024x4.txt --exercise-mode multi --num-lanes 4 --port COM4 --fpga-fclk-hz 100000000 --build-cpu
```

## Historical S7 Hardware

The S7 bitstreams above are retained for historical comparison and are not the
current headline target. If the stored-path one-lane S7 image is programmed for
an archival check, use Vivado Hardware Manager or a board-specific programming
script with:

```text
vivado_build/arty_s7_50_multi_lanes1_10ns/arty_s7_qmc_multi.bit
```

Pair it with `--num-lanes 1` and the S7 COM port. Do not compare that image to
a host invocation configured with `--num-lanes 4`.

## Virtual Benchmark

No-board benchmark:

```powershell
.\scripts\run_virtual_a7_benchmark.ps1 -ParamFile baseline\cpp_fixed\params_latency_1024x4.txt -NumLanes 4 -FclkHz 100000000 -ExerciseMode Multi
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

The historical S7 routes used the same in-process implementation sequence.

## Board Resource Interpretation

The active four-lane A7-100T route is meaningfully constrained:

- LUT: 72.48%.
- DSP: 75.00%.
- Block RAM: 48.89%.
- Slice sites: 91.38%, making physical packing tighter than the LUT count alone
  suggests.

The stored-path architecture made BRAM material without exhausting it, while
placement, LUT, and DSP headroom now limit straightforward lane replication.
The four-lane A7 route is therefore the densest routed headline build, not a
lightly utilized foundation image.

The historical S7-50 results show the scaling pressure more sharply. Its
stored-path one-lane route uses 86.67% of BRAM; the two-lane route uses 93.88%
of LUTs, 96.67% of DSPs, and 86.67% of BRAM, and closes at 95.24 MHz rather
than 100 MHz.

Future lane replication or on-chip path-capacity expansion should be driven by
measured workload benefit and accompanied by a new routed report. Host-side
batching can be evaluated separately without claiming that it is already part
of the RTL architecture.
