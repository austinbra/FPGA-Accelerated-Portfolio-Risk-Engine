#!/usr/bin/env python3
"""Collect claim-grade, boundary-explicit performance evidence.

The script intentionally keeps FPGA core latency separate from every CPU and
host boundary.  It can run the inexpensive C++ oracle, run or parse xsim,
run or parse Google Benchmark, and parse routed Vivado reports.  Compact JSON,
CSV, and Markdown artifacts are written to ``results/claims`` by default.

Full reproduction (Vivado tools and a C++ toolchain required)::

    python scripts/reproduce_claims.py --cpp-mode run --xsim-mode run \
        --benchmark-mode run --vivado-mode run --require-complete

Fast, partial collection is the default.  Expensive sources can instead be
parsed from archived files or skipped explicitly.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import json
import math
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence


Q16_SCALE = 1 << 16
SUCCESS_MARKER = 0xABCD0001
DEFAULT_CLOCK_HZ = 100_000_000.0
DEFAULT_LANES = 4
EXERCISE_MODE = "multi"
OPTION_TYPE = "put"
RTL_CORE_TOP = "top_mc_option_pricer_multi_stored"
EXPECTED_IMPLEMENTATION_TOP = "arty_a7_option_pricer_top"
EXPECTED_DEVICE_NORMALIZED = "7a100tcsg"


class EvidenceError(RuntimeError):
    """Raised when evidence is malformed, inconsistent, or unavailable."""


@dataclass(frozen=True)
class ClaimCase:
    case_id: str
    paths: int
    steps: int
    expected_price_raw: int
    expected_core_cycles: int
    S0: float = 100.0
    K: float = 100.0
    r: float = 0.05
    sigma: float = 0.2
    T: float = 1.0
    option_type: int = 1

    @property
    def price(self) -> float:
        return self.expected_price_raw / Q16_SCALE


CANONICAL_CASES = (
    ClaimCase("put_1024x4_multi", 1024, 4, 391_343, 72_394),
    ClaimCase("put_1024x12_multi", 1024, 12, 428_757, 236_362),
)


@dataclass(frozen=True)
class CommandResult:
    command: list[str]
    stdout: str
    stderr: str
    returncode: int


def _run(
    command: Sequence[str | os.PathLike[str]],
    *,
    cwd: Path,
    timeout: int,
) -> CommandResult:
    rendered = [os.fspath(part) for part in command]
    try:
        proc = subprocess.run(
            rendered,
            cwd=cwd,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError as exc:
        raise EvidenceError(f"command not found: {rendered[0]}") from exc
    except subprocess.TimeoutExpired as exc:
        raise EvidenceError(
            f"command timed out after {timeout}s: {shlex.join(rendered)}"
        ) from exc
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout).strip()
        raise EvidenceError(
            f"command failed ({proc.returncode}): {shlex.join(rendered)}"
            + (f"\n{detail}" if detail else "")
        )
    return CommandResult(rendered, proc.stdout, proc.stderr, proc.returncode)


def _read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        raise EvidenceError(f"could not read evidence file {path}: {exc}") from exc


def _display_path(path: Path, repo: Path) -> str:
    try:
        return path.resolve().relative_to(repo.resolve()).as_posix()
    except ValueError:
        return os.fspath(path.resolve())


def file_fingerprint(path: Path, repo: Path) -> dict[str, Any]:
    """Return a compact content and freshness identity for an evidence file."""
    resolved = path.resolve()
    try:
        stat = resolved.stat()
    except OSError as exc:
        raise EvidenceError(f"could not stat evidence file {resolved}: {exc}") from exc
    digest = hashlib.sha256()
    try:
        with resolved.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as exc:
        raise EvidenceError(f"could not fingerprint evidence file {resolved}: {exc}") from exc
    return {
        "path": _display_path(resolved, repo),
        "sha256": digest.hexdigest(),
        "size_bytes": stat.st_size,
        "mtime_ns": stat.st_mtime_ns,
        "mtime_utc": dt.datetime.fromtimestamp(
            stat.st_mtime, tz=dt.timezone.utc
        ).isoformat(),
    }


def _snapshot_files(repo: Path, roots_and_patterns: Sequence[tuple[str, str]]) -> dict[str, Any]:
    paths: set[Path] = set()
    for root_name, pattern in roots_and_patterns:
        root = repo / root_name
        if root.is_dir():
            paths.update(path for path in root.rglob(pattern) if path.is_file())
        elif root.is_file() and root.match(pattern):
            paths.add(root)
    ordered = sorted(paths, key=lambda path: _display_path(path, repo))
    aggregate = hashlib.sha256()
    latest_mtime_ns = 0
    latest_path: str | None = None
    for path in ordered:
        fingerprint = file_fingerprint(path, repo)
        relative = fingerprint["path"]
        aggregate.update(relative.encode("utf-8"))
        aggregate.update(bytes((0,)))
        aggregate.update(fingerprint["sha256"].encode("ascii"))
        aggregate.update(b"\n")
        if fingerprint["mtime_ns"] >= latest_mtime_ns:
            latest_mtime_ns = fingerprint["mtime_ns"]
            latest_path = relative
    return {
        "sha256": aggregate.hexdigest(),
        "file_count": len(ordered),
        "latest_source_mtime_ns": latest_mtime_ns,
        "latest_source_mtime_utc": (
            dt.datetime.fromtimestamp(
                latest_mtime_ns / 1e9, tz=dt.timezone.utc
            ).isoformat()
            if latest_mtime_ns
            else None
        ),
        "latest_source_path": latest_path,
    }


def source_snapshot(repo: Path) -> dict[str, Any]:
    """Fingerprint the exact C++ and routed-RTL inputs used by claim collection."""
    rtl = _snapshot_files(
        repo,
        (
            ("src", "*.sv"),
            ("src/gen", "*.mem"),
            ("fpga", "*.sv"),
            ("fpga", "*.mem"),
            ("constraints", "*.xdc"),
            ("scripts/vivado_build_arty_a7.tcl", "vivado_build_arty_a7.tcl"),
            ("scripts/run_vivado_build_arty_a7.ps1", "run_vivado_build_arty_a7.ps1"),
            ("scripts/vivado_build_runner.py", "vivado_build_runner.py"),
        ),
    )
    cpp = _snapshot_files(
        repo,
        (
            ("baseline/cpp_fixed", "main.cpp"),
            ("baseline/cpp_fixed", "pricing.cpp"),
            ("baseline/cpp_fixed", "pricing.h"),
            ("baseline/cpp_fixed", "linalg.cpp"),
            ("baseline/cpp_fixed", "linalg.h"),
            ("baseline/cpp_fixed", "rtl_math.cpp"),
            ("baseline/cpp_fixed", "rtl_math.h"),
            ("baseline/cpp_fixed", "sobol_wrapper.cpp"),
            ("baseline/cpp_fixed", "sobol_wrapper.h"),
            ("baseline/cpp_fixed", "utils.cpp"),
            ("baseline/cpp_fixed", "utils.h"),
            ("baseline/cpp_fixed", "types.h"),
            ("baseline/cpp_fixed", "google_benchmark.cpp"),
            ("baseline/cpp_fixed", "pricing_intrinsic_test.cpp"),
            ("baseline/cpp_fixed", "CMakeLists.txt"),
            ("src/gen", "*.mem"),
        ),
    )
    combined = hashlib.sha256(
        f"rtl={rtl['sha256']}\ncpp={cpp['sha256']}\n".encode("ascii")
    ).hexdigest()
    return {"combined_sha256": combined, "rtl": rtl, "cpp": cpp}


def parse_cpp_output(text: str) -> dict[str, Any]:
    raw_match = re.search(r"Estimated Option Price \(Q16\.16\):\s*(-?\d+)", text)
    price_match = re.search(
        r"Estimated Option Price \(double\):\s*([-+0-9.eE]+)", text
    )
    elapsed_match = re.search(r"Elapsed Time:\s*([-+0-9.eE]+)\s+seconds", text)
    mode_match = re.search(r"Pricing Mode:\s*([A-Z0-9_]+)", text)
    type_match = re.search(r"Option Type:\s*(PUT|CALL)", text)
    if not all((raw_match, price_match, elapsed_match, mode_match, type_match)):
        raise EvidenceError("C++ output is missing price, elapsed-time, type, or mode fields")
    return {
        "price_raw_q16_16": int(raw_match.group(1)),
        "price": float(price_match.group(1)),
        "process_elapsed_seconds": float(elapsed_match.group(1)),
        "exercise_mode_label": mode_match.group(1),
        "option_type": type_match.group(1).lower(),
    }


_XSIM_LINE = re.compile(
    r"\[VIRTUAL_A7\]\s+paths=(\d+)\s+steps=(\d+)\s+"
    r"core_cycles=(\d+)\s+price_raw=(0x[0-9a-fA-F]+)\s+"
    r"marker=(0x[0-9a-fA-F]+)"
)


def parse_xsim_output(text: str, case: ClaimCase | None = None) -> dict[str, Any]:
    rows = []
    for match in _XSIM_LINE.finditer(text):
        row = {
            "paths": int(match.group(1)),
            "steps": int(match.group(2)),
            "core_cycles": int(match.group(3)),
            "price_raw_q16_16": int(match.group(4), 16),
            "result_marker": int(match.group(5), 16),
            "evidence_line": match.group(0),
        }
        if row["price_raw_q16_16"] & 0x80000000:
            row["price_raw_q16_16"] -= 1 << 32
        rows.append(row)
    if case is not None:
        rows = [
            row
            for row in rows
            if row["paths"] == case.paths and row["steps"] == case.steps
        ]
    if len(rows) != 1:
        suffix = f" for {case.case_id}" if case else ""
        raise EvidenceError(f"expected exactly one [VIRTUAL_A7] record{suffix}; found {len(rows)}")
    if rows[0]["result_marker"] != SUCCESS_MARKER:
        raise EvidenceError(
            f"xsim result marker is 0x{rows[0]['result_marker']:08X}, "
            f"expected 0x{SUCCESS_MARKER:08X}"
        )
    version = re.search(r"\*{6}\s+xsim\s+v([^\s]+)", text, re.IGNORECASE)
    rows[0]["xsim_version"] = version.group(1) if version else None
    rows[0]["price"] = rows[0]["price_raw_q16_16"] / Q16_SCALE
    return rows[0]


def _report_metadata(text: str) -> dict[str, str | None]:
    def value(label: str) -> str | None:
        match = re.search(rf"^\|\s*{re.escape(label)}\s*:\s*(.*?)\s*$", text, re.MULTILINE)
        return match.group(1).strip() if match else None

    return {
        "tool": value("Tool Version"),
        "report_date": value("Date"),
        "implementation_top": value("Design"),
        "device": value("Device"),
        "design_state": value("Design State"),
    }


def parse_timing_report(text: str) -> dict[str, Any]:
    metadata = _report_metadata(text)
    summary = re.search(
        r"WNS\(ns\).*?\n\s*-+.*?\n\s*"
        r"([-+]?\d+(?:\.\d+)?)\s+([-+]?\d+(?:\.\d+)?)\s+(\d+)",
        text,
        re.DOTALL,
    )
    if not summary:
        raise EvidenceError("could not parse Vivado design timing summary")
    clock = re.search(
        r"^sys_clk\s+\{[^}]+\}\s+([0-9.]+)\s+([0-9.]+)\s*$",
        text,
        re.MULTILINE,
    )
    constraints_met = bool(
        re.search(r"All user specified timing constraints are met", text)
    )
    return {
        **metadata,
        "wns_ns": float(summary.group(1)),
        "tns_ns": float(summary.group(2)),
        "setup_failing_endpoints": int(summary.group(3)),
        "clock_name": "sys_clk" if clock else None,
        "clock_period_ns": float(clock.group(1)) if clock else None,
        "clock_frequency_mhz": float(clock.group(2)) if clock else None,
        "all_constraints_met": constraints_met,
    }


def _parse_util_row(text: str, label: str) -> dict[str, float | int]:
    match = re.search(
        rf"^\|\s*{re.escape(label)}\s*\|\s*(\d+)\s*\|\s*\d+\s*\|"
        rf"\s*\d+\s*\|\s*(\d+)\s*\|\s*([0-9.]+)\s*\|",
        text,
        re.MULTILINE,
    )
    if not match:
        raise EvidenceError(f"could not parse utilization row: {label}")
    return {
        "used": int(match.group(1)),
        "available": int(match.group(2)),
        "percent": float(match.group(3)),
    }


def parse_utilization_report(text: str) -> dict[str, Any]:
    return {
        **_report_metadata(text),
        "slice_luts": _parse_util_row(text, "Slice LUTs"),
        "slice_registers": _parse_util_row(text, "Slice Registers"),
        "block_ram_tiles": _parse_util_row(text, "Block RAM Tile"),
        "dsps": _parse_util_row(text, "DSPs"),
    }


def _normalize_device(value: str | None) -> str | None:
    if not value:
        return None
    normalized = re.sub(r"[^a-z0-9]", "", value.lower())
    if normalized.startswith("xc"):
        normalized = normalized[2:]
    normalized = re.sub(r"\d+$", "", normalized)
    return normalized or None


_BOUNDARY_BENCHMARKS = {
    "end_to_end": "BM_EndToEndMultiPutMatrix",
    "pricing_core": "BM_PricingCoreMultiPutMatrix",
    "hot_kernel": "BM_HotKernelMultiPutMatrix",
}
_TIME_SCALE = {"ns": 1e-9, "us": 1e-6, "ms": 1e-3, "s": 1.0}


def parse_benchmark_json(
    document: Mapping[str, Any], cases: Iterable[ClaimCase] = CANONICAL_CASES
) -> dict[str, Any]:
    context = dict(document.get("context", {}))
    rows = document.get("benchmarks")
    if not isinstance(rows, list):
        raise EvidenceError("Google Benchmark JSON has no benchmarks array")

    parsed_cases: dict[str, Any] = {}
    for case in cases:
        boundaries: dict[str, Any] = {}
        for boundary, benchmark_name in _BOUNDARY_BENCHMARKS.items():
            run_name = f"{benchmark_name}/{case.paths}/{case.steps}"
            candidates = [
                row
                for row in rows
                if row.get("run_name") == run_name
                and row.get("aggregate_name") == "mean"
            ]
            if len(candidates) != 1:
                raise EvidenceError(
                    f"expected one mean Google Benchmark row for {run_name}; "
                    f"found {len(candidates)}"
                )
            row = candidates[0]
            unit = row.get("time_unit")
            if unit not in _TIME_SCALE:
                raise EvidenceError(f"unsupported Google Benchmark time unit: {unit!r}")
            if row.get("error_occurred"):
                raise EvidenceError(f"benchmark failed for {run_name}: {row.get('error_message')}")
            boundaries[boundary] = {
                "benchmark": run_name,
                "mean_real_seconds": float(row["real_time"]) * _TIME_SCALE[unit],
                "mean_cpu_seconds": float(row["cpu_time"]) * _TIME_SCALE[unit],
                "repetitions": int(row.get("repetitions", 0)),
                "iterations": int(row.get("iterations", 0)),
                "label": row.get("label"),
            }
        parsed_cases[case.case_id] = boundaries
    return {"context": context, "cases": parsed_cases}


def _git_value(repo: Path, *args: str) -> str | None:
    try:
        return _run(["git", *args], cwd=repo, timeout=20).stdout.strip() or None
    except EvidenceError:
        return None


def _cpu_model() -> str:
    if sys.platform.startswith("linux"):
        try:
            for line in Path("/proc/cpuinfo").read_text(errors="replace").splitlines():
                if line.lower().startswith("model name"):
                    return line.split(":", 1)[1].strip()
        except OSError:
            pass
    identifier = os.environ.get("PROCESSOR_IDENTIFIER", "").strip()
    return identifier or platform.processor() or "unknown"


def _tool_version(command: Sequence[str], repo: Path) -> str | None:
    try:
        result = _run(command, cwd=repo, timeout=30)
    except EvidenceError:
        return None
    combined = (result.stdout + "\n" + result.stderr).strip()
    return combined.splitlines()[0] if combined else None


def _q16(value: float) -> int:
    scaled = value * Q16_SCALE
    # These canonical parameters are not ties.  Keep the conversion explicit
    # so the plusargs are auditable and match the C++ Q16.16 values.
    return math.floor(scaled + 0.5) if scaled >= 0 else math.ceil(scaled - 0.5)


def _cpp_command(executable: Path, repo: Path, case: ClaimCase) -> list[str]:
    return [
        os.fspath(executable),
        "--paths",
        str(case.paths),
        "--steps",
        str(case.steps),
        "--S0",
        str(case.S0),
        "--K",
        str(case.K),
        "--r",
        str(case.r),
        "--sigma",
        str(case.sigma),
        "--T",
        str(case.T),
        "--option-type",
        str(case.option_type),
        "--exercise-mode",
        EXERCISE_MODE,
        "--direction-file",
        os.fspath(repo / "src" / "gen" / "direction.mem"),
        "--lut-dir",
        os.fspath(repo / "src" / "gen"),
    ]


def build_cpp_oracle(repo: Path, build_dir: Path, compiler: str) -> tuple[Path, list[str]]:
    build_dir.mkdir(parents=True, exist_ok=True)
    executable = build_dir / ("fixed_baseline.exe" if os.name == "nt" else "fixed_baseline")
    source_dir = repo / "baseline" / "cpp_fixed"
    command = [
        compiler,
        "-std=c++17",
        "-O3",
        "-DNDEBUG",
        "main.cpp",
        "pricing.cpp",
        "linalg.cpp",
        "rtl_math.cpp",
        "sobol_wrapper.cpp",
        "utils.cpp",
        "-o",
        os.fspath(executable),
    ]
    _run(command, cwd=source_dir, timeout=300)
    return executable, command


def collect_cpp_runs(
    repo: Path, executable: Path, raw_dir: Path, timeout: int
) -> dict[str, Any]:
    evidence: dict[str, Any] = {}
    for case in CANONICAL_CASES:
        command = _cpp_command(executable, repo, case)
        result = _run(command, cwd=repo, timeout=timeout)
        raw_path = raw_dir / f"{case.case_id}_cpp.txt"
        raw_path.write_text(result.stdout + result.stderr, encoding="utf-8")
        parsed = parse_cpp_output(result.stdout + result.stderr)
        parsed["command"] = command
        parsed["source"] = os.fspath(raw_path)
        parsed["artifact_fingerprint"] = file_fingerprint(raw_path, repo)
        evidence[case.case_id] = parsed
    return evidence


def collect_cpp_logs(paths: Mapping[str, Path], repo: Path) -> dict[str, Any]:
    evidence = {}
    for case in CANONICAL_CASES:
        path = paths.get(case.case_id)
        if path is None:
            continue
        parsed = parse_cpp_output(_read_text(path))
        parsed["source"] = os.fspath(path)
        parsed["artifact_fingerprint"] = file_fingerprint(path, repo)
        evidence[case.case_id] = parsed
    return evidence


def _powershell_executable() -> str:
    for name in ("pwsh", "powershell.exe", "powershell"):
        found = shutil.which(name)
        if found:
            return found
    raise EvidenceError("PowerShell is required to run the existing xsim harness")


def _xsim_plusargs(case: ClaimCase) -> str:
    values = {
        "paths": case.paths,
        "steps": case.steps,
        "S0": _q16(case.S0),
        "K": _q16(case.K),
        "r": _q16(case.r),
        "sigma": _q16(case.sigma),
        "T": _q16(case.T),
        "opt": case.option_type,
        "expected_price": case.expected_price_raw,
    }
    return ",".join(f"{key}={value}" for key, value in values.items())


def collect_xsim_runs(repo: Path, raw_dir: Path, timeout: int) -> dict[str, Any]:
    powershell = _powershell_executable()
    harness = repo / "scripts" / "run_tb_top_uart_safe.ps1"
    evidence: dict[str, Any] = {}
    for index, case in enumerate(CANONICAL_CASES):
        command = [
            powershell,
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            os.fspath(harness),
            "-ComputeMode",
            "-MultiExercise",
            "-NumLanes",
            str(DEFAULT_LANES),
            "-TestPlusargs",
            _xsim_plusargs(case),
            "-XsimTimeoutSeconds",
            str(timeout),
        ]
        if index == 0:
            command.append("-NoCleanup")
        else:
            command.append("-SkipCompile")
        result = _run(command, cwd=repo, timeout=timeout + 2400)
        raw_path = raw_dir / f"{case.case_id}_xsim.txt"
        raw_path.write_text(result.stdout + result.stderr, encoding="utf-8")
        parsed = parse_xsim_output(result.stdout + result.stderr, case)
        parsed["command"] = command
        parsed["source"] = os.fspath(raw_path)
        parsed["artifact_fingerprint"] = file_fingerprint(raw_path, repo)
        evidence[case.case_id] = parsed
    return evidence


def collect_xsim_logs(paths: Mapping[str, Path], repo: Path) -> dict[str, Any]:
    evidence = {}
    for case in CANONICAL_CASES:
        path = paths.get(case.case_id)
        if path is None:
            continue
        parsed = parse_xsim_output(_read_text(path), case)
        parsed["source"] = os.fspath(path)
        parsed["artifact_fingerprint"] = file_fingerprint(path, repo)
        evidence[case.case_id] = parsed
    return evidence


def vivado_route_command(repo: Path, timeout: int, powershell: str) -> list[str]:
    harness = repo / "scripts" / "run_vivado_build_arty_a7.ps1"
    return [
        powershell,
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        os.fspath(harness),
        "-MultiExercise",
        "-NumLanes",
        str(DEFAULT_LANES),
        "-ClockPeriodNs",
        "10.0",
        "-TimeoutSeconds",
        str(timeout),
    ]


def run_vivado_route(repo: Path, timeout: int) -> dict[str, Any]:
    """Run the existing four-lane, 10 ns Artix-7 implementation flow."""
    command = vivado_route_command(repo, timeout, _powershell_executable())
    started_at_ns = dt.datetime.now(dt.timezone.utc).timestamp() * 1e9
    result = _run(command, cwd=repo, timeout=timeout + 300)
    return {
        "command": command,
        "started_at_ns": int(started_at_ns),
        "stdout_tail": (result.stdout + result.stderr)[-2000:],
    }


def benchmark_configure_command(
    repo: Path, build_dir: Path, compiler: str
) -> list[str]:
    source_dir = repo / "baseline" / "cpp_fixed"
    selected_compiler = shutil.which(compiler) or compiler
    # This project uses MinGW g++ on Windows. CMake's auto-selected Ninja
    # generator can leave its compiler try-link waiting indefinitely in the
    # restricted Windows shell used by the reproduction flow. Prefer the
    # matching MinGW generator when it is available; other platforms retain
    # their normal CMake default.
    generator = (
        ["-G", "MinGW Makefiles"]
        if os.name == "nt" and shutil.which("mingw32-make")
        else []
    )
    return [
        "cmake",
        *generator,
        "-S",
        os.fspath(source_dir),
        "-B",
        os.fspath(build_dir),
        "-DCMAKE_BUILD_TYPE=Release",
        f"-DCMAKE_CXX_COMPILER={selected_compiler}",
        "-DQMC_BENCHMARK_NATIVE_ARCH=ON",
        "-DBENCHMARK_ENABLE_TESTING=OFF",
    ]


def build_and_run_benchmark(
    repo: Path, build_dir: Path, raw_dir: Path, timeout: int, compiler: str
) -> tuple[dict[str, Any], list[list[str]]]:
    configure = benchmark_configure_command(repo, build_dir, compiler)
    build = ["cmake", "--build", os.fspath(build_dir), "--config", "Release"]
    _run(configure, cwd=repo, timeout=timeout)
    _run(build, cwd=repo, timeout=timeout)
    candidates = (
        build_dir / "Release" / "qmc_google_benchmark.exe",
        build_dir / "qmc_google_benchmark.exe",
        build_dir / "qmc_google_benchmark",
    )
    executable = next((path for path in candidates if path.is_file()), None)
    if executable is None:
        raise EvidenceError(f"could not find qmc_google_benchmark under {build_dir}")
    raw_json = raw_dir / "google_benchmark.json"
    run = [
        os.fspath(executable),
        r"--benchmark_filter=BM_(EndToEnd|PricingCore|HotKernel)MultiPutMatrix/1024/(4|12)$",
        "--benchmark_repetitions=15",
        "--benchmark_report_aggregates_only=true",
        "--benchmark_min_time=0.1s",
        f"--benchmark_out={raw_json}",
        "--benchmark_out_format=json",
    ]
    _run(run, cwd=repo, timeout=timeout)
    try:
        document = json.loads(_read_text(raw_json))
    except json.JSONDecodeError as exc:
        raise EvidenceError(f"invalid Google Benchmark JSON in {raw_json}: {exc}") from exc
    parsed = parse_benchmark_json(document)
    parsed["artifact_fingerprint"] = file_fingerprint(raw_json, repo)
    return parsed, [configure, build, run]


def collect_benchmark_file(path: Path, repo: Path) -> dict[str, Any]:
    try:
        document = json.loads(_read_text(path))
    except json.JSONDecodeError as exc:
        raise EvidenceError(f"invalid Google Benchmark JSON in {path}: {exc}") from exc
    parsed = parse_benchmark_json(document)
    parsed["source"] = os.fspath(path)
    parsed["artifact_fingerprint"] = file_fingerprint(path, repo)
    return parsed


def _financial_reference(case: ClaimCase, steps: int) -> dict[str, Any] | None:
    if case.steps != 4:
        return None
    try:
        from financial_reference import american_binomial_crr
    except ImportError as exc:  # pragma: no cover - indicates a broken checkout
        raise EvidenceError("could not import scripts/financial_reference.py") from exc
    reference = american_binomial_crr(
        case.S0,
        case.K,
        case.r,
        case.sigma,
        case.T,
        case.option_type,
        steps,
    )
    signed_error = case.price - reference
    return {
        "model": "CRR American binomial tree",
        "reference_steps": steps,
        "price": reference,
        "qmc_lsm_price": case.price,
        "signed_error": signed_error,
        "absolute_error": abs(signed_error),
        "signed_error_bps_of_spot": signed_error / case.S0 * 10_000.0,
        "absolute_error_bps_of_spot": abs(signed_error) / case.S0 * 10_000.0,
        "scope": "this canonical workload only; not a global accuracy guarantee",
    }


def assemble_evidence(
    *,
    repo: Path,
    cpp: Mapping[str, Any],
    xsim: Mapping[str, Any],
    benchmark: Mapping[str, Any] | None,
    timing: Mapping[str, Any] | None,
    utilization: Mapping[str, Any] | None,
    clock_hz: float,
    compiler_version: str | None,
    cpp_build_command: Sequence[str] | None,
    benchmark_commands: Sequence[Sequence[str]] | None,
    reference_steps: int,
    skipped_sources: Sequence[str],
    benchmark_compiler_version: str | None = None,
    snapshots: Mapping[str, Any] | None = None,
    artifact_fingerprints: Mapping[str, Any] | None = None,
    collection_modes: Mapping[str, str] | None = None,
    parsed_source_fingerprint: str | None = None,
    parsed_git_commit: str | None = None,
    vivado_run: Mapping[str, Any] | None = None,
    snapshot_before_collection: Mapping[str, Any] | None = None,
    benchmark_cpu: str | None = None,
) -> dict[str, Any]:
    commit = _git_value(repo, "rev-parse", "HEAD")
    status = _git_value(repo, "status", "--porcelain")
    benchmark_context = benchmark.get("context", {}) if benchmark else {}
    snapshots = dict(snapshots or source_snapshot(repo))
    artifact_fingerprints = dict(artifact_fingerprints or {})
    modes = {"cpp": "run", "xsim": "run", "benchmark": "run", "vivado": "run"}
    modes.update(collection_modes or {})
    benchmark_cpu_identity = benchmark_cpu or (
        _cpu_model() if modes.get("benchmark") == "run" else None
    )
    timing_period = timing.get("clock_period_ns") if timing else None
    configured_period = 1e9 / clock_hz
    routed_clock_hz = 1e9 / float(timing_period) if timing_period else None
    effective_clock_hz = routed_clock_hz or clock_hz
    problems: list[str] = []
    warnings: list[str] = []

    if not commit:
        problems.append("missing git commit provenance")
    if not compiler_version:
        problems.append("missing C++ oracle compiler provenance")
    if benchmark is not None and not (benchmark_compiler_version or compiler_version):
        problems.append("missing Google Benchmark compiler provenance")
    if benchmark is not None and not benchmark_cpu_identity:
        problems.append("missing Google Benchmark CPU provenance")

    parsed_modes = [
        name for name, mode in modes.items() if mode in ("parse", "prebuilt")
    ]
    if parsed_modes:
        if not parsed_git_commit:
            problems.append(
                "parsed evidence requires --parsed-git-commit provenance"
            )
        elif commit and parsed_git_commit != commit:
            problems.append(
                f"parsed evidence commit {parsed_git_commit} does not match current {commit}"
            )
        current_fingerprint = snapshots.get("combined_sha256")
        if not parsed_source_fingerprint:
            problems.append(
                "parsed evidence requires --parsed-source-fingerprint provenance"
            )
        elif parsed_source_fingerprint != current_fingerprint:
            problems.append("parsed evidence source fingerprint does not match current sources")

    if snapshot_before_collection and (
        snapshot_before_collection.get("combined_sha256")
        != snapshots.get("combined_sha256")
    ):
        problems.append("implementation sources changed during evidence collection")

    if benchmark is not None:
        build_type = str(benchmark_context.get("library_build_type", "")).lower()
        if build_type != "release":
            problems.append(
                "Google Benchmark provenance must report library_build_type=release"
            )

    if timing_period is not None and not math.isclose(
        float(timing_period), configured_period, rel_tol=0.0, abs_tol=1e-6
    ):
        problems.append(
            f"configured clock period {configured_period:g} ns does not match "
            f"routed report requirement {float(timing_period):g} ns"
        )
    if timing_period and timing and timing.get("clock_frequency_mhz") is not None:
        derived_frequency_mhz = 1000.0 / float(timing_period)
        if not math.isclose(
            float(timing["clock_frequency_mhz"]),
            derived_frequency_mhz,
            rel_tol=0.0,
            abs_tol=1e-6,
        ):
            problems.append("routed clock period and frequency metadata are inconsistent")

    cases = []
    for case in CANONICAL_CASES:
        cpp_row = dict(cpp[case.case_id]) if case.case_id in cpp else None
        xsim_row = dict(xsim[case.case_id]) if case.case_id in xsim else None
        bench_rows = (
            dict(benchmark["cases"][case.case_id])
            if benchmark and case.case_id in benchmark.get("cases", {})
            else None
        )
        if cpp_row is None:
            problems.append(f"missing C++ oracle evidence for {case.case_id}")
        else:
            if cpp_row["price_raw_q16_16"] != case.expected_price_raw:
                problems.append(
                    f"{case.case_id} C++ raw price {cpp_row['price_raw_q16_16']} "
                    f"!= canonical {case.expected_price_raw}"
                )
            if cpp_row["exercise_mode_label"] != "FPGA_STYLE_MULTI_EXERCISE":
                problems.append(f"{case.case_id} C++ did not run multi-exercise mode")
            if cpp_row["option_type"] != OPTION_TYPE:
                problems.append(f"{case.case_id} C++ did not price a PUT")
        if xsim_row is None:
            problems.append(f"missing four-lane xsim evidence for {case.case_id}")
        else:
            xsim_row["core_latency_seconds"] = (
                xsim_row["core_cycles"] / effective_clock_hz
            )
            xsim_row["latency_clock_source"] = (
                "routed sys_clk Clock Summary"
                if routed_clock_hz
                else "configured --clock-hz (not routed evidence)"
            )
            if not xsim_row.get("xsim_version"):
                problems.append(f"{case.case_id} is missing xsim tool provenance")
            if xsim_row["price_raw_q16_16"] != case.expected_price_raw:
                problems.append(
                    f"{case.case_id} xsim raw price {xsim_row['price_raw_q16_16']} "
                    f"!= canonical {case.expected_price_raw}"
                )
            if xsim_row["core_cycles"] != case.expected_core_cycles:
                problems.append(
                    f"{case.case_id} xsim cycles {xsim_row['core_cycles']} "
                    f"!= canonical {case.expected_core_cycles}"
                )

        parity = None
        if cpp_row and xsim_row:
            delta = xsim_row["price_raw_q16_16"] - cpp_row["price_raw_q16_16"]
            parity = {"raw_lsb_delta": delta, "bit_exact": delta == 0}
            if delta != 0:
                problems.append(f"{case.case_id} C++/xsim result is not bit-exact")

        if not bench_rows:
            problems.append(f"missing CPU boundary benchmark evidence for {case.case_id}")
        else:
            if set(bench_rows) != set(_BOUNDARY_BENCHMARKS):
                problems.append(f"{case.case_id} is missing a named CPU timing boundary")
            for boundary, row in bench_rows.items():
                if row["mean_real_seconds"] <= 0 or not math.isfinite(
                    row["mean_real_seconds"]
                ):
                    problems.append(f"{case.case_id} {boundary} has invalid timing")
                expected_label = f"Q16.16 price={case.expected_price_raw}"
                if row.get("label") != expected_label:
                    problems.append(
                        f"{case.case_id} {boundary} benchmark label does not bind "
                        "the canonical raw price"
                    )
                if xsim_row:
                    row["cpu_mean_real_over_fpga_core_ratio"] = (
                        row["mean_real_seconds"] / xsim_row["core_latency_seconds"]
                    )
                if row["repetitions"] < 15:
                    problems.append(
                        f"{case.case_id} {boundary} has {row['repetitions']} benchmark "
                        "repetitions; claim-grade collection requires 15"
                    )

        cases.append(
            {
                "case_id": case.case_id,
                "workload": asdict(case),
                "cpp_rtl_exact": cpp_row,
                "rtl_xsim_four_lane": xsim_row,
                "cpp_rtl_parity": parity,
                "cpu_boundaries": bench_rows,
                "financial_reference": _financial_reference(case, reference_steps),
            }
        )

    if timing is None:
        problems.append("missing routed timing report")
    else:
        for field in (
            "tool",
            "report_date",
            "implementation_top",
            "device",
            "design_state",
            "clock_name",
            "clock_period_ns",
            "clock_frequency_mhz",
        ):
            if timing.get(field) in (None, ""):
                problems.append(f"timing report is missing {field} metadata")
        if str(timing.get("design_state", "")).lower() != "routed":
            problems.append("timing report Design State is not Routed")
        if timing.get("implementation_top") != EXPECTED_IMPLEMENTATION_TOP:
            problems.append("timing report does not target the expected Artix-7 wrapper")
        if _normalize_device(timing.get("device")) != EXPECTED_DEVICE_NORMALIZED:
            problems.append("timing report does not target the expected Artix-7 100T device")
        if timing["wns_ns"] < 0 or timing["tns_ns"] != 0:
            problems.append("routed implementation does not close setup timing")
        if timing["setup_failing_endpoints"] != 0:
            problems.append("routed implementation has setup failing endpoints")
        if not timing["all_constraints_met"]:
            problems.append("timing report does not state that all constraints are met")
    if utilization is None:
        problems.append("missing routed utilization report")
    else:
        for field in (
            "tool",
            "report_date",
            "implementation_top",
            "device",
            "design_state",
        ):
            if utilization.get(field) in (None, ""):
                problems.append(f"utilization report is missing {field} metadata")
        if str(utilization.get("design_state", "")).lower() != "routed":
            problems.append("utilization report Design State is not Routed")
        if utilization.get("implementation_top") != EXPECTED_IMPLEMENTATION_TOP:
            problems.append("utilization report does not target the expected Artix-7 wrapper")
        if _normalize_device(utilization.get("device")) != EXPECTED_DEVICE_NORMALIZED:
            problems.append(
                "utilization report does not target the expected Artix-7 100T device"
            )

    if timing is not None and utilization is not None:
        if timing.get("tool") != utilization.get("tool"):
            problems.append("timing/utilization Vivado tool metadata does not match")
        if timing.get("implementation_top") != utilization.get("implementation_top"):
            problems.append("timing/utilization implementation tops do not match")
        if _normalize_device(timing.get("device")) != _normalize_device(
            utilization.get("device")
        ):
            problems.append("timing/utilization FPGA devices do not match")

    timing_file = artifact_fingerprints.get("timing_report")
    utilization_file = artifact_fingerprints.get("utilization_report")
    if timing is not None and not timing_file:
        problems.append("missing timing-report content fingerprint")
    if utilization is not None and not utilization_file:
        problems.append("missing utilization-report content fingerprint")
    if timing_file and utilization_file:
        latest_rtl_source = int(
            snapshots.get("rtl", {}).get("latest_source_mtime_ns", 0)
        )
        oldest_report = min(
            int(timing_file.get("mtime_ns", 0)),
            int(utilization_file.get("mtime_ns", 0)),
        )
        if latest_rtl_source and oldest_report < latest_rtl_source:
            problems.append(
                "routed reports predate the latest RTL/build input; rerun Vivado"
            )
        if vivado_run and oldest_report < int(vivado_run.get("started_at_ns", 0)):
            problems.append("Vivado run did not produce fresh routed reports")

    provenance = {
        "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "git_commit": commit,
        "git_worktree_dirty": bool(status),
        "host": platform.node(),
        "operating_system": platform.platform(),
        "current_host_cpu": _cpu_model(),
        "benchmark_cpu": benchmark_cpu_identity,
        "python": sys.version.splitlines()[0],
        "cpp_compiler": compiler_version,
        "benchmark_compiler": benchmark_compiler_version or compiler_version,
        "google_benchmark": benchmark_context,
        "vivado": (timing or utilization or {}).get("tool"),
        "fpga_device": (utilization or timing or {}).get("device"),
        "implementation_top": (utilization or timing or {}).get("implementation_top"),
        "rtl_core_top": RTL_CORE_TOP,
        "lanes": DEFAULT_LANES,
        "configured_clock_hz": clock_hz,
        "configured_clock_period_ns": configured_period,
        "routed_clock_hz": routed_clock_hz,
        "routed_clock_period_ns": timing_period,
        "latency_clock_hz": effective_clock_hz,
        "latency_clock_source": (
            "routed sys_clk Clock Summary"
            if routed_clock_hz
            else "configured --clock-hz (not routed evidence)"
        ),
        "exercise_mode": EXERCISE_MODE,
        "option_type": OPTION_TYPE,
        "collection_modes": modes,
        "parsed_source_fingerprint": parsed_source_fingerprint,
        "parsed_git_commit": parsed_git_commit,
        "source_snapshot": snapshots,
        "artifact_fingerprints": artifact_fingerprints,
        "vivado_run": dict(vivado_run) if vivado_run else None,
        "cpp_build_command": list(cpp_build_command) if cpp_build_command else None,
        "benchmark_commands": [list(cmd) for cmd in benchmark_commands]
        if benchmark_commands
        else None,
        "skipped_sources": list(skipped_sources),
    }
    return {
        "schema_version": 2,
        "claim_ready": not problems and not warnings,
        "provenance": provenance,
        "timing_boundary_definitions": {
            "fpga_core": (
                "RTL acceptance of a complete job through result_valid; includes "
                "initialization, Sobol/GBM generation, LSM regression, exercise "
                "decisions, and averaging; excludes UART, USB, Python, and host scheduling"
            ),
            "cpu_end_to_end": "direction-file load, allocation, path generation, and induction",
            "cpu_pricing_core": "persistent direction data; allocation, path generation, and induction",
            "cpu_hot_kernel": "persistent direction data and path storage; path generation and induction",
        },
        "routed_timing": dict(timing) if timing else None,
        "routed_utilization": dict(utilization) if utilization else None,
        "cases": cases,
        "validation": {"problems": problems, "warnings": warnings},
    }


def _fmt(value: Any, digits: int = 6) -> str:
    if value is None:
        return "N/A"
    if isinstance(value, float):
        return f"{value:.{digits}f}"
    return str(value)


def render_markdown(evidence: Mapping[str, Any]) -> str:
    provenance = evidence["provenance"]
    timing = evidence.get("routed_timing")
    utilization = evidence.get("routed_utilization")
    state = "CLAIM-READY" if evidence["claim_ready"] else "PARTIAL / NOT CLAIM-READY"
    lines = [
        "# Reproducible Claim Evidence",
        "",
        f"Status: **{state}**",
        "",
        "FPGA core latency is measured from acceptance of a complete RTL job through "
        "`result_valid`. It excludes UART, USB, Python, and host scheduling.",
        "",
        "## Provenance",
        "",
        f"- Commit: `{provenance.get('git_commit') or 'unknown'}` "
        f"(dirty worktree: `{provenance.get('git_worktree_dirty')}`)",
        f"- Benchmark CPU: {provenance.get('benchmark_cpu') or 'not collected'}",
        f"- Current host CPU: {provenance.get('current_host_cpu')}",
        f"- C++ compiler: {provenance.get('cpp_compiler') or 'not collected'}",
        f"- Benchmark compiler: {provenance.get('benchmark_compiler') or 'not collected'}",
        f"- Vivado: {(timing or utilization or {}).get('tool') or 'not collected'}",
        f"- Device/top: {(timing or utilization or {}).get('device') or 'N/A'} / "
        f"{(timing or utilization or {}).get('implementation_top') or 'N/A'}",
        f"- Core/lanes/clock: `{provenance['rtl_core_top']}` / "
        f"{provenance['lanes']} / {provenance['latency_clock_hz'] / 1e6:g} MHz "
        f"({provenance['latency_clock_source']})",
        f"- Source fingerprint: `{provenance['source_snapshot']['combined_sha256']}`",
        f"- Product/mode: {provenance['option_type'].upper()} / {provenance['exercise_mode']}",
        "",
        "## Routed implementation",
        "",
    ]
    if timing:
        lines.extend(
            [
                f"- WNS: {_fmt(timing['wns_ns'], 3)} ns",
                f"- TNS: {_fmt(timing['tns_ns'], 3)} ns",
                f"- Setup failing endpoints: {timing['setup_failing_endpoints']}",
            ]
        )
    else:
        lines.append("- Timing report: not collected")
    if utilization:
        lines.extend(
            [
                f"- Slice LUTs: {utilization['slice_luts']['used']} "
                f"({utilization['slice_luts']['percent']:.2f}%)",
                f"- Slice registers: {utilization['slice_registers']['used']} "
                f"({utilization['slice_registers']['percent']:.2f}%)",
                f"- DSPs: {utilization['dsps']['used']} ({utilization['dsps']['percent']:.2f}%)",
                f"- Block RAM tiles: {utilization['block_ram_tiles']['used']} "
                f"({utilization['block_ram_tiles']['percent']:.2f}%)",
            ]
        )
    else:
        lines.append("- Utilization report: not collected")

    lines.extend(
        [
            "",
            "## Canonical workloads",
            "",
            "| Workload | Raw Q16.16 | C++/RTL | Core cycles | Core latency (ms) | CRR error (bp spot) |",
            "|---|---:|---|---:|---:|---:|",
        ]
    )
    for row in evidence["cases"]:
        workload = row["workload"]
        xsim = row.get("rtl_xsim_four_lane")
        cpp = row.get("cpp_rtl_exact")
        parity = row.get("cpp_rtl_parity")
        reference = row.get("financial_reference")
        raw = cpp["price_raw_q16_16"] if cpp else (xsim or {}).get("price_raw_q16_16")
        parity_text = "bit-exact" if parity and parity["bit_exact"] else "not collected"
        lines.append(
            f"| {workload['paths']}×{workload['steps']} multi PUT | {_fmt(raw, 0)} | "
            f"{parity_text} | {_fmt((xsim or {}).get('core_cycles'), 0)} | "
            f"{_fmt(((xsim or {}).get('core_latency_seconds') or 0) * 1e3 if xsim else None, 5)} | "
            f"{_fmt((reference or {}).get('signed_error_bps_of_spot'), 4)} |"
        )

    lines.extend(
        [
            "",
            "## Explicit CPU/FPGA timing-boundary ratios",
            "",
            "Each ratio below is `CPU mean real time / FPGA core time`. It applies only to "
            "the named CPU boundary and workload; it is not a general accelerator claim.",
            "",
            "| Workload | CPU boundary | CPU mean (ms) | FPGA core (ms) | Boundary-specific ratio | Repetitions |",
            "|---|---|---:|---:|---:|---:|",
        ]
    )
    for row in evidence["cases"]:
        xsim = row.get("rtl_xsim_four_lane")
        if xsim is None:
            continue
        for boundary, cpu in (row.get("cpu_boundaries") or {}).items():
            lines.append(
                f"| {row['workload']['paths']}×{row['workload']['steps']} | "
                f"{boundary.replace('_', ' ')} | {cpu['mean_real_seconds'] * 1e3:.6f} | "
                f"{xsim['core_latency_seconds'] * 1e3:.6f} | "
                f"{cpu['cpu_mean_real_over_fpga_core_ratio']:.3f}× | {cpu['repetitions']} |"
            )
    if not any(row.get("cpu_boundaries") for row in evidence["cases"]):
        lines.append("| N/A | CPU benchmark skipped | N/A | N/A | N/A | N/A |")

    validation = evidence["validation"]
    lines.extend(["", "## Validation", ""])
    if not validation["problems"] and not validation["warnings"]:
        lines.append("All required parity, cycle, benchmark, and routed-report checks passed.")
    else:
        for problem in validation["problems"]:
            lines.append(f"- Problem: {problem}")
        for warning in validation["warnings"]:
            lines.append(f"- Warning: {warning}")
    lines.extend(
        [
            "",
            "The CRR comparison is a financial reference for the single canonical 1,024×4 "
            "workload, not a global accuracy guarantee.",
            "",
        ]
    )
    return "\n".join(lines)


def _public_evidence_value(value: Any, repo: Path | None) -> Any:
    """Remove machine identity and make recorded paths portable."""
    if isinstance(value, Mapping):
        return {
            key: _public_evidence_value(item, repo)
            for key, item in value.items()
            if key not in {"host", "host_name"}
        }
    if isinstance(value, list):
        return [_public_evidence_value(item, repo) for item in value]
    if isinstance(value, tuple):
        return [_public_evidence_value(item, repo) for item in value]
    if not isinstance(value, str):
        return value

    rendered = value
    prefixes: list[tuple[Path, str]] = []
    if repo is not None:
        prefixes.append((repo.resolve(), "."))
    prefixes.append((Path.home().resolve(), "~"))
    for prefix, replacement in prefixes:
        for spelling in {os.fspath(prefix), prefix.as_posix()}:
            rendered = rendered.replace(spelling, replacement)
    return rendered.replace("\\", "/")


def write_outputs(
    output_dir: Path,
    evidence: Mapping[str, Any],
    *,
    repo: Path | None = None,
) -> None:
    evidence = _public_evidence_value(evidence, repo)
    output_dir.mkdir(parents=True, exist_ok=True)
    json_path = output_dir / "claim_evidence.json"
    csv_path = output_dir / "claim_evidence.csv"
    markdown_path = output_dir / "claim_evidence.md"
    json_path.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    markdown_path.write_text(render_markdown(evidence), encoding="utf-8")

    columns = [
        "case_id",
        "paths",
        "steps",
        "exercise_mode",
        "option_type",
        "cpp_price_raw_q16_16",
        "xsim_price_raw_q16_16",
        "bit_exact",
        "core_cycles",
        "clock_hz",
        "core_latency_seconds",
        "cpu_end_to_end_mean_seconds",
        "cpu_end_to_end_over_fpga_core_ratio",
        "cpu_pricing_core_mean_seconds",
        "cpu_pricing_core_over_fpga_core_ratio",
        "cpu_hot_kernel_mean_seconds",
        "cpu_hot_kernel_over_fpga_core_ratio",
        "crr_price",
        "signed_error_bps_of_spot",
        "wns_ns",
        "tns_ns",
        "setup_failing_endpoints",
    ]
    with csv_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns)
        writer.writeheader()
        for case in evidence["cases"]:
            cpp = case.get("cpp_rtl_exact") or {}
            xsim = case.get("rtl_xsim_four_lane") or {}
            parity = case.get("cpp_rtl_parity") or {}
            cpu = case.get("cpu_boundaries") or {}
            reference = case.get("financial_reference") or {}
            timing = evidence.get("routed_timing") or {}
            writer.writerow(
                {
                    "case_id": case["case_id"],
                    "paths": case["workload"]["paths"],
                    "steps": case["workload"]["steps"],
                    "exercise_mode": evidence["provenance"]["exercise_mode"],
                    "option_type": evidence["provenance"]["option_type"],
                    "cpp_price_raw_q16_16": cpp.get("price_raw_q16_16"),
                    "xsim_price_raw_q16_16": xsim.get("price_raw_q16_16"),
                    "bit_exact": parity.get("bit_exact"),
                    "core_cycles": xsim.get("core_cycles"),
                    "clock_hz": evidence["provenance"]["latency_clock_hz"],
                    "core_latency_seconds": xsim.get("core_latency_seconds"),
                    "cpu_end_to_end_mean_seconds": (cpu.get("end_to_end") or {}).get(
                        "mean_real_seconds"
                    ),
                    "cpu_end_to_end_over_fpga_core_ratio": (
                        cpu.get("end_to_end") or {}
                    ).get("cpu_mean_real_over_fpga_core_ratio"),
                    "cpu_pricing_core_mean_seconds": (cpu.get("pricing_core") or {}).get(
                        "mean_real_seconds"
                    ),
                    "cpu_pricing_core_over_fpga_core_ratio": (
                        cpu.get("pricing_core") or {}
                    ).get("cpu_mean_real_over_fpga_core_ratio"),
                    "cpu_hot_kernel_mean_seconds": (cpu.get("hot_kernel") or {}).get(
                        "mean_real_seconds"
                    ),
                    "cpu_hot_kernel_over_fpga_core_ratio": (
                        cpu.get("hot_kernel") or {}
                    ).get("cpu_mean_real_over_fpga_core_ratio"),
                    "crr_price": reference.get("price"),
                    "signed_error_bps_of_spot": reference.get("signed_error_bps_of_spot"),
                    "wns_ns": timing.get("wns_ns"),
                    "tns_ns": timing.get("tns_ns"),
                    "setup_failing_endpoints": timing.get("setup_failing_endpoints"),
                }
            )


def _path_or_none(value: str | None) -> Path | None:
    return Path(value).resolve() if value else None


def _case_paths(path4: str | None, path12: str | None) -> dict[str, Path]:
    values = (_path_or_none(path4), _path_or_none(path12))
    return {
        case.case_id: path
        for case, path in zip(CANONICAL_CASES, values)
        if path is not None
    }


def create_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Generate boundary-explicit FPGA pricing claim evidence"
    )
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output-dir", type=Path, default=Path("results/claims"))
    parser.add_argument("--work-dir", type=Path, default=Path(".tmp/claim-evidence"))
    parser.add_argument("--cpp-mode", choices=("run", "parse", "skip"), default="run")
    parser.add_argument("--xsim-mode", choices=("run", "parse", "skip"), default="skip")
    parser.add_argument(
        "--benchmark-mode", choices=("run", "parse", "skip"), default="skip"
    )
    parser.add_argument(
        "--vivado-mode", choices=("run", "parse", "skip"), default="skip"
    )
    parser.add_argument("--cpp-log-4")
    parser.add_argument("--cpp-log-12")
    parser.add_argument("--xsim-log-4")
    parser.add_argument("--xsim-log-12")
    parser.add_argument("--benchmark-json")
    parser.add_argument("--cpp-exe", type=Path)
    parser.add_argument("--cxx", default=os.environ.get("CXX", "g++"))
    parser.add_argument(
        "--compiler-provenance",
        help="compiler identity for parsed or externally built C++/benchmark artifacts",
    )
    parser.add_argument(
        "--cpu-provenance",
        help="CPU model explicitly associated with parsed Google Benchmark artifacts",
    )
    parser.add_argument(
        "--parsed-source-fingerprint",
        help="combined source SHA-256 explicitly associated with parsed artifacts",
    )
    parser.add_argument(
        "--parsed-git-commit",
        help="git commit explicitly associated with parsed artifacts",
    )
    parser.add_argument(
        "--timing-report",
        type=Path,
        default=Path("vivado_build/arty_a7_100_multi_lanes4_10ns/timing_post_route.rpt"),
    )
    parser.add_argument(
        "--utilization-report",
        type=Path,
        default=Path("vivado_build/arty_a7_100_multi_lanes4_10ns/utilization.rpt"),
    )
    parser.add_argument(
        "--clock-hz",
        type=float,
        default=DEFAULT_CLOCK_HZ,
        help="configured expectation; claim latency is derived from routed sys_clk when available",
    )
    parser.add_argument("--reference-steps", type=int, default=4096)
    parser.add_argument("--command-timeout", type=int, default=3600)
    parser.add_argument(
        "--require-complete",
        action="store_true",
        help="return nonzero unless every claim-grade check and 15-repetition benchmark passes",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = create_parser().parse_args(argv)
    repo = args.repo.resolve()
    output_dir = args.output_dir if args.output_dir.is_absolute() else repo / args.output_dir
    work_dir = args.work_dir if args.work_dir.is_absolute() else repo / args.work_dir
    raw_dir = work_dir / "raw"
    raw_dir.mkdir(parents=True, exist_ok=True)
    # Some restricted Windows shells inherit an inaccessible system TEMP.
    # Keep compiler and simulator scratch files inside the ignored work tree.
    for variable in ('TEMP', 'TMP', 'TMPDIR'):
        os.environ[variable] = os.fspath(work_dir)
    if not math.isfinite(args.clock_hz) or args.clock_hz <= 0:
        raise EvidenceError("--clock-hz must be positive and finite")
    if args.reference_steps <= 0:
        raise EvidenceError("--reference-steps must be positive")

    snapshot_before = source_snapshot(repo)

    cpp: dict[str, Any] = {}
    xsim: dict[str, Any] = {}
    benchmark: dict[str, Any] | None = None
    cpp_build_command: list[str] | None = None
    benchmark_commands: list[list[str]] | None = None
    vivado_run_info: dict[str, Any] | None = None
    skipped: list[str] = []

    selected_compiler_version = _tool_version([args.cxx, "--version"], repo)
    cpp_compiler_version: str | None = None
    benchmark_compiler_version: str | None = None
    if args.cpp_mode == "run":
        executable = args.cpp_exe
        if executable is None:
            executable, cpp_build_command = build_cpp_oracle(repo, work_dir / "cpp", args.cxx)
            cpp_compiler_version = selected_compiler_version
        else:
            executable = executable.resolve()
            cpp_compiler_version = args.compiler_provenance
        cpp = collect_cpp_runs(repo, executable, raw_dir, args.command_timeout)
    elif args.cpp_mode == "parse":
        cpp = collect_cpp_logs(_case_paths(args.cpp_log_4, args.cpp_log_12), repo)
        cpp_compiler_version = args.compiler_provenance
    else:
        skipped.append("cpp")

    if args.xsim_mode == "run":
        xsim = collect_xsim_runs(repo, raw_dir, args.command_timeout)
    elif args.xsim_mode == "parse":
        xsim = collect_xsim_logs(_case_paths(args.xsim_log_4, args.xsim_log_12), repo)
    else:
        skipped.append("xsim")

    if args.benchmark_mode == "run":
        benchmark, benchmark_commands = build_and_run_benchmark(
            repo, work_dir / "benchmark", raw_dir, args.command_timeout, args.cxx
        )
        benchmark_compiler_version = selected_compiler_version
    elif args.benchmark_mode == "parse":
        if not args.benchmark_json:
            raise EvidenceError("--benchmark-json is required with --benchmark-mode parse")
        benchmark = collect_benchmark_file(Path(args.benchmark_json).resolve(), repo)
        benchmark_compiler_version = args.compiler_provenance
    else:
        skipped.append("google_benchmark")

    timing_path = args.timing_report if args.timing_report.is_absolute() else repo / args.timing_report
    util_path = (
        args.utilization_report
        if args.utilization_report.is_absolute()
        else repo / args.utilization_report
    )
    if args.vivado_mode == "run":
        vivado_run_info = run_vivado_route(repo, args.command_timeout)
    elif args.vivado_mode == "skip":
        skipped.append("vivado")

    parse_vivado = args.vivado_mode in ("run", "parse")
    timing = (
        parse_timing_report(_read_text(timing_path))
        if parse_vivado and timing_path.is_file()
        else None
    )
    utilization = (
        parse_utilization_report(_read_text(util_path))
        if parse_vivado and util_path.is_file()
        else None
    )
    artifact_fingerprints: dict[str, Any] = {}
    artifact_fingerprints["collector"] = file_fingerprint(Path(__file__), repo)
    if parse_vivado and timing_path.is_file():
        artifact_fingerprints["timing_report"] = file_fingerprint(timing_path, repo)
    if parse_vivado and util_path.is_file():
        artifact_fingerprints["utilization_report"] = file_fingerprint(util_path, repo)
    if benchmark and benchmark.get("artifact_fingerprint"):
        artifact_fingerprints["google_benchmark"] = benchmark["artifact_fingerprint"]
    snapshot_after = source_snapshot(repo)

    evidence = assemble_evidence(
        repo=repo,
        cpp=cpp,
        xsim=xsim,
        benchmark=benchmark,
        timing=timing,
        utilization=utilization,
        clock_hz=args.clock_hz,
        compiler_version=cpp_compiler_version,
        cpp_build_command=cpp_build_command,
        benchmark_commands=benchmark_commands,
        reference_steps=args.reference_steps,
        skipped_sources=skipped,
        benchmark_compiler_version=benchmark_compiler_version,
        snapshots=snapshot_after,
        artifact_fingerprints=artifact_fingerprints,
        collection_modes={
            "cpp": (
                "prebuilt"
                if args.cpp_mode == "run" and args.cpp_exe is not None
                else args.cpp_mode
            ),
            "xsim": args.xsim_mode,
            "benchmark": args.benchmark_mode,
            "vivado": args.vivado_mode,
        },
        parsed_source_fingerprint=args.parsed_source_fingerprint,
        parsed_git_commit=args.parsed_git_commit,
        vivado_run=vivado_run_info,
        snapshot_before_collection=snapshot_before,
        benchmark_cpu=(
            _cpu_model() if args.benchmark_mode == "run" else args.cpu_provenance
        ),
    )
    write_outputs(output_dir, evidence, repo=repo)
    print(f"Wrote {output_dir / 'claim_evidence.json'}")
    print(f"Wrote {output_dir / 'claim_evidence.csv'}")
    print(f"Wrote {output_dir / 'claim_evidence.md'}")
    print("Status:", "CLAIM-READY" if evidence["claim_ready"] else "PARTIAL")
    print(f"Git commit: {evidence['provenance'].get('git_commit') or 'unknown'}")
    print(
        "Source fingerprint: "
        f"{evidence['provenance']['source_snapshot']['combined_sha256']}"
    )
    if evidence["validation"]["problems"]:
        for problem in evidence["validation"]["problems"]:
            print(f"  problem: {problem}")
    if evidence["validation"]["warnings"]:
        for warning in evidence["validation"]["warnings"]:
            print(f"  warning: {warning}")
    if args.require_complete and not evidence["claim_ready"]:
        return 2
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except EvidenceError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(2)
