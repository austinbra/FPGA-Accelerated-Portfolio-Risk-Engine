# Physical Arty S7-50 Evidence

Status: **PHYSICAL S7 PARITY AND TRANSPORT PASS**

This report is intentionally separate from `results/claims`, whose generated
artifact describes A7 post-route simulation and CPU benchmark evidence.

## Configuration

- Measurement date: 2026-08-01
- JTAG-detected part: `xc7s50`
- Build: `arty_s7_50_multi_lanes2_10p5ns_rowopt`
- Mode/lanes: multi-exercise / 2
- Generated core: 10.500 ns / 95,238,095 Hz
- Bit SHA-256: `729F8D9099A1A84B81C4D784FF7EF18343B72C364C897557F537692A173C5178`
- Routed timing: WNS +0.165 ns, TNS 0, WHS +0.011 ns, THS 0

## Command

```powershell
.\scripts\program_arty_s7.ps1 -TimeoutSeconds 600
python src\uart_host.py `
  --mode benchmark `
  --target both `
  --param-file baseline\cpp_fixed\params_latency_1024x4.txt `
  --exercise-mode multi `
  --num-lanes 2 `
  --port COM4 `
  --fpga-fclk-hz 95238095 `
  --fpga-repetitions 30 `
  --build-cpu
```

## Measured Result

| Field | Result |
|---|---:|
| Repetitions | 30 |
| CPU raw Q16.16 price | 391,343 |
| FPGA raw Q16.16 price | 391,343 |
| Raw-price parity | exact |
| FPGA core cycles | 159,398 in every run |
| FPGA core interval | 1.673679 ms |
| UART transport p50 | 31.981 ms |
| UART transport p95 | 32.764 ms |
| UART transport p99 | 33.207 ms |

The UART host sends each 32-bit request word as a separate write with a 2 ms
guard. Unpaced FTDI bursts caused framing errors on this board/cable pair. The
guard is included in transport time and excluded from the FPGA core interval.
The RTL receiver uses a two-stage asynchronous synchronizer and rejects invalid
stop bits.

This supports a measured-on-physical-Spartan-7 claim for the named bitstream,
workload, and core boundary. It does not establish A7 hardware performance,
board power, a generic CPU/FPGA speedup, or a universal maximum clock.
