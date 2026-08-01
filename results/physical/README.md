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
- Bit SHA-256: `575EFA8E2EB164471E861DF37887BCB30D877609D557B34B5EB39BAA3731A874`
- Routed timing: WNS +0.013 ns, TNS 0, WHS +0.013 ns, THS 0

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
  --fpga-repetitions 100 `
  --build-cpu
```

## Measured Result

| Field | Result |
|---|---:|
| Repetitions | 100 |
| CPU raw Q16.16 price | 391,343 |
| FPGA raw Q16.16 price | 391,343 |
| Raw-price parity | exact |
| FPGA core cycles | 159,398 in every run |
| FPGA core interval | 1.673679 ms |
| UART transport p50 | 15.974 ms |
| UART transport p95 | 16.147 ms |
| UART transport p99 | 16.240 ms |

The UART host sends all eight words as one 32-byte zero-gap write. The earlier
apparent need for a 2 ms inter-word guard was caused by `_read_exact()` assigning
pyserial's `timeout` after `write()`. On Windows that reconfigured the COM handle
while the FTDI could still be transmitting. The fixed host configures the
bounded timeout once when opening the port and does not mutate it in the read
loop. The same cable also passed 1,000/1,000 zero-gap requests with the minimal
95.238 MHz UART diagnostic.

This supports a measured-on-physical-Spartan-7 claim for the named bitstream,
workload, and core boundary. It does not establish A7 hardware performance,
board power, a generic CPU/FPGA speedup, or a universal maximum clock.
