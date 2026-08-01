"""Strict host interface for the fixed-point QMC-LSM CPU and FPGA models.

UART remains eight request words, eight echoes, then exactly four result words:
marker, price/error, cycle-low, and cycle-high. Exercise mode and lane count are
build-time bitstream properties; their CLI values are explicit host assertions.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime
import math
import os
import re
import struct
import subprocess
import time
from pathlib import Path
from typing import Mapping, Sequence

Q16_SCALE = 1 << 16
INT32_MIN, INT32_MAX = -(1 << 31), (1 << 31) - 1
RESULT_MARKER = 0xABCD0001
FRAMING_DIAGNOSTIC_PREFIX = 0xBADF
CORE_TIMEOUT = 0xDEAD0001
INVALID_WORKLOAD = 0xDEAD0002
FPGA_MAX_PATHS, FPGA_MAX_STEPS = 1024, 50


class UartProtocolError(RuntimeError):
    """A complete FPGA response violated the documented protocol."""


class FpgaCoreError(RuntimeError):
    """The FPGA returned a documented error in its price word."""

    def __init__(self, code: int, cycles: int):
        label = {CORE_TIMEOUT: "core timeout", INVALID_WORKLOAD: "invalid workload"}.get(
            code, "unknown core error"
        )
        self.code, self.cycles = code, cycles
        super().__init__(f"FPGA {label} (0x{code:08X}, cycles={cycles})")


@dataclass(frozen=True)
class CpuResult:
    output: str
    price_raw: int
    price: float
    elapsed_s: float


@dataclass(frozen=True)
class FpgaResult:
    echoes: tuple[int, ...]
    marker: int
    price_word: int
    price_raw: int
    price: float
    core_cycles: int
    transport_s: float


def float_to_q16_16(x: float) -> int:
    value = float(x)
    if not math.isfinite(value):
        raise ValueError(f"Q16.16 input must be finite, got {x!r}")
    # Match C++ std::llround: midpoint values round away from zero. The C++
    # adapter's accepted numerical interval is [-32768, 32767].
    if value < -32768.0 or value > 32767.0:
        raise ValueError(f"Q16.16 input is outside the C++ model range: {value!r}")
    scaled = value * Q16_SCALE
    raw = math.floor(scaled + 0.5) if scaled >= 0 else math.ceil(scaled - 0.5)
    if raw < INT32_MIN or raw > INT32_MAX:
        raise ValueError(f"Q16.16 input is out of range: {value!r}")
    return raw


def unsigned_to_signed32(word: int) -> int:
    word = int(word) & 0xFFFF_FFFF
    return word - 0x1_0000_0000 if word >= 0x8000_0000 else word


def q16_16_to_float(x: int) -> float:
    return unsigned_to_signed32(x) / float(Q16_SCALE)


def load_params_file(path: str | Path) -> dict[str, int | float | str]:
    parsed: dict[str, str] = {}
    with open(path, "r", encoding="utf-8") as source:
        for raw in source:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            parsed[key.strip()] = value.strip()
    required = ["paths", "steps", "S0", "K", "r", "sigma", "T"]
    missing = [key for key in required if key not in parsed]
    if missing:
        raise ValueError(f"Missing keys in params file: {missing}")
    option_type = int(parsed.get("option_type", "1"))
    if option_type not in (0, 1):
        raise ValueError("option_type must be 0 (CALL) or 1 (PUT)")
    result = {
        "paths": int(parsed["paths"]), "steps": int(parsed["steps"]),
        "S0": float(parsed["S0"]), "K": float(parsed["K"]),
        "r": float(parsed["r"]), "sigma": float(parsed["sigma"]),
        "T": float(parsed["T"]), "option_type": option_type,
    }
    if "exercise_mode" in parsed:
        mode = parsed["exercise_mode"].lower()
        if mode not in ("single", "multi"):
            raise ValueError("exercise_mode in parameter file must be single or multi")
        result["exercise_mode"] = mode
    return result


def fetch_live_params(symbol, strike, r, maturity_years):
    try:
        import yfinance as yf
    except ImportError as exc:
        raise RuntimeError("live mode requires yfinance") from exc
    history = yf.Ticker(symbol).history(period="1y", interval="1d")
    if history.empty:
        raise RuntimeError(f"No market data returned for symbol: {symbol}")
    closes = history["Close"].dropna()
    if closes.empty:
        raise RuntimeError(f"No close prices available for symbol: {symbol}")
    spot = float(closes.iloc[-1])
    volatility = float(closes.pct_change().dropna().std() * math.sqrt(252.0))
    return {
        "paths": 1024, "steps": 12, "S0": spot,
        "K": spot if strike is None else float(strike), "r": float(r),
        "sigma": volatility, "T": float(maturity_years), "option_type": 1,
    }


def validate_fpga_params(params: Mapping[str, int | float], num_lanes: int) -> None:
    """Validate the active stored-path envelope before a serial port opens."""
    paths, steps = int(params["paths"]), int(params["steps"])
    if num_lanes not in (1, 2, 4, 8):
        raise ValueError("num_lanes must be one of 1, 2, 4, or 8")
    if not 1 <= paths <= FPGA_MAX_PATHS:
        raise ValueError(f"paths must be in [1, {FPGA_MAX_PATHS}], got {paths}")
    if not 1 <= steps <= FPGA_MAX_STEPS:
        raise ValueError(f"steps must be in [1, {FPGA_MAX_STEPS}], got {steps}")
    if paths % num_lanes:
        raise ValueError(f"paths ({paths}) must be divisible by num_lanes ({num_lanes})")
    if int(params.get("option_type", 1)) not in (0, 1):
        raise ValueError("option_type must be 0 (CALL) or 1 (PUT)")
    for name in ("S0", "K", "r", "sigma", "T"):
        value = float(params[name])
        if not math.isfinite(value):
            raise ValueError(f"{name} must be finite")
        if name in ("S0", "K", "sigma", "T") and value <= 0:
            raise ValueError(f"{name} must be positive")
        try:
            float_to_q16_16(value)
        except ValueError as exc:
            raise ValueError(f"{name} is not representable as signed Q16.16") from exc


def _request_payload(params: Mapping[str, int | float]) -> tuple[int, ...]:
    return (
        int(params["paths"]), int(params["steps"]),
        float_to_q16_16(params["S0"]), float_to_q16_16(params["K"]),
        float_to_q16_16(params["r"]), float_to_q16_16(params["sigma"]),
        float_to_q16_16(params["T"]), int(params.get("option_type", 1)),
    )


def _read_exact(stream, size: int, deadline: float, clock=time.monotonic) -> bytes:
    chunks = bytearray()
    while len(chunks) < size:
        remaining = deadline - clock()
        if remaining <= 0:
            raise TimeoutError(
                f"UART deadline expired after {len(chunks)} of {size} bytes"
            )
        # The serial port is opened with a bounded read timeout. Do not assign
        # stream.timeout here: pyserial reconfigures the Windows COM handle,
        # which can disturb an FTDI transmission that has just been queued.
        chunk = stream.read(size - len(chunks))
        if chunk:
            chunks.extend(chunk)
    return bytes(chunks)


class FpgaSession:
    """A lazy persistent serial connection for one or more pricing jobs."""

    def __init__(self, port, baud=115200, timeout_s=2.0, num_lanes=4,
                 serial_factory=None, clock=time.monotonic,
                 request_word_gap_s=0.0, serial_open_settle_s=0.1,
                 sleeper=time.sleep):
        if timeout_s <= 0:
            raise ValueError("timeout_s must be positive")
        if request_word_gap_s < 0:
            raise ValueError("request_word_gap_s cannot be negative")
        if serial_open_settle_s < 0:
            raise ValueError("serial_open_settle_s cannot be negative")
        self.port, self.baud = port, int(baud)
        self.timeout_s, self.num_lanes = float(timeout_s), int(num_lanes)
        self._serial_factory, self._clock = serial_factory, clock
        self.request_word_gap_s, self._sleeper = float(request_word_gap_s), sleeper
        self.serial_open_settle_s = float(serial_open_settle_s)
        self._serial = None

    def __enter__(self):
        return self  # lazy so run_job validates before opening the port

    def __exit__(self, _type, _value, _traceback):
        self.close()

    def _open(self):
        if self._serial is not None:
            return self._serial
        factory = self._serial_factory
        if factory is None:
            try:
                import serial
            except ImportError as exc:
                raise RuntimeError("FPGA UART target requires pyserial") from exc
            factory = serial.Serial
        self._serial = factory(
            port=self.port, baudrate=self.baud, timeout=min(self.timeout_s, 0.05)
        )
        # Purge first, then leave the FTDI link idle-high before the first
        # request. On Windows, placing reset_input_buffer immediately before
        # write() makes the first USB transfer phase-sensitive on this board.
        if hasattr(self._serial, "reset_input_buffer"):
            self._serial.reset_input_buffer()
        if self.serial_open_settle_s:
            self._sleeper(self.serial_open_settle_s)
        return self._serial

    def close(self):
        if self._serial is not None:
            self._serial.close()
            self._serial = None

    def run_job(self, params: Mapping[str, int | float]) -> FpgaResult:
        validate_fpga_params(params, self.num_lanes)
        payload = _request_payload(params)
        stream = self._open()
        started = self._clock()
        deadline = started + self.timeout_s
        if self.request_word_gap_s:
            for word in payload:
                written = stream.write(struct.pack("<i", word))
                if written != 4:
                    raise UartProtocolError(
                        f"UART wrote {written} of 4 request bytes"
                    )
                if hasattr(stream, "flush"):
                    stream.flush()
                self._sleeper(self.request_word_gap_s)
        else:
            request_bytes = struct.pack("<8i", *payload)
            written = stream.write(request_bytes)
            if written != len(request_bytes):
                raise UartProtocolError(
                    f"UART wrote {written} of {len(request_bytes)} request bytes"
                )
            if hasattr(stream, "flush"):
                stream.flush()
        first_echo = _read_exact(stream, 4, deadline, self._clock)
        first_word = struct.unpack("<I", first_echo)[0]
        if first_word >> 16 == FRAMING_DIAGNOSTIC_PREFIX:
            diagnostic = struct.unpack(
                "<4I",
                first_echo + _read_exact(stream, 12, deadline, self._clock),
            )
            location = diagnostic[0] & 0x1F
            word_index = (location >> 2) & 0x7
            accepted_bytes = location & 0x3
            raise UartProtocolError(
                "FPGA UART framing diagnostic: "
                f"word={word_index} accepted_bytes={accepted_bytes} "
                f"packet={[f'0x{word:08X}' for word in diagnostic]}"
            )
        echoes = struct.unpack(
            "<8i", first_echo + _read_exact(stream, 28, deadline, self._clock)
        )
        if echoes != payload:
            raise UartProtocolError(
                f"UART echo mismatch: expected {payload!r}, received {echoes!r}"
            )
        marker, price_word, low, high = struct.unpack(
            "<4I", _read_exact(stream, 16, deadline, self._clock)
        )
        elapsed = self._clock() - started
        if marker != RESULT_MARKER:
            raise UartProtocolError(
                f"unexpected result marker 0x{marker:08X}; expected 0x{RESULT_MARKER:08X}"
            )
        cycles = (high << 32) | low
        if price_word in (CORE_TIMEOUT, INVALID_WORKLOAD):
            raise FpgaCoreError(price_word, cycles)
        price_raw = unsigned_to_signed32(price_word)
        return FpgaResult(
            tuple(echoes), marker, price_word, price_raw,
            q16_16_to_float(price_raw), cycles, elapsed
        )


def send_params_uart(params, port, baud, timeout_s, num_lanes=4):
    """Compatibility wrapper for one job; batch code should reuse FpgaSession."""
    with FpgaSession(port, baud, timeout_s, num_lanes) as session:
        result = session.run_job(params)
    packet = [result.marker, result.price_word,
              result.core_cycles & 0xFFFF_FFFF, result.core_cycles >> 32]
    return list(result.echoes), packet, result.transport_s


def build_cpu_baseline(baseline_dir, use_boost=False, boost_include="", runner=subprocess.run):
    baseline_path = Path(baseline_dir).resolve()
    compiler_temp = baseline_path.parents[1] / ".tmp" / "cpu_build"
    compiler_temp.mkdir(parents=True, exist_ok=True)
    build_env = os.environ.copy()
    build_env.update({key: str(compiler_temp) for key in ("TEMP", "TMP", "TMPDIR")})
    cmd = ["g++", "-std=c++17", "-O3", "-DNDEBUG", "-pipe"]
    if use_boost:
        cmd.append("-DUSE_BOOST_SOBOL")
    if boost_include:
        cmd.append(f"-I{boost_include}")
    cmd += ["main.cpp", "pricing.cpp", "linalg.cpp", "rtl_math.cpp",
            "sobol_wrapper.cpp", "utils.cpp", "-o", "fixed_baseline"]
    runner(cmd, cwd=str(baseline_dir), check=True, env=build_env)


def _cpu_command(params, baseline_dir, exercise_mode):
    if exercise_mode not in ("single", "multi"):
        raise ValueError("exercise_mode must be 'single' or 'multi'")
    base = Path(baseline_dir).resolve()
    executable = base / "fixed_baseline.exe"
    if not executable.exists():
        executable = base / "fixed_baseline"
    repo_root = base.resolve().parents[1]
    return [
        str(executable), "--paths", str(int(params["paths"])),
        "--steps", str(int(params["steps"])), "--S0", str(params["S0"]),
        "--K", str(params["K"]), "--r", str(params["r"]),
        "--sigma", str(params["sigma"]), "--T", str(params["T"]),
        "--option-type", str(int(params.get("option_type", 1))),
        "--exercise-mode", exercise_mode,
        "--direction-file", str(repo_root / "src" / "gen" / "direction.mem"),
        "--lut-dir", str(repo_root / "src" / "gen"),
    ]


def run_cpu_job(params, baseline_dir, exercise_mode="multi", runner=subprocess.run):
    process = runner(
        _cpu_command(params, baseline_dir, exercise_mode), cwd=str(baseline_dir),
        check=True, capture_output=True, text=True,
    )
    output = (process.stdout or "") + (process.stderr or "")
    raw = re.search(r"Estimated Option Price \(Q16\.16\):\s*(-?\d+)", output)
    price = re.search(r"Estimated Option Price \(double\):\s*([0-9eE+\-.]+)", output)
    elapsed = re.search(r"Elapsed Time:\s*([0-9eE+\-.]+)\s*seconds", output)
    if not raw or not price or not elapsed:
        raise RuntimeError("Could not parse price/raw/timing fields from C++ output")
    raw_value = int(raw.group(1))
    # Use the exact fixed-point value for parity and finite differences. The
    # human-readable C++ double is parsed only to verify the output contract.
    float(price.group(1))
    return CpuResult(output, raw_value, q16_16_to_float(raw_value), float(elapsed.group(1)))


def cpu_baseline_exists(baseline_dir):
    base = Path(baseline_dir).resolve()
    return (base / "fixed_baseline.exe").is_file() or (base / "fixed_baseline").is_file()


def run_cpu_baseline(params, baseline_dir, exercise_mode="multi"):
    """Compatibility tuple used by older callers."""
    result = run_cpu_job(params, baseline_dir, exercise_mode)
    return result.output, result.price, result.elapsed_s


def print_params(params, exercise_mode):
    option_label = "PUT" if int(params.get("option_type", 1)) else "CALL"
    print("Parameters:")
    print(f"  paths={params['paths']} steps={params['steps']} "
          f"S0={float(params['S0']):.6f} K={float(params['K']):.6f}")
    print(f"  r={float(params['r']):.6f} sigma={float(params['sigma']):.6f} "
          f"T={float(params['T']):.6f} option_type={option_label} "
          f"exercise_mode={exercise_mode}")


def percentile(values: Sequence[float], percentile_value: float) -> float:
    if not values:
        raise ValueError("cannot calculate a percentile of an empty sequence")
    ordered = sorted(float(value) for value in values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * percentile_value / 100.0
    lower, upper = math.floor(position), math.ceil(position)
    if lower == upper:
        return ordered[lower]
    fraction = position - lower
    return ordered[lower] * (1 - fraction) + ordered[upper] * fraction


def _print_fpga_result(result, fclk_hz, exercise_mode):
    print("\n[FPGA] UART echo")
    for index, value in enumerate(result.echoes):
        decoded = q16_16_to_float(value) if 2 <= index <= 6 else value
        print(f"  echo[{index}] raw=0x{value & 0xFFFFFFFF:08X} decoded={decoded}")
    print(f"[FPGA] result_marker=0x{result.marker:08X}")
    print(f"[FPGA] price_raw=0x{result.price_word:08X} "
          f"signed_raw={result.price_raw} price={result.price:.8f}")
    print(f"[FPGA] core_cycles={result.core_cycles}")
    if fclk_hz > 0:
        print(f"[FPGA] core_time_s={result.core_cycles / fclk_hz:.9f}")
    else:
        print("[FPGA] core_time_s=unavailable (set --fpga-fclk-hz)")
    print(f"[FPGA] transport_roundtrip_s={result.transport_s:.6f}")
    print(f"[FPGA] bitstream_exercise_mode={exercise_mode} (host assertion)")


def _run_sweep(args, params, baseline_dir):
    sweep_values = [64, 128, 256, 512, 1024]
    if args.sweep_n:
        sweep_values = [int(value.strip()) for value in args.sweep_n.split(",")]
    rows, previous, session = [], None, None
    try:
        if args.target in ("fpga", "both"):
            for paths in sweep_values:
                candidate = dict(params)
                candidate["paths"] = paths
                validate_fpga_params(candidate, args.num_lanes)
            session = FpgaSession(
                args.port, args.baud, args.timeout, args.num_lanes,
                request_word_gap_s=args.request_word_gap_ms / 1000.0,
                serial_open_settle_s=args.serial_open_settle_ms / 1000.0,
            )
        print("\n" + "=" * 60)
        print(f"CONVERGENCE SWEEP (exercise_mode={args.exercise_mode})")
        print("=" * 60)
        for paths in sweep_values:
            candidate = dict(params)
            candidate["paths"] = paths
            cpu = run_cpu_job(candidate, baseline_dir, args.exercise_mode) \
                if args.target in ("cpu", "both") else None
            fpga = session.run_job(candidate) if session is not None else None
            if cpu and fpga and cpu.price_raw != fpga.price_raw:
                raise RuntimeError(
                    f"C++/FPGA raw mismatch at N={paths}: "
                    f"CPU={cpu.price_raw}, FPGA={fpga.price_raw}"
                )
            price = fpga.price if fpga else cpu.price
            elapsed = fpga.transport_s if fpga else cpu.elapsed_s
            delta = abs(price - previous) if previous is not None else math.inf
            rows.append((paths, price, delta, elapsed))
            previous = price
    finally:
        if session is not None:
            session.close()
    print(f"\n{'N':>6}  {'Price':>12}  {'Delta':>12}  {'Boundary time(s)':>16}")
    print("-" * 54)
    for paths, price, delta, elapsed in rows:
        delta_text = f"{delta:.6f}" if math.isfinite(delta) else "---"
        print(f"{paths:6d}  {price:12.6f}  {delta_text:>12}  {elapsed:16.6f}")
    print("CPU rows use its reported interval; FPGA rows use UART round trip.")
    print("=" * 60)


def main():
    parser = argparse.ArgumentParser(
        description="CPU/FPGA benchmark, live runner, and convergence sweep"
    )
    parser.add_argument("--mode", choices=["benchmark", "live", "sweep"], required=True)
    parser.add_argument("--target", choices=["cpu", "fpga", "both", "virtual"],
                        required=True)
    parser.add_argument("--param-file", default="", help="key=value benchmark input")
    parser.add_argument("--symbol", default="SPY")
    parser.add_argument("--strike", type=float, default=None)
    parser.add_argument("--r", type=float, default=0.05)
    parser.add_argument("--maturity", type=float, default=1.0)
    parser.add_argument("--sweep-n", default="", help="comma-separated N values")
    parser.add_argument("--port", default="COM4")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--timeout", type=float, default=2.0)
    parser.add_argument(
        "--request-word-gap-ms", type=float, default=0.0,
        help="legacy idle time between 32-bit request words",
    )
    parser.add_argument(
        "--serial-open-settle-ms", type=float, default=100.0,
        help="one-time delay after opening and clearing the serial port",
    )
    parser.add_argument("--fpga-fclk-hz", type=float, default=105_263_158.0)
    parser.add_argument("--num-lanes", type=int, default=4,
                        help="lane count compiled into the physical/virtual bitstream")
    parser.add_argument("--exercise-mode", choices=("single", "multi"), default=None,
                        help="schedule compiled into the bitstream and passed to C++; "
                             "defaults to the parameter file or multi")
    parser.add_argument("--fpga-repetitions", type=int, default=1,
                        help="repeat on one persistent port; use 30 for tail latency")
    parser.add_argument("--virtual-report-format",
                        choices=("verbose", "uart_shaped"), default="verbose")
    parser.add_argument("--build-cpu", action="store_true")
    parser.add_argument("--use-boost", action="store_true")
    parser.add_argument("--boost-include", default="")
    args = parser.parse_args()

    if args.fpga_repetitions < 1:
        raise ValueError("--fpga-repetitions must be at least 1")
    if args.fpga_fclk_hz < 0:
        raise ValueError("--fpga-fclk-hz cannot be negative")
    if args.request_word_gap_ms < 0:
        raise ValueError("--request-word-gap-ms cannot be negative")
    if args.serial_open_settle_ms < 0:
        raise ValueError("--serial-open-settle-ms cannot be negative")
    repo_root = Path(__file__).resolve().parents[1]
    baseline_dir = repo_root / "baseline" / "cpp_fixed"
    if args.mode in ("benchmark", "sweep"):
        if not args.param_file:
            raise ValueError("--param-file is required for benchmark/sweep mode")
        params = load_params_file(args.param_file)
    else:
        params = fetch_live_params(args.symbol, args.strike, args.r, args.maturity)
    file_mode = params.pop("exercise_mode", None)
    if args.exercise_mode and file_mode and args.exercise_mode != file_mode:
        raise ValueError(
            f"--exercise-mode {args.exercise_mode} conflicts with parameter file {file_mode}"
        )
    args.exercise_mode = args.exercise_mode or file_mode or "multi"

    if args.target == "virtual":
        if args.mode != "benchmark":
            raise ValueError("--target virtual requires --mode benchmark")
        validate_fpga_params(params, args.num_lanes)
        script = repo_root / "scripts" / "run_virtual_a7_benchmark.ps1"
        report_format = "UartShaped" if args.virtual_report_format == "uart_shaped" \
            else "Verbose"
        cmd = [
            "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
            str(script), "-ParamFile", str(Path(args.param_file).resolve()),
            "-NumLanes", str(args.num_lanes), "-FclkHz", str(args.fpga_fclk_hz),
            "-ExerciseMode", args.exercise_mode.capitalize(),
            "-ReportFormat", report_format,
        ]
        print("[VIRTUAL] " + " ".join(cmd))
        subprocess.run(cmd, cwd=str(repo_root), check=True)
        return

    if args.target in ("fpga", "both"):
        validate_fpga_params(params, args.num_lanes)
    print_params(params, args.exercise_mode)
    if args.mode == "live":
        print("\n[LIVE] Input snapshot (for repeatability):")
        print(f"  ticker={args.symbol} date={datetime.now().isoformat()}")
        for key, value in params.items():
            print(f"  {key}={value}")
    if args.target in ("cpu", "both") and (
        args.build_cpu or not cpu_baseline_exists(baseline_dir)
    ):
        build_cpu_baseline(baseline_dir, args.use_boost, args.boost_include)
    if args.mode == "sweep":
        _run_sweep(args, params, baseline_dir)
        return

    cpu_result = None
    if args.target in ("cpu", "both"):
        cpu_result = run_cpu_job(params, baseline_dir, args.exercise_mode)
        print("\n[CPU] Output")
        print(cpu_result.output)
        print(f"[CPU] price_raw={cpu_result.price_raw} price={cpu_result.price:.8f} "
              f"runtime_s={cpu_result.elapsed_s:.6f} "
              "boundary=baseline_reported_pricing_interval")

    fpga_results = []
    if args.target in ("fpga", "both"):
        with FpgaSession(
            args.port, args.baud, args.timeout, args.num_lanes,
            request_word_gap_s=args.request_word_gap_ms / 1000.0,
            serial_open_settle_s=args.serial_open_settle_ms / 1000.0,
        ) as session:
            for _ in range(args.fpga_repetitions):
                fpga_results.append(session.run_job(params))
        first = fpga_results[0]
        if any(result.price_raw != first.price_raw or
               result.core_cycles != first.core_cycles for result in fpga_results[1:]):
            raise RuntimeError("repeated FPGA jobs returned different price/cycle results")
        _print_fpga_result(first, args.fpga_fclk_hz, args.exercise_mode)
        if len(fpga_results) > 1:
            transport = [result.transport_s for result in fpga_results]
            print(f"[FPGA] repeated_runs={len(transport)} "
                  f"transport_p50_s={percentile(transport, 50):.6f} "
                  f"transport_p95_s={percentile(transport, 95):.6f} "
                  f"transport_p99_s={percentile(transport, 99):.6f}")

    if cpu_result is not None and fpga_results:
        fpga = fpga_results[0]
        print("\n" + "=" * 58)
        print(f"C++ / FPGA PARITY (exercise_mode={args.exercise_mode})")
        print("=" * 58)
        print(f"  CPU raw price:  {cpu_result.price_raw}")
        print(f"  FPGA raw price: {fpga.price_raw}")
        parity = cpu_result.price_raw == fpga.price_raw
        print(f"  Q16.16 parity:  {'MATCH' if parity else 'MISMATCH'}")
        print(f"  CPU reported interval: {cpu_result.elapsed_s:.6f} s "
              "(implementation-reported boundary)")
        if args.fpga_fclk_hz > 0:
            print(f"  FPGA core interval:     "
                  f"{fpga.core_cycles / args.fpga_fclk_hz:.9f} s "
                  "(request acceptance through result_valid; excludes UART/host)")
        print(f"  FPGA transport interval:{fpga.transport_s:.6f} s "
              "(host write through complete four-word response)")
        print("  No aggregate speedup is reported because these timing boundaries differ.")
        print("=" * 58)
        if not parity:
            raise RuntimeError(
                "C++/FPGA raw-price mismatch; confirm the bitstream exercise mode"
            )


if __name__ == "__main__":
    main()
