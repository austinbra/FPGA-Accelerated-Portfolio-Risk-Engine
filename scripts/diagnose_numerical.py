#!/usr/bin/env python3
"""
Stage-by-stage numerical diagnosis for the C++ FPGA-style baseline vs RTL sim.

The script runs both implementations with diagnostic tracing enabled, aligns the
[NUM][...] records, and reports the first raw fixed-point mismatch.
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


NUM_RE = re.compile(r"\[NUM\]\[(?P<stage>[A-Z0-9-]+)\]")
TOKEN_RE = re.compile(r"(?P<key>[A-Za-z0-9_]+)=(?P<value>\"[^\"]*\"|\S+)")


@dataclass(frozen=True)
class TraceKey:
    stage: str
    key: str
    path: int | None = None
    step: int | None = None
    pass_name: str = ""


@dataclass
class TraceRecord:
    source: str
    line_no: int
    stage: str
    key: str
    raw: int
    signed: int
    width: int
    path: int | None
    step: int | None
    pass_name: str
    line: str

    @property
    def hex_value(self) -> str:
        return f"0x{self.raw & ((1 << self.width) - 1):0{self.width // 4}X}"

    @property
    def q16_float(self) -> float:
        return self.signed / float(1 << 16)


def float_to_q16_16(x: float) -> int:
    return int(round(x * (1 << 16)))


def signed_from_raw(raw: int, width: int) -> int:
    sign_bit = 1 << (width - 1)
    full = 1 << width
    return raw - full if raw & sign_bit else raw


def parse_trace(text: str, source: str) -> list[TraceRecord]:
    records: list[TraceRecord] = []
    for line_no, line in enumerate(text.splitlines(), 1):
        m = NUM_RE.search(line)
        if not m:
            continue

        tokens = {tm.group("key"): tm.group("value").strip('"') for tm in TOKEN_RE.finditer(line)}
        key = tokens.get("key")
        if not key:
            continue

        if "value64" in tokens:
            width = 64
            raw = int(tokens["value64"], 16)
        elif "value" in tokens:
            width = 32
            raw = int(tokens["value"], 16)
        else:
            continue

        signed = int(tokens["signed"]) if "signed" in tokens else signed_from_raw(raw, width)
        records.append(
            TraceRecord(
                source=source,
                line_no=line_no,
                stage=m.group("stage"),
                key=key,
                raw=raw,
                signed=signed,
                width=width,
                path=int(tokens["path"]) if "path" in tokens else None,
                step=int(tokens["step"]) if "step" in tokens else None,
                pass_name=tokens.get("pass", ""),
                line=line,
            )
        )
    return records


def normalize_key(record: TraceRecord, source: str) -> TraceKey | None:
    pass_name = record.pass_name

    # CPU simulates one path set. RTL regenerates the path set in train and
    # decide passes. Multi-date RTL also has an initial terminal pass, which is
    # the only regenerated pass that reaches all M steps. Keep the first
    # matching pass in trace order.
    if record.stage == "PATH":
        if source == "rtl" and pass_name not in ("", "terminal", "train"):
            return None
        pass_name = ""
    elif pass_name in ("multi", "terminal", "train", "decide", "final"):
        # Multi-date C++ tags the financial induction records as pass=multi.
        # RTL uses more granular pass labels because it regenerates paths.
        # Stage/path/step/key identify the comparable financial record.
        pass_name = ""

    return TraceKey(
        stage=record.stage,
        key=record.key,
        path=record.path,
        step=record.step,
        pass_name=pass_name,
    )


def build_index(records: list[TraceRecord], source: str) -> dict[TraceKey, TraceRecord]:
    out: dict[TraceKey, TraceRecord] = {}
    for rec in records:
        key = normalize_key(rec, source)
        if key is not None and key not in out:
            out[key] = rec
    return out


def run_cmd(cmd: list[str], cwd: Path, timeout: int, env: dict[str, str] | None = None) -> str:
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=env)
    out = proc.stdout + proc.stderr
    if proc.returncode != 0:
        raise RuntimeError(
            f"Command failed with exit code {proc.returncode}: {' '.join(cmd)}\n"
            f"--- output tail ---\n{out[-4000:]}"
        )
    return out


def find_cpu_exe(baseline_dir: Path) -> Path:
    for name in ("fixed_baseline.exe", "fixed_baseline"):
        exe = baseline_dir / name
        if exe.exists():
            return exe
    raise FileNotFoundError("fixed_baseline executable was not found")


def build_cpu(baseline_dir: Path) -> None:
    repo_tmp = baseline_dir.parents[1] / ".tmp"
    repo_tmp.mkdir(exist_ok=True)
    env = os.environ.copy()
    env["TEMP"] = str(repo_tmp)
    env["TMP"] = str(repo_tmp)
    env["TMPDIR"] = str(repo_tmp)
    cmd = [
        "g++",
        "-std=c++17",
        "main.cpp",
        "pricing.cpp",
        "linalg.cpp",
        "rtl_math.cpp",
        "sobol_wrapper.cpp",
        "utils.cpp",
        "-o",
        "fixed_baseline",
    ]
    run_cmd(cmd, baseline_dir, timeout=120, env=env)


def run_cpu_trace(args: argparse.Namespace, baseline_dir: Path) -> str:
    if args.build_cpu:
        build_cpu(baseline_dir)
    try:
        exe = find_cpu_exe(baseline_dir)
    except FileNotFoundError:
        build_cpu(baseline_dir)
        exe = find_cpu_exe(baseline_dir)

    cmd = [
        str(exe),
        "--paths",
        str(args.paths),
        "--steps",
        str(args.steps),
        "--S0",
        str(args.S0),
        "--K",
        str(args.K),
        "--r",
        str(args.r),
        "--sigma",
        str(args.sigma),
        "--T",
        str(args.T),
        "--option-type",
        str(args.option_type & 1),
        "--fpga-style",
        "--exercise-mode",
        args.exercise_mode,
        "--trace-numerical",
        "--direction-file",
        str(baseline_dir.parents[1] / "src" / "gen" / "direction.mem"),
        "--lut-dir",
        str(baseline_dir.parents[1] / "src" / "gen"),
    ]
    return run_cmd(cmd, baseline_dir, timeout=120)


def powershell_exe() -> str:
    return shutil.which("powershell") or shutil.which("pwsh") or "powershell"


def run_rtl_trace(args: argparse.Namespace, repo_root: Path) -> str:
    script = repo_root / "scripts" / "run_tb_top_uart_safe.ps1"
    plusargs = [
        f"paths={args.paths}",
        f"steps={args.steps}",
        f"S0={float_to_q16_16(args.S0)}",
        f"K={float_to_q16_16(args.K)}",
        f"r={float_to_q16_16(args.r)}",
        f"sigma={float_to_q16_16(args.sigma)}",
        f"T={float_to_q16_16(args.T)}",
        f"opt={args.option_type & 1}",
    ]
    cmd = [
        powershell_exe(),
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(script),
        "-MultiExercise" if args.exercise_mode == "multi" else "-ComputeMode",
        "-NoCleanup",
        "-DebugNum",
        "-XvlogTimeoutSeconds",
        str(args.xvlog_timeout_seconds),
        "-XelabTimeoutSeconds",
        str(args.xelab_timeout_seconds),
        "-XsimTimeoutSeconds",
        str(args.xsim_timeout_seconds),
        "-TestPlusargs",
        ",".join(plusargs),
    ]
    return run_cmd(cmd, repo_root, timeout=args.xvlog_timeout_seconds + args.xelab_timeout_seconds + args.xsim_timeout_seconds + 120)


def describe_key(key: TraceKey) -> str:
    parts = [f"stage={key.stage}", f"key={key.key}"]
    if key.pass_name:
        parts.append(f"pass={key.pass_name}")
    if key.path is not None:
        parts.append(f"path={key.path}")
    if key.step is not None:
        parts.append(f"step={key.step}")
    return " ".join(parts)


def print_record(prefix: str, rec: TraceRecord) -> None:
    print(f"  {prefix}: {rec.hex_value} signed={rec.signed} q16={rec.q16_float:.10f} line={rec.line_no}")


def report_mismatch(key: TraceKey, cpu: TraceRecord, rtl: TraceRecord) -> None:
    signed_delta = rtl.signed - cpu.signed
    float_delta = rtl.q16_float - cpu.q16_float
    rel = abs(float_delta) / abs(cpu.q16_float) if cpu.q16_float != 0 else float("inf")
    print("FIRST MISMATCH")
    print(f"  {describe_key(key)}")
    print_record("C++", cpu)
    print_record("RTL", rtl)
    print(f"  raw_lsb_delta={signed_delta}")
    print(f"  float_delta={float_delta:.10f}")
    print(f"  relative_delta={rel:.10f} ({rel * 100:.6f}%)")


def report_missing(key: TraceKey, cpu: TraceRecord, side: str) -> None:
    print("FIRST MISMATCH")
    print(f"  {describe_key(key)}")
    print_record("C++", cpu)
    print(f"  Missing {side} trace record for this key")


def compare_traces(cpu_records: list[TraceRecord], rtl_records: list[TraceRecord], tolerance_lsb: int) -> bool:
    rtl_index = build_index(rtl_records, "rtl")
    seen: set[TraceKey] = set()

    for cpu in cpu_records:
        key = normalize_key(cpu, "cpu")
        if key is None or key in seen:
            continue
        seen.add(key)

        rtl = rtl_index.get(key)
        if rtl is None:
            report_missing(key, cpu, "RTL")
            return False

        if cpu.width != rtl.width or abs(cpu.signed - rtl.signed) > tolerance_lsb:
            report_mismatch(key, cpu, rtl)
            return False

    print("NO TRACE MISMATCH FOUND")
    print(f"  Compared {len(seen)} normalized C++ records against RTL.")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description="Diagnose C++ vs RTL numerical divergence")
    parser.add_argument("--paths", type=int, default=4)
    parser.add_argument("--steps", type=int, default=4)
    parser.add_argument("--S0", type=float, default=100.0)
    parser.add_argument("--K", type=float, default=100.0)
    parser.add_argument("--r", type=float, default=0.05)
    parser.add_argument("--sigma", type=float, default=0.2)
    parser.add_argument("--T", type=float, default=1.0)
    parser.add_argument("--option-type", type=int, default=1, help="0=CALL, 1=PUT")
    parser.add_argument("--exercise-mode", choices=("single", "multi"), default="single")
    parser.add_argument("--build-cpu", action="store_true")
    parser.add_argument("--tolerance-lsb", type=int, default=0)
    parser.add_argument("--xvlog-timeout-seconds", type=int, default=1800)
    parser.add_argument("--xelab-timeout-seconds", type=int, default=600)
    parser.add_argument("--xsim-timeout-seconds", type=int, default=1200)
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[1]
    baseline_dir = repo_root / "baseline" / "cpp_fixed"

    print("Numerical diagnosis: C++ trace vs RTL TOP_NUM_DEBUG trace")
    print(
        f"  paths={args.paths} steps={args.steps} S0={args.S0} K={args.K} "
        f"r={args.r} sigma={args.sigma} T={args.T} option_type={args.option_type & 1} "
        f"exercise_mode={args.exercise_mode}"
    )

    print("[1/2] Running C++ trace...")
    cpu_out = run_cpu_trace(args, baseline_dir)
    cpu_records = parse_trace(cpu_out, "cpu")
    print(f"  Parsed {len(cpu_records)} C++ trace records")
    if not cpu_records:
        print("ERROR: C++ trace emitted no [NUM] records")
        return 1

    print("[2/2] Running RTL trace...")
    rtl_out = run_rtl_trace(args, repo_root)
    rtl_records = parse_trace(rtl_out, "rtl")
    print(f"  Parsed {len(rtl_records)} RTL trace records")
    if not rtl_records:
        print("ERROR: RTL trace emitted no [NUM] records")
        print("--- RTL output tail ---")
        print(rtl_out[-4000:])
        return 1

    compare_traces(cpu_records, rtl_records, args.tolerance_lsb)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.TimeoutExpired as exc:
        print(f"ERROR: command timed out after {exc.timeout} seconds")
        raise SystemExit(1)
    except Exception as exc:
        print(f"ERROR: {exc}")
        raise SystemExit(1)
