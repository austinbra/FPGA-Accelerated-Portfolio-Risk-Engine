# FPGA Build and Board Lab Manual

This guide starts where RTL simulation ends. It explains what Vivado must do,
which project to open, how lane count and period are selected, how to read timing
reports, how to program a board, and how to decide whether a result is valid.

The validated configurations in this repository use Vivado 2025.1. Menus can
move slightly in other releases, but the implementation concepts are the same.

## 1. The Flow After Simulation

Simulation asks, "Does the described logic behave correctly for the tested
inputs and clock events?" It does not prove that the logic fits a particular
FPGA or can run at a requested clock.

Vivado then performs these stages:

1. **Synthesis** converts SystemVerilog and IP into a device-level netlist of
   LUTs, flip-flops, DSPs, block RAMs, clock resources, and connections.
2. **Optimization** simplifies and restructures the synthesized netlist.
3. **Placement** assigns every cell to a physical site on the FPGA.
4. **Physical optimization** repairs selected congestion and timing problems
   using placement-aware transformations.
5. **Routing** selects physical wires and switches for every connection.
6. **Static timing analysis** checks every constrained register-to-register
   path without requiring a test vector.
7. **DRC and route checks** verify that the device is fully and legally routed.
8. **Bitstream generation** creates the configuration image loaded over JTAG.
9. **Programming** transfers the bitstream to the physical FPGA.
10. **Hardware validation** sends known jobs and compares price, cycles, and
    transport behavior with the reference model.

"Generate Bitstream" in the GUI normally launches any missing synthesis and
implementation stages automatically. It does not make place-and-route optional;
it merely chains those steps behind one button.

## 2. Two Clocks You Must Keep Separate

Both Arty boards have a 100 MHz oscillator. The XDC constrains that physical
input:

```tcl
create_clock -add -name board_clk_100mhz -period 10.000 -waveform {0.000 5.000} [get_ports CLK100MHZ]
```

Changing this line to 10.5 ns tells timing analysis a false fact; it does not
slow the oscillator. The corrected board wrappers instantiate an MMCM:

```text
100 MHz input -> 1 GHz VCO -> selectable output divider -> core clock BUFG
```

For the validated S7 build, the generated core is 95.238095 MHz with a
10.500 ns period. For the validated A7 build, it is 105.263158 MHz with a
9.500 ns period. Vivado derives the generated clock as
`core_clk_unbuffered`.

The UART transmitter also receives the generated `CORE_CLK_FREQ_HZ`, so its baud
divider remains correct when the core period changes.

## 3. Why Generated Projects Are Fixed Snapshots

A Vivado `.xpr` in this repository is created from a complete `synth.dcp`.
Synthesis has already resolved:

- `MULTI_EXERCISE`;
- `NUM_LANES`;
- MMCM output divide and core period;
- core clock frequency passed to UART;
- all generate blocks and parameter-dependent widths.

You cannot turn a 2-lane 10.5 ns checkpoint into a 1-lane 11 ns checkpoint by
editing a displayed parameter after synthesis. Build a new snapshot with the
PowerShell command instead.

The source of truth is:

```text
PowerShell options
  -> environment variables
  -> board-specific Tcl
  -> common validated build helper
  -> exact output directory and manifest
```

## 4. Retained Project Matrix

Only these complete projects should be used:

| Board | Mode | Lanes | Core period | Purpose |
|---|---|---:|---:|---|
| A7-100T | multi | 4 | 9.500 ns | canonical passing build |
| S7-50 | multi | 2 | 10.500 ns | canonical passing build |

Open paths:

```text
vivado_build/arty_a7_100_multi_lanes4_9p5ns_rowopt/gui_post_synth/arty_a7_qmc_post_synth.xpr
vivado_build/arty_s7_50_multi_lanes2_10p5ns_rowopt/gui_post_synth/arty_s7_qmc_post_synth.xpr
```

The board build scripts accept:

- S7: `-NumLanes 1` or `2`;
- A7: `-NumLanes 1`, `2`, or `4`;
- periods from 2 to 128 ns in legal 0.125 ns steps.

Eight lanes remains a simulation experiment because it does not fit these board
flows. The scripts reject it before launching Vivado.

## 5. Rebuild from Source

Close any Vivado project that points at the same output directory before
rebuilding it. A running GUI can hold implementation status files open.

### Spartan-7 default

```powershell
.\scripts\run_vivado_build_arty_s7.ps1 `
  -MultiExercise `
  -NumLanes 2 `
  -ClockPeriodNs 10.5 `
  -TimeoutSeconds 21600
```

Canonical retained directory:

```text
vivado_build/arty_s7_50_multi_lanes2_10p5ns_rowopt
```

Pass that path with `-OutputDir` only when intentionally reproducing the
canonical artifact; otherwise the script creates its normal configuration
name.

### Artix-7 canonical

```powershell
.\scripts\run_vivado_build_arty_a7.ps1 `
  -MultiExercise `
  -NumLanes 4 `
  -ClockPeriodNs 9.5 `
  -TimeoutSeconds 21600
```

Canonical retained directory:

```text
vivado_build/arty_a7_100_multi_lanes4_9p5ns_rowopt
```

### A new lane/period experiment

For example, a 1-lane S7 at 11 ns:

```powershell
.\scripts\run_vivado_build_arty_s7.ps1 `
  -MultiExercise `
  -NumLanes 1 `
  -ClockPeriodNs 11.0 `
  -TimeoutSeconds 21600
```

Do not use `-OutputDir` unless you have a specific reason. The automatic name
records board, mode, lanes, and period and prevents accidental overwrites.

## 6. What the Build Script Does

The common Tcl helper performs the following:

1. validates the requested period against the MMCM divide grid;
2. reads RTL, board wrapper, generated tables, and physical XDC;
3. creates/generates `fxDiv_core` with the tested signed 48/32 configuration;
4. synthesizes with the exact top-level generics;
5. saves a complete `synth.dcp`;
6. creates a gate-level GUI project from that checkpoint;
7. runs `opt_design -directive ExploreArea`;
8. runs `place_design -directive Explore`;
9. runs `phys_opt_design -directive Explore`;
10. runs `route_design -directive Explore -tns_cleanup`;
11. writes timing, utilization, route-status, and DRC reports;
12. rejects negative WNS or WHS;
13. writes the bitstream only after the timing gate passes;
14. writes `build_manifest.json` with the exact configuration and slack.

The runner streams Vivado output to `.tmp` and enforces a wall-clock timeout so
a stalled batch process cannot silently become a result.

## 7. Using the Vivado GUI

### Open the right project

1. Start Vivado.
2. Choose **Open Project**.
3. Browse to one of the two retained `.xpr` files.
4. Confirm the title/path contains the intended board, lane count, and period.
5. In **Design Runs**, confirm there is one implementation run named `impl_1`.

This is a post-synthesis project. It is normal for the Sources pane to look
different from a hand-created RTL project.

### Re-run implementation

If the project already contains a completed run:

1. In **Design Runs**, right-click `impl_1`.
2. Choose **Reset Run** if you intentionally want to discard its current
   placement and route.
3. Right-click `impl_1` and choose **Launch Runs**.
4. Wait through optimization, placement, physical optimization, routing, and
   bitstream generation.
5. Do not close Vivado while the run is active.

A reroute can produce slightly different placement and slack. Recheck every
acceptance item rather than assuming the previous numbers.

### Open the implemented design

1. In **Flow Navigator**, click **Open Implemented Design**.
2. Wait for the routed checkpoint to load.
3. Read the status bar and Messages pane for DRC or route errors.
4. Use **Reports > Timing > Report Timing Summary** if no timing tab exists.

## 8. Reading Timing Correctly

### Setup timing

Setup analysis asks whether data launched on one active clock edge reaches the
next register early enough for its capture edge.

- **WNS** is worst negative slack. Positive is passing margin; negative is the
  size of the worst setup miss.
- **TNS** sums only negative setup slack over failing endpoints.
- **Failing endpoints** counts destination pins that miss setup.

A valid passing setup result has WNS >= 0, TNS = 0, and zero failing endpoints.

### Hold timing

Hold analysis asks whether newly launched data changes too soon after the same
capture edge.

- **WHS** is worst hold slack.
- **THS** sums negative hold slack.

A valid passing hold result has WHS >= 0, THS = 0, and zero failing endpoints.

### The correct clock name

In the Tcl Console:

```tcl
get_clocks
get_property PERIOD [get_clocks core_clk_unbuffered]
get_property FREQUENCY [get_clocks core_clk_unbuffered]
```

Use `get_clocks` first. A command against `sys_clk` fails if no clock object has
that name in the implemented netlist. The corrected reports use
`core_clk_unbuffered` for core paths.

### Open the actual worst path

In the Timing Summary:

1. Expand **Intra-Clock Paths**.
2. Double-click the blue WNS value for `core_clk_unbuffered`.
3. Double-click the first path in the lower path table.
4. Read **Source**, **Destination**, **Requirement**, **Data Path Delay**, logic
   delay, route delay, logic levels, and slack.

Equivalent Tcl:

```tcl
report_timing -delay_type max -max_paths 10 -sort_by group
report_timing -delay_type min -max_paths 10 -sort_by group
report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose
```

The canonical worst setup paths are:

- A7 9.5 ns: `lane_sumy_reg[2][2]` to `reg_mat_reg[3][24]`,
  9.094 ns data delay, 23 logic levels, and +0.121 ns slack.
- S7 10.5 ns: `state_reg[3]/C` to bank-1 spot-memory `ADDRBWRADDR[8]`,
  9.602 ns data delay, 86.5% route delay, and +0.165 ns slack.

A path with mostly route delay suggests congestion/fanout/placement. A path with
many logic levels suggests pipelining or algebraic restructuring. Always inspect
several worst paths; fixing only one path can expose the next.

## 9. Reading Utilization and Route Health

Open **Reports > Report Utilization** and record:

- Slice LUTs;
- Slice registers;
- DSP48E1s;
- block RAM tiles;
- clocking resources.

High utilization is not automatically failure, but it raises congestion and
routing risk. The S7 build is especially dense at 93.31% LUT, 96.67% DSP, and
86.67% BRAM.

Also inspect:

```text
route_status.rpt
drc_post_route.rpt
```

Reject a release if route status reports failed, unrouted, partially routed, or
overlapping nets. Review DRC warnings in context; do not equate a generated
bitstream with a clean implementation.

## 10. Efficient Iteration and Period Search

Do not run a full matrix after every edit. Use this ladder:

1. run focused unit simulation;
2. run one full-core generated-divider simulation;
3. reuse the last synthesis checkpoint for strategy-only implementation work;
4. rebuild synthesis only when RTL, top parameters, generated clock, or
   constraints change;
5. keep one conservative passing build per board;
6. test only the adjacent faster legal period to bracket the boundary;
7. run the complete evidence collector only for a release snapshot.

In the GUI, enable **Incremental Implementation** and select the previous routed
checkpoint when experimenting with place/route directives on the same synthesized
netlist. A lane or MMCM-period change alters the synthesized snapshot and needs a
new synthesis run. Generated IP should remain cached unless its configuration
changes.

A period search is a controlled experiment:

1. hold RTL, lanes, Vivado version, strategy, and seed constant;
2. start from a passing period with useful margin;
3. reduce by one legal 0.125 ns step;
4. perform a complete place-and-route, not synthesis only;
5. record WNS, WHS, route status, utilization, and worst path;
6. stop at the first failure unless an obvious low-risk optimization exists;
7. rerun the selected default from clean source.

Do not infer timing closure from synthesis estimates. Placement and routing are
where physical wire delay appears.

Current search evidence:

| Target | Passing point | Adjacent evidence | Decision |
|---|---:|---|---|
| S7, 2 lanes | 10.500 ns, WNS +0.165 | 10.375 ns, WNS -0.228 | retain 10.500 ns |
| A7, 4 lanes | 9.500 ns, WNS +0.121 | 9.375 ns, WNS -0.153 | retain 9.500 ns |

Both adjacent failures were fully routed. If RTL, strategy, Vivado version, or
seed changes, rerun only this passing point and its adjacent faster step.

## 11. RTL Optimization Made in This Pass

Reset deassertion is synchronized and distributed through a BUFG. The pricing
core now registers the valuation intrinsic in its existing initialization state
and narrows row/path counters to their configured ranges. This removed the S7
`scan_row` carry chain from the worst path and reduced LUT pressure without
changing raw prices or cycle counts.

`ExploreWithRemap` is an `opt_design` directive, selected from the run's
implementation settings or supplied in Tcl. It was tested here and increased
LUT pressure, so the final flow uses `opt_design -directive ExploreArea`.
It is not a separate command you need to run.

The corrected routes now expose arithmetic paths. Pipelining them would change
ready/valid timing, cycle counts, and verification expectations. Both targets
close at the selected periods, so no speculative arithmetic pipeline was
added.

## 12. Generate and Locate the Bitstream

A passing batch build creates:

```text
arty_a7_qmc_multi.bit
arty_s7_qmc_multi.bit
```

inside the exact build directory. In the GUI, **Generate Bitstream** should be
used only after confirming the project is the intended configuration. The
common batch flow is preferred for release evidence because it checks slack
before bitstream writing and records a manifest.

Current hashes:

```text
A7 9.5 ns:  708C312F611909598B9B509B57F08D07C3A247CB9FC0C15820CAD5B7557CE8EF
S7 10.5 ns: 729F8D9099A1A84B81C4D784FF7EF18343B72C364C897557F537692A173C5178
```

A hash identifies a file; it does not by itself prove timing or function.

## 13. Program the Board

### Through the GUI

1. Connect the board's programming USB port with a data-capable cable.
2. Power the board and verify its power LED.
3. Open **Hardware Manager**.
4. Click **Open Target > Auto Connect**.
5. Confirm the detected part matches the bitstream (`xc7s50...` for S7-50 or
   `xc7a100t...` for A7-100T).
6. Right-click the FPGA and choose **Program Device**.
7. Select the corrected `.bit` file.
8. Click **Program**.
9. A DONE LED means configuration completed. It does not prove pricing parity,
   UART function, timing in silicon, or the expected lane/mode image.

### Through the checked script

List the JTAG part first when you are unsure which board/cable Vivado sees:

```powershell
.\scripts\detect_xilinx_hw.ps1 -TimeoutSeconds 120
```

S7:

```powershell
.\scripts\program_arty_s7.ps1 -TimeoutSeconds 600
```

A7:

```powershell
.\scripts\program_arty_a7.ps1 -TimeoutSeconds 600
```

The S7 script checks that JTAG reports an XC7S50. If another Vivado Hardware
Manager already owns the target, close that target or close Vivado cleanly and
retry. Do not bypass the part check for reportable measurements.

## 14. Find the UART COM Port

Use Device Manager under **Ports (COM & LPT)**, or:

```powershell
Get-CimInstance Win32_SerialPort | Select-Object DeviceID,Name
```

A board appearing in JTAG proves the cable carries data for programming. The
UART interface may appear as a separate FTDI/Digilent channel and COM number.
Use the COM port associated with the board, not a random Bluetooth port.

## 15. Run the First Hardware Parity Job

For the corrected 2-lane S7 image:

```powershell
python src\uart_host.py `
  --mode benchmark `
  --target both `
  --param-file baseline\cpp_fixed\params_latency_1024x4.txt `
  --exercise-mode multi `
  --num-lanes 2 `
  --port COM4 `
  --fpga-fclk-hz 95238095 `
  --fpga-repetitions 1 `
  --build-cpu
```

Change `COM4` only if Device Manager reports another port.

Expected functional result:

```text
CPU raw price:  391343
FPGA raw price: 391343
Q16.16 parity:  MATCH
```

The generated-IP model and the physical S7-50 both return 159,398 core cycles
for this 2-lane case. Require that exact count before accepting another board
run.

For the A7 4-lane 9.5 ns image, use `--num-lanes 4` and
`--fpga-fclk-hz 105263158`. Its generated-model results are 91,302 cycles
for 1,024 x 4 and 293,790 cycles for 1,024 x 12.

## 16. Understand the UART Words

The host sends eight 32-bit parameter words as separate guarded writes. This
avoids the framing errors observed with an unpaced FTDI burst; the guard remains
part of transport time, not core time. The FPGA echoes all eight so byte
alignment and endianness can be checked. It then sends four result words:

```text
0: 0xABCD0001                    completion marker
1: signed Q16.16 price
2: core_cycles low 32 bits
3: core_cycles high 32 bits
```

The host combines cycle words as:

```text
core_cycles = word2 | (word3 << 32)
core_seconds = core_cycles / implemented_core_frequency_hz
```

The cycle counter spans complete job acceptance through `result_valid`. UART
round-trip spans host write through receipt of the complete result packet. Keep
both; never call UART round-trip "FPGA compute time."

## 17. Repeat for Transport Statistics

Only after one parity run passes:

```powershell
python src\uart_host.py `
  --mode benchmark `
  --target fpga `
  --param-file baseline\cpp_fixed\params_latency_1024x4.txt `
  --exercise-mode multi `
  --num-lanes 2 `
  --port COM4 `
  --fpga-fclk-hz 95238095 `
  --fpga-repetitions 30
```

Accept the run only if every repetition returns the same raw price and cycle
count. Report transport p50/p95/p99 separately from core latency.

The corrected physical S7 run passed 30/30 with raw price 391,343, 159,398
cycles, 1.673679 ms core time, and 31.981/32.764/33.207 ms transport
p50/p95/p99.

## 18. Common Failure Modes

### `No clocks matched 'sys_clk'`

You queried a name not present in the opened design. Run `get_clocks`, then use
`core_clk_unbuffered` for the generated core clock.

### WNS is `inf` and Vivado says there are no user constraints

The XDC was not applied, the wrong top was selected, or you opened a project
that does not contain the complete constrained checkpoint. Use one of the
retained projects or rerun the checked build script.

### Place Design says there are more LUTs than available

The selected lane count or stale netlist does not fit. Directives cannot create
missing device capacity. Check `build_manifest.json`, top generics, and the
board lane limits.

### `save_project` says a name is missing

`save_project` is not the command needed here. Use **File > Save Project** in
the GUI, or `save_project_as <name> <directory>` when intentionally creating a
new project. The checked flow creates the project automatically.

### UART echo words are shifted or multiplied by powers of 256

The wrong COM channel, baud, bitstream, or an unpaced custom sender can cause
this. The checked host sends guarded 32-bit words. `--fpga-fclk-hz` converts
cycles to seconds; it does not configure UART timing.

### UART echo is correct but price is zero

Transport is working, but the pricing image is not functionally valid. The old
S7 image did exactly this because it used the wrong divider output slice.
Program the corrected retained bitstream and require raw-price parity.

### Programmer says the hardware target is owned by another client

A Vivado GUI Hardware Manager has it open. In that GUI choose **Close Hardware
Target**, or close Vivado after saving work, then rerun the script.

### Power report shows hundreds of watts

A vectorless estimate with invalid switching assumptions is not credible. Do
not report it. Provide realistic activity from simulation/SAIF and verify clock,
toggle, thermal, and board assumptions before making a power claim.

## 19. Release Checklist

A configuration is valid only when all relevant items are true:

- [ ] directory name records board, mode, lanes, and period;
- [ ] `build_manifest.json` matches those values;
- [ ] physical input XDC remains 10.000 ns;
- [ ] generated core clock period matches the requested period;
- [ ] synthesis completes with the expected top;
- [ ] route is complete with no failed/unrouted/partial nets;
- [ ] WNS >= 0 and TNS = 0;
- [ ] WHS >= 0 and THS = 0;
- [ ] setup and hold failing endpoints are zero;
- [ ] DRC has no blocking errors;
- [ ] bitstream exists and its hash is recorded;
- [ ] full RTL passes with generated divider VHDL;
- [ ] C++ and RTL raw prices are bit-exact;
- [ ] physical JTAG part matches the claimed board;
- [ ] physical raw price and cycle count are stable;
- [ ] core and transport boundaries are reported separately.

Passing simulation is the beginning of this list, not the end.
