# Reproducible Claim Evidence

This directory contains the compact tracked evidence for the corrected pricing
kernel:

- `claim_evidence.json`: complete machine-readable provenance, checks, and data;
- `claim_evidence.csv`: flattened workload and ratio rows;
- `claim_evidence.md`: human-readable generated summary.

Raw xsim logs, Google Benchmark JSON, CMake trees, Vivado projects, checkpoints,
and bitstreams remain under ignored `.tmp/` and `vivado_build/` directories.

## Complete Collection

From the repository root:

```powershell
python scripts\reproduce_claims.py `
  --cpp-mode run `
  --xsim-mode run `
  --benchmark-mode run `
  --vivado-mode run `
  --require-complete
```

The collector:

1. fingerprints implementation RTL, simulation inputs, and C++ sources;
2. builds/runs the C++ oracle for 1,024 x 4 and 1,024 x 12;
3. finds and fingerprints generated `div_gen` behavioral VHDL;
4. runs both full four-lane RTL workloads with that vendor model;
5. builds Release Google Benchmark and collects all three named CPU boundaries
   over at least 15 repetitions;
6. routes the corrected four-lane A7 at 9.5 ns;
7. parses routed clock, timing, utilization, and report hashes;
8. calculates only boundary-explicit CPU/FPGA ratios;
9. writes JSON, CSV, and Markdown outputs;
10. returns nonzero if any claim-ready requirement fails.

The complete run is intentionally expensive because xsim and Vivado are part of
the evidence, not decorative build steps. It is a release action, not the normal
edit/test loop.

For day-to-day work, run focused unit/full-core simulation first and reuse the
canonical routed reports with `--vivado-mode parse`. Re-run implementation only
after implementation RTL, constraints, wrapper parameters, or tool strategy
changes. For timing exploration, keep one passing checkpoint and test only the
adjacent faster legal period; do not sweep every period from scratch.

## Claim-Ready Requirements

A report can say `CLAIM-READY` only when:

- C++ and RTL raw prices match for both canonical workloads;
- RTL cycles match corrected expectations (91,302 and 293,790);
- xsim used generated behavioral divider VHDL, not only the convenience stub;
- source contents do not change during collection;
- parsed artifacts are bound to the current source fingerprint;
- Google Benchmark is Release, includes hot/pricing/end-to-end rows, and has at
  least 15 repetitions;
- CPU model and compiler identities are recorded;
- routed timing/utilization reports are newer than implementation inputs;
- report hashes, Vivado version, device, top, lane count, and clock source are
  recorded;
- routed core period is 9.5 ns and agrees with the configured expectation;
- WNS and WHS are nonnegative, TNS and THS are zero, and setup/hold
  failing endpoints are zero;
- all required parity, provenance, and accuracy checks pass.

The current report is claim-ready for C++/RTL, benchmark, and post-route
statements. It is not a physical-board report.

## Partial Runs

A quick development report can skip expensive sources:

```powershell
python scripts\reproduce_claims.py `
  --xsim-mode skip `
  --benchmark-mode skip `
  --vivado-mode skip
```

It will be labeled partial. Do not publish it as a replacement for the tracked
complete report.

`parse` mode can reuse archived logs/reports, but claim-ready parsing requires
explicit compiler, CPU, git commit, and source-fingerprint provenance. That
prevents a current source tree from silently claiming old binaries or reports.
Use `--help` for the exact artifact arguments.

## Interpreting Ratios

Every displayed ratio is:

```text
CPU mean real time for the named boundary / FPGA core time
```

FPGA core time is corrected RTL cycles divided by the routed A7 core frequency.
It excludes UART, USB, Python, and host scheduling. The report therefore does
not state a general CPU/FPGA speedup.

A ratio above 1 means the FPGA core interval is shorter than that named CPU
boundary. A ratio below 1 means that CPU boundary is shorter.

## Corrected-Evidence Boundary

Evidence created before the divider correction must not be mixed into this
directory. In particular, old 72,394/236,362 cycle rows, pre-fix routes,
pre-fix bitstreams, and the S7 zero-price physical run are excluded.

The corrected S7 bitstream now returns the expected raw price and stable cycle
count on physical hardware. Its 30-run parity and transport record is kept
separate from this generated A7 post-route report in
[`results/physical/README.md`](../physical/README.md).
