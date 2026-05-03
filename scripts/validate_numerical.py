#!/usr/bin/env python3
"""
Numerical validation gate: compare xsim RTL price against the C++ FPGA-style
mirror with identical UART parameters.

Default behavior preserves the original single-date PUT smoke case:
N=64, M=12, S0=K=100, r=0.05, sigma=0.2, T=1, PUT.
"""

from __future__ import annotations

import argparse
import csv
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


TIMEOUT_PRICE_RAW = 0xDEAD0001


@dataclass
class CpuResult:
    price_double: float
    price_q16: int
    stdout_tail: str


@dataclass
class RtlResult:
    price_float: float
    price_raw: int
    price_q16: int
    core_cycles: int | None
    marker_raw: int | None
    stdout_tail: str


def q16_16_to_float(raw: int) -> float:
    signed = signed_q16_from_raw(raw)
    return signed / float(1 << 16)


def signed_q16_from_raw(raw: int) -> int:
    raw &= 0xFFFF_FFFF
    return raw - 0x1_0000_0000 if raw >= 0x8000_0000 else raw


def float_to_q16_16(value: float) -> int:
    return int(round(value * (1 << 16)))


def option_name(option_type: int) -> str:
    return "PUT" if (option_type & 1) else "CALL"


def find_cpu_exe(baseline_dir: Path) -> Path:
    for name in ("fixed_baseline.exe", "fixed_baseline"):
        exe = baseline_dir / name
        if exe.exists():
            return exe
    raise FileNotFoundError(
        f"C++ baseline not built under {baseline_dir}. "
        "Use --build-cpu or build baseline/cpp_fixed/fixed_baseline first."
    )


def build_cpu_baseline(repo_root: Path, baseline_dir: Path) -> None:
    tmp_dir = repo_root / ".tmp"
    tmp_dir.mkdir(exist_ok=True)
    env = os.environ.copy()
    env["TEMP"] = str(tmp_dir)
    env["TMP"] = str(tmp_dir)
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
    subprocess.run(
        cmd,
        cwd=baseline_dir,
        env=env,
        capture_output=True,
        text=True,
        check=True,
        timeout=180,
    )


def run_cpu_baseline(
    repo_root: Path,
    baseline_dir: Path,
    paths: int,
    steps: int,
    s0: float,
    strike: float,
    rate: float,
    sigma: float,
    maturity: float,
    option_type_value: int,
    exercise_mode: str,
) -> CpuResult:
    exe = find_cpu_exe(baseline_dir)
    cmd = [
        str(exe),
        "--paths",
        str(paths),
        "--steps",
        str(steps),
        "--S0",
        str(s0),
        "--K",
        str(strike),
        "--r",
        str(rate),
        "--sigma",
        str(sigma),
        "--T",
        str(maturity),
        "--option-type",
        str(option_type_value & 1),
        "--fpga-style",
        "--exercise-mode",
        exercise_mode,
        "--direction-file",
        str(repo_root / "src" / "gen" / "direction.mem"),
        "--lut-dir",
        str(repo_root / "src" / "gen"),
    ]
    proc = subprocess.run(
        cmd,
        cwd=baseline_dir,
        capture_output=True,
        text=True,
        check=True,
        timeout=180,
    )
    out = proc.stdout + proc.stderr
    price_d_match = re.search(r"Estimated Option Price \(double\):\s*([0-9eE+\-.]+)", out)
    price_q_match = re.search(r"Estimated Option Price \(Q16\.16\):\s*(-?[0-9]+)", out)
    if not price_d_match or not price_q_match:
        raise RuntimeError(f"Could not parse C++ baseline output.\n---\n{out[-2000:]}")
    return CpuResult(
        price_double=float(price_d_match.group(1)),
        price_q16=int(price_q_match.group(1)),
        stdout_tail=out[-2000:],
    )


def run_fpga_sim(
    repo_root: Path,
    paths: int,
    steps: int,
    s0: float,
    strike: float,
    rate: float,
    sigma: float,
    maturity: float,
    option_type_value: int,
    exercise_mode: str,
    xvlog_timeout_seconds: int,
    xelab_timeout_seconds: int,
    xsim_timeout_seconds: int,
) -> RtlResult:
    script = repo_root / "scripts" / "run_tb_top_uart_safe.ps1"
    if not script.exists():
        raise FileNotFoundError(f"run_tb_top_uart_safe.ps1 not found at {script}")

    plusargs = [
        f"paths={paths}",
        f"steps={steps}",
        f"S0={float_to_q16_16(s0)}",
        f"K={float_to_q16_16(strike)}",
        f"r={float_to_q16_16(rate)}",
        f"sigma={float_to_q16_16(sigma)}",
        f"T={float_to_q16_16(maturity)}",
        f"opt={option_type_value & 1}",
    ]

    mode_switch = "-MultiExercise" if exercise_mode == "multi" else "-ComputeMode"
    cmd = [
        "powershell",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(script),
        mode_switch,
        "-NoCleanup",
        "-XvlogTimeoutSeconds",
        str(xvlog_timeout_seconds),
        "-XelabTimeoutSeconds",
        str(xelab_timeout_seconds),
        "-XsimTimeoutSeconds",
        str(xsim_timeout_seconds),
        "-TestPlusargs",
        ",".join(plusargs),
    ]
    outer_timeout = xvlog_timeout_seconds + xelab_timeout_seconds + xsim_timeout_seconds + 300
    proc = subprocess.run(
        cmd,
        cwd=repo_root,
        capture_output=True,
        text=True,
        timeout=outer_timeout,
    )
    out = proc.stdout + proc.stderr
    if proc.returncode != 0:
        raise RuntimeError(f"RTL simulation failed with exit code {proc.returncode}.\n---\n{out[-4000:]}")

    marker_raw = None
    core_cycles = None
    price_raw = None

    virtual_match = re.search(
        r"\[VIRTUAL_A7\]\s+paths=\d+\s+steps=\d+\s+core_cycles=(\d+)\s+price_raw=0x([0-9a-fA-F]+)\s+marker=0x([0-9a-fA-F]+)",
        out,
    )
    if virtual_match:
        core_cycles = int(virtual_match.group(1))
        price_raw = int(virtual_match.group(2), 16)
        marker_raw = int(virtual_match.group(3), 16)
    else:
        price_match = re.search(r"Batch 0 price (?:= |out of plausible range: )0x([0-9a-fA-F]+)", out)
        if price_match:
            price_raw = int(price_match.group(1), 16)

    if price_raw is None:
        raise RuntimeError(f"Could not parse RTL price from output.\n---\n{out[-4000:]}")

    return RtlResult(
        price_float=q16_16_to_float(price_raw),
        price_raw=price_raw,
        price_q16=signed_q16_from_raw(price_raw),
        core_cycles=core_cycles,
        marker_raw=marker_raw,
        stdout_tail=out[-4000:],
    )


def append_csv(path: Path, row: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    exists = path.exists()
    fields = list(row.keys())
    with path.open("a", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fields)
        if not exists:
            writer.writeheader()
        writer.writerow(row)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Compare RTL xsim price against the C++ FPGA-style mirror.")
    parser.add_argument("--paths", type=int, default=64)
    parser.add_argument("--steps", type=int, default=12)
    parser.add_argument("--S0", type=float, default=100.0)
    parser.add_argument("--K", type=float, default=100.0)
    parser.add_argument("--r", type=float, default=0.05)
    parser.add_argument("--sigma", type=float, default=0.2)
    parser.add_argument("--T", type=float, default=1.0)
    parser.add_argument("--option-type", type=int, choices=(0, 1), default=1, help="0=CALL, 1=PUT")
    parser.add_argument("--exercise-mode", choices=("single", "multi"), default="single")
    parser.add_argument("--build-cpu", action="store_true")
    parser.add_argument("--xvlog-timeout-seconds", type=int, default=1800)
    parser.add_argument("--xelab-timeout-seconds", type=int, default=600)
    parser.add_argument("--xsim-timeout-seconds", type=int, default=600)
    parser.add_argument("--tolerance-lsb", type=int, default=1)
    parser.add_argument("--fclk-hz", type=float, default=83_333_333.33333333)
    parser.add_argument("--output-csv", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = Path(__file__).resolve().parents[1]
    baseline_dir = repo_root / "baseline" / "cpp_fixed"

    print("Numerical validation: RTL xsim vs C++ FPGA-style mirror")
    print(
        f"  exercise_mode={args.exercise_mode} option={option_name(args.option_type)} "
        f"paths={args.paths} steps={args.steps}"
    )
    print(f"  S0={args.S0} K={args.K} r={args.r} sigma={args.sigma} T={args.T}")
    print()

    if args.build_cpu:
        print("[1/3] Building C++ baseline...")
        try:
            build_cpu_baseline(repo_root, baseline_dir)
        except Exception as exc:
            print(f"ERROR: C++ build failed: {exc}")
            return 1
    else:
        print("[1/3] C++ build skipped (use --build-cpu to rebuild).")

    print("[2/3] Running C++ FPGA-style mirror...")
    try:
        cpu = run_cpu_baseline(
            repo_root,
            baseline_dir,
            args.paths,
            args.steps,
            args.S0,
            args.K,
            args.r,
            args.sigma,
            args.T,
            args.option_type,
            args.exercise_mode,
        )
    except Exception as exc:
        print(f"ERROR: C++ baseline failed: {exc}")
        return 1
    print(f"  CPU price (double): {cpu.price_double:.8f}")
    print(f"  CPU price (Q16.16): {cpu.price_q16}")
    print()

    print("[3/3] Running RTL simulation...")
    try:
        rtl = run_fpga_sim(
            repo_root,
            args.paths,
            args.steps,
            args.S0,
            args.K,
            args.r,
            args.sigma,
            args.T,
            args.option_type,
            args.exercise_mode,
            args.xvlog_timeout_seconds,
            args.xelab_timeout_seconds,
            args.xsim_timeout_seconds,
        )
    except subprocess.TimeoutExpired:
        print("ERROR: RTL simulation process timed out")
        return 1
    except Exception as exc:
        print(f"ERROR: RTL simulation failed: {exc}")
        return 1

    print(f"  RTL price raw: 0x{rtl.price_raw:08X}")
    print(f"  RTL price (float): {rtl.price_float:.8f}")
    print(f"  RTL price (Q16.16): {rtl.price_q16}")
    if rtl.core_cycles is not None:
        seconds_at_fclk = rtl.core_cycles / args.fclk_hz if args.fclk_hz > 0 else float("nan")
        print(f"  RTL core cycles: {rtl.core_cycles}")
        print(f"  Estimated core time @ {args.fclk_hz:.3f} Hz: {seconds_at_fclk:.6f} s")
    if rtl.marker_raw is not None:
        print(f"  RTL marker: 0x{rtl.marker_raw:08X}")
    print()

    lsb_delta = rtl.price_q16 - cpu.price_q16
    float_delta = rtl.price_float - cpu.price_double
    rel_err = abs(float_delta) / abs(cpu.price_double) if cpu.price_double != 0 else float("inf")
    timeout_seen = rtl.price_raw == TIMEOUT_PRICE_RAW

    print(f"Float delta: {float_delta:.8f}")
    print(f"Relative error: {rel_err:.8f} ({rel_err * 100:.6f}%)")
    print(f"Q16.16 LSB delta: {lsb_delta}")

    if args.output_csv:
        append_csv(
            args.output_csv,
            {
                "exercise_mode": args.exercise_mode,
                "option_type": option_name(args.option_type),
                "paths": args.paths,
                "steps": args.steps,
                "S0": args.S0,
                "K": args.K,
                "r": args.r,
                "sigma": args.sigma,
                "T": args.T,
                "cpu_price_q16": cpu.price_q16,
                "cpu_price_double": f"{cpu.price_double:.10f}",
                "rtl_price_raw": f"0x{rtl.price_raw:08X}",
                "rtl_price_q16": rtl.price_q16,
                "rtl_price_float": f"{rtl.price_float:.10f}",
                "lsb_delta": lsb_delta,
                "float_delta": f"{float_delta:.10f}",
                "relative_error": f"{rel_err:.10f}",
                "core_cycles": rtl.core_cycles if rtl.core_cycles is not None else "",
                "fclk_hz": f"{args.fclk_hz:.6f}",
                "estimated_core_seconds": f"{(rtl.core_cycles / args.fclk_hz):.10f}"
                if rtl.core_cycles is not None and args.fclk_hz > 0
                else "",
                "marker_raw": f"0x{rtl.marker_raw:08X}" if rtl.marker_raw is not None else "",
            },
        )
        print(f"Wrote CSV row: {args.output_csv}")

    if timeout_seen:
        print("FAIL: RTL returned timeout marker 0xDEAD0001")
        return 1
    if abs(lsb_delta) <= args.tolerance_lsb:
        print(f"PASS: Q16.16 delta {lsb_delta} within {args.tolerance_lsb} LSB")
        return 0

    print(f"FAIL: Q16.16 delta {lsb_delta} exceeds {args.tolerance_lsb} LSB")
    return 1


if __name__ == "__main__":
    sys.exit(main())
