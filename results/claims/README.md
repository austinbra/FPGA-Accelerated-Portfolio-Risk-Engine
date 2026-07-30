# Claim Evidence

This directory contains compact, tracked evidence for published project
performance claims. Generated JSON and CSV retain machine-readable provenance;
the Markdown report is the human-readable summary.

Run a complete collection with:

```powershell
python scripts/reproduce_claims.py --cpp-mode run --xsim-mode run --benchmark-mode run --vivado-mode run --require-complete
```

That command rebuilds the C++17 oracle with `-O3 -DNDEBUG`, runs both canonical
four-lane xsim workloads, runs each named Google Benchmark boundary for 15
repetitions in Release mode, and runs the existing four-lane Artix-7 route flow
at a 10 ns target before parsing its timing/utilization reports. Vivado build
trees and verbose logs remain under ignored `.tmp/` and `vivado_build/`; only
compact outputs are tracked here.

For a fast partial report, skip expensive sources:

```powershell
python scripts/reproduce_claims.py --xsim-mode skip --benchmark-mode skip --vivado-mode skip
```

Archived evidence can be parsed without rerunning tools by selecting `parse`
and passing both case logs (suffixes `-4` and `-12`) plus a benchmark JSON file.
Parsed artifacts are not claim-ready unless `--compiler-provenance`,
`--cpu-provenance`, `--parsed-git-commit`, and
`--parsed-source-fingerprint` explicitly bind them to the toolchain, benchmark
host, and current source snapshot. A first partial collection prints the
current commit and combined source SHA-256 for this purpose.

Claim-ready collection additionally requires matching Routed timing and
utilization metadata, content hashes for both reports, reports newer than every
RTL/build input, a routed `sys_clk` clock summary, Release benchmark provenance,
all three named CPU timing boundaries, and at least 15 repetitions. FPGA core
latency is derived from the routed clock period; `--clock-hz` is only a
configured expectation and must match the routed period.

The report never states a generic CPU/FPGA speed claim. Every ratio names its
CPU timing boundary and divides that value by FPGA **core** latency. FPGA core
latency excludes UART, USB, Python, and host scheduling.
