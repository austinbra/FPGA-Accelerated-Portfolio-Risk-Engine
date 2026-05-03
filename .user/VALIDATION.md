# Validation

This file is the internal verification playbook. The public summary lives in root `README.md` and `PROJECT_REPORT.md`.

## Final Thesis Gates

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

## Vivado Gates

A7-100T multi-date 100 MHz:

```powershell
.\scripts\run_vivado_build_arty_a7.ps1 -MultiExercise -ClockPeriodNs 10 -TimeoutSeconds 21600
```

Expected artifacts:

- `vivado_build/arty_a7_100_multi_10ns/timing_post_route.rpt`
- `vivado_build/arty_a7_100_multi_10ns/utilization.rpt`
- `vivado_build/arty_a7_100_multi_10ns/arty_a7_qmc_multi.bit`

Expected timing:

- WNS `+0.153 ns`
- TNS `0`
- 0 failing endpoints

Expected resources:

- 23,167 LUTs
- 27,873 registers
- 80 DSP48E1
- 16 RAMB36

S7-50 multi-date 100 MHz:

```powershell
.\scripts\run_vivado_build_arty_s7.ps1 -MultiExercise -ClockPeriodNs 10 -TimeoutSeconds 21600
```

Expected artifacts:

- `vivado_build/arty_s7_50_multi_10ns/timing_post_route.rpt`
- `vivado_build/arty_s7_50_multi_10ns/utilization.rpt`
- `vivado_build/arty_s7_50_multi_10ns/arty_s7_qmc_multi.bit`

Expected timing:

- WNS `+0.113 ns`
- TNS `0`
- 0 failing endpoints

Expected resources:

- 23,154 LUTs
- 27,873 registers
- 80 DSP48E1
- 16 RAMB36

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

Future fork work should keep this kernel stable:

- C++/RTL parity must remain within 1 Q16.16 LSB unless the algorithm contract intentionally changes.
- A7-100T and S7-50 100 MHz builds should continue to meet timing.
- No change should reintroduce `u_q16=0` into inverse-CDF.
- CALL early exercise should remain suppressed until a dividend-yield input exists.
- Regression health metrics should remain bounded before any RTL expansion.
- UART packet format should stay unchanged unless the product phase deliberately versions it.
