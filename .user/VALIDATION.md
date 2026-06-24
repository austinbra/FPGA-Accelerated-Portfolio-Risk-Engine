# Validation

This file is the internal verification playbook for the fork. The public summary lives in root `README.md` and `PROJECT_REPORT.md`.

The product layer can change, but the inherited FPGA pricing kernel must remain trustworthy.

## Kernel Gates

Run from the repository root.

```powershell
python -m py_compile scripts\validate_numerical.py scripts\diagnose_numerical.py scripts\accuracy_study.py scripts\financial_reference.py scripts\vivado_build_runner.py
.\scripts\run_xelab_smoke.ps1 -XvlogTimeoutSeconds 600 -XelabTimeoutSeconds 600 -NoCleanup
python scripts\validate_numerical.py --exercise-mode single --paths 64 --steps 12 --option-type 1 --build-cpu
python scripts\validate_numerical.py --exercise-mode multi --paths 64 --steps 12 --option-type 1 --build-cpu
python scripts\validate_numerical.py --exercise-mode multi --paths 256 --steps 12 --option-type 1
python scripts\validate_numerical.py --exercise-mode multi --paths 1024 --steps 12 --option-type 1 --xsim-timeout-seconds 2400
python scripts\validate_numerical.py --exercise-mode multi --paths 64 --steps 12 --option-type 0 --xsim-timeout-seconds 1200
python scripts\diagnose_numerical.py --paths 64 --steps 12 --option-type 1 --exercise-mode multi
git diff --check
```

Expected parity:

| Case | Expected result |
|------|-----------------|
| Single-date PUT N=64/M=12 | C++ and RTL match exactly, 0 Q16.16 LSB delta |
| Multi-date PUT N=64/M=12 | C++ and RTL match exactly, 0 Q16.16 LSB delta |
| Multi-date PUT N=256/M=12 | C++ and RTL match exactly, 0 Q16.16 LSB delta |
| Multi-date PUT N=1024/M=12 | C++ and RTL match exactly, 0 Q16.16 LSB delta |
| Multi-date CALL N=64/M=12 | C++ and RTL match exactly, 0 Q16.16 LSB delta |

Known measured values:

| Case | Price Q16.16 | Hex | Core cycles |
|------|--------------|-----|-------------|
| Single-date PUT N=64/M=12 | 263,688 | `0x00040608` | 75,603 |
| Multi-date PUT N=64/M=12 | 373,676 | `0x0005B3AC` | 461,245 |
| Multi-date PUT N=256/M=12 | 426,642 | `0x00068292` | 1,843,158 |
| Multi-date PUT N=1024/M=12 | 428,757 | `0x00068AD5` | 7,370,906 |
| Multi-date CALL N=64/M=12 | 482,546 | `0x00075CF2` | 37,726 |

## Stored-Path Multi-Lane Multi-Date Engine

The stored-path engine in `src/top/top_option_pricer_multi_stored.sv` replaces
the original regeneration-based multi-date controller. It generates every spot
once, stores paths in lane-banked BRAM, stores cashflows in lane-local banks,
replicates the path and feature pipelines, and schedules independent paths
step-major so inverse-CDF/GBM work can overlap safely.

Validated on the same 1,024-path, 12-step American PUT case. All lane counts
return the C++/legacy RTL oracle `428,757` (`0x00068AD5`) exactly:

| Lanes | Core cycles | Core time at 100 MHz | Speedup vs 7,370,906-cycle v1 |
|-------|------------:|----------------------:|---------------------------------:|
| 1 | 720,474 | 7.205 ms | 10.23x |
| 2 | 411,626 | 4.116 ms | 17.91x |
| 4 | 236,362 | 2.364 ms | 31.18x |
| 8 | 121,290 | 1.213 ms | 60.77x |

The optimized i9-13905H C++ means for the same 1,024x12 raw-price workload
are 1.285 ms hot-kernel, 1.336 ms with path allocation, and 1.860 ms with
direction-file loading. The physical four-lane A7 is therefore 0.54x to 0.79x
as fast as that CPU (the CPU is 1.27x to 1.84x faster). Do not use the older
4.286-ms measurement as the resume denominator. Full methodology is in
`.user/PERFORMANCE_MATRIX.md`.

The eight-lane row is a cycle-accurate scaling result, not a board-fit claim.
A7-100T synthesis used 91,092 LUTs (143.68%), so it cannot be placed on that
device. Four lanes is the maximum synthesized configuration that fits:

| Target/config | LUTs | Registers | DSP48E1 | RAMB36 | Status |
|---------------|-----:|----------:|--------:|-------:|--------|
| A7-100T, 4 lanes | 45,875 (72.36%) | 46,911 (37.00%) | 180 (75.00%) | 66 (48.89%) | Routed at 100 MHz, WNS +0.144 ns |
| A7-100T, 8 lanes | 91,092 (143.68%) | 89,440 (70.54%) | 240 (100%) | 64 (47.41%) | Does not fit LUT capacity |
| S7-50, 1 lane | 23,399 (71.78%) | 28,967 (44.43%) | 84 (70.00%) | 65 (86.67%) | Routed at 100 MHz, WNS +0.310 ns |
| S7-50, 2 lanes | 30,606 (93.88%) | 34,855 (53.46%) | 116 (96.67%) | 65 (86.67%) | Routed at 95.24 MHz (10.5 ns), WNS +0.083 ns; fails 100 MHz by -0.180 ns |

The S7-50 two-lane configuration is the densest fit evaluated (93.88% LUT,
96.67% DSP). It does not close at 100 MHz, so it is published at its honest
closing clock of 95.24 MHz (10.5 ns, WNS +0.083 ns), where the 1,024x12 compute
window is 4.322 ms, rather than claimed at 100 MHz. The one-lane S7-50 build is
the S7 configuration that meets 100 MHz with margin.

At four lanes, the 2.364 ms compute window corresponds to about 433,231
complete 12-step paths/s, or 5.199 million simulated path-steps/s. UART transfer
is excluded; timing is the RTL `core_cycles` interval.

The routed 10 ns A7-100T build meets all timing constraints with WNS
`+0.144 ns`, TNS `0`, and zero failing endpoints. The bitstream and reports are
under `vivado_build/arty_a7_100_multi_lanes4_10ns/`.

Exact regression command:

```powershell
.\scripts\run_tb_top_uart_safe.ps1 -MultiExercise -NumLanes 4 `
  -TestPlusargs "paths=1024,steps=12,S0=6553600,K=6553600,r=3277,sigma=13107,T=65536,opt=1,expected_price=428757" `
  -XsimTimeoutSeconds 1200 -NoCleanup
```

## Product Gates

For portfolio, scenario, and Greeks work, add focused tests as files are created.

Minimum expectations:

- CSV parsing rejects malformed contracts with clear row-level errors.
- `--target cpu` works without a board.
- `--target both` reports CPU/FPGA price deltas when hardware is available.
- Scenario reports preserve contract IDs and scenario names.
- Greek reports record bump sizes and base/bumped prices.
- Product scripts do not change the kernel parity contract unless explicitly versioned.

Likely first commands:

```powershell
python -m py_compile scripts\portfolio_price.py scripts\scenario_sweep.py
python scripts\portfolio_price.py --portfolio examples\portfolio.csv --output-dir .tmp\portfolio_smoke --target cpu
python scripts\scenario_sweep.py --portfolio examples\portfolio.csv --scenarios examples\scenarios.csv --output-dir .tmp\scenario_smoke --target cpu
git diff --check
```

## Vivado Gates

A7-100T multi-date 100 MHz:

```powershell
.\scripts\run_vivado_build_arty_a7.ps1 -MultiExercise -NumLanes 4 -ClockPeriodNs 10 -TimeoutSeconds 21600
```

Expected artifacts:

- `vivado_build/arty_a7_100_multi_lanes4_10ns/timing_post_route.rpt`
- `vivado_build/arty_a7_100_multi_lanes4_10ns/utilization.rpt`
- `vivado_build/arty_a7_100_multi_lanes4_10ns/arty_a7_qmc_multi.bit`

Expected timing:

- WNS `+0.144 ns`
- TNS `0`
- 0 failing endpoints

Expected resources:

- 45,875 LUTs
- 46,911 registers
- 180 DSP48E1
- 66 block-RAM tiles

S7-50 multi-date 100 MHz:

```powershell
.\scripts\run_vivado_build_arty_s7.ps1 -MultiExercise -NumLanes 1 -ClockPeriodNs 10 -TimeoutSeconds 21600
```

Expected artifacts:

- `vivado_build/arty_s7_50_multi_lanes1_10ns/timing_post_route.rpt`
- `vivado_build/arty_s7_50_multi_lanes1_10ns/utilization.rpt`
- `vivado_build/arty_s7_50_multi_lanes1_10ns/arty_s7_qmc_multi.bit`

Expected timing:

- WNS `+0.310 ns`
- TNS `0`
- 0 failing endpoints

Expected resources:

- 23,399 LUTs
- 28,967 registers
- 84 DSP48E1
- 65 block-RAM tiles

S7-50 multi-date 2 lanes at relaxed clock (does not close at 100 MHz):

```powershell
.\scripts\run_vivado_build_arty_s7.ps1 -MultiExercise -NumLanes 2 -ClockPeriodNs 10.5 -TimeoutSeconds 21600
```

Expected artifacts:

- `vivado_build/arty_s7_50_multi_lanes2_10p5ns/timing_post_route.rpt`
- `vivado_build/arty_s7_50_multi_lanes2_10p5ns/utilization.rpt`
- `vivado_build/arty_s7_50_multi_lanes2_10p5ns/arty_s7_qmc_multi.bit`

Expected timing (95.24 MHz / 10.5 ns):

- WNS `+0.083 ns`
- TNS `0`
- 0 failing endpoints

Expected resources:

- 30,606 LUTs
- 34,855 registers
- 116 DSP48E1
- 65 block-RAM tiles

At 95.24 MHz the 1,024x12 two-lane compute window is 411,626 cycles = 4.322 ms.

## Accuracy Gates

These gates measure financial quality, not C++/RTL parity.

```powershell
python scripts\accuracy_study.py --preset smoke --build-cpu --attribution
python scripts\accuracy_study.py --preset default --exercise-mode both --build-cpu --attribution --health-metrics --output-dir .tmp\accuracy_default_health
python scripts\accuracy_study.py --preset smoke --paths-list 1024,4096,8192 --steps-list 12,20 --moneyness-list 0.6,0.8,1.0,1.2,1.4 --sigma-list 0.05,0.2,0.4,0.6 --option-types put,call --exercise-mode both --build-cpu --attribution --health-metrics --output-dir .tmp\accuracy_stress_health
```

Outputs:

- `accuracy_results.csv`
- `accuracy_summary.md`
- `health/health_rows.csv`

Interpretation:

- Use `abs_bps_spot` for market-style error.
- Use `multi_fixed_point_bps_spot` to judge hardware arithmetic impact.
- Use health metrics to catch regression instability.
- For no-dividend CALLs, early exercise should be suppressed.

## Diagnosis Flow

Use diagnosis whenever parity breaks.

```powershell
python scripts\diagnose_numerical.py --paths 4 --steps 4 --option-type 1 --exercise-mode multi
python scripts\diagnose_numerical.py --paths 8 --steps 12 --option-type 1 --exercise-mode multi
python scripts\diagnose_numerical.py --paths 64 --steps 12 --option-type 1 --exercise-mode multi
```

The script compares raw C++ and RTL Q16.16 trace tags:

- `[INIT]`
- `[PATH]`
- `[ACC-IN]`
- `[ACC-SUM]`
- `[BETA]`
- `[LSM]`
- `[PV]`
- `[FINAL]`

The correct workflow is to fix the first divergent stage before looking at final price.

## Hardware UART Run

A7-100T:

```powershell
.\scripts\program_arty_a7.ps1 -Bit vivado_build\arty_a7_100_multi_10ns\arty_a7_qmc_multi.bit
python src\uart_host.py --mode benchmark --target both --param-file baseline\cpp_fixed\params_example.txt --port COM4 --fpga-fclk-hz 100000000 --build-cpu
```

S7-50 uses the S7 bitstream and the same host UART flow after programming through Vivado Hardware Manager or a board-specific programming script.

The host reports:

- FPGA price,
- C++ mirror price,
- Q16.16 delta,
- `core_cycles`,
- FPGA core seconds,
- UART round-trip seconds,
- CPU wall seconds,
- speedup.

## Acceptance Criteria For Future Changes

Future product work should keep this kernel stable:

- C++/RTL parity must remain within 1 Q16.16 LSB unless the algorithm contract intentionally changes.
- A7-100T and S7-50 100 MHz builds should continue to meet timing for RTL changes.
- No change should reintroduce `u_q16=0` into inverse-CDF.
- CALL early exercise should remain suppressed until a dividend-yield input exists.
- Regression health metrics should remain bounded before any RTL expansion.
- UART packet format should stay unchanged unless the product phase deliberately versions it.
