import argparse
import os
import re
import struct
import subprocess
import time
from pathlib import Path


def float_to_q16_16(x):
    return int(round(x * (1 << 16)))


def q16_16_to_float(x):
    """Convert Q16.16 to float. Handles unsigned 32-bit representing signed values."""
    if x >= 0x8000_0000:
        x -= 0x1_0000_0000
    return x / float(1 << 16)


def load_params_file(path):
    params = {}
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            params[k.strip()] = v.strip()
    required = ["paths", "steps", "S0", "K", "r", "sigma", "T"]
    missing = [k for k in required if k not in params]
    if missing:
        raise ValueError(f"Missing keys in params file: {missing}")
    opt = params.get("option_type", "0")
    return {
        "paths": int(params["paths"]),
        "steps": int(params["steps"]),
        "S0": float(params["S0"]),
        "K": float(params["K"]),
        "r": float(params["r"]),
        "sigma": float(params["sigma"]),
        "T": float(params["T"]),
        "option_type": int(opt) & 1,  # 0=CALL, 1=PUT
    }


def fetch_live_params(symbol, strike, r, maturity_years):
    try:
        import yfinance as yf
    except ImportError as exc:
        raise RuntimeError("yfinance is required for live mode. Install with: pip install yfinance") from exc

    ticker = yf.Ticker(symbol)
    hist = ticker.history(period="1y", interval="1d")
    if hist.empty:
        raise RuntimeError(f"No market data returned for symbol: {symbol}")

    closes = hist["Close"].dropna()
    if closes.empty:
        raise RuntimeError(f"No close prices available for symbol: {symbol}")

    s0 = float(closes.iloc[-1])
    returns = closes.pct_change().dropna()
    sigma = float(returns.std() * (252.0 ** 0.5))
    k = s0 if strike is None else float(strike)

    return {
        "paths": 10000,
        "steps": 50,
        "S0": s0,
        "K": k,
        "r": float(r),
        "sigma": sigma,
        "T": float(maturity_years),
        "option_type": 0,  # CALL by default
    }


def send_params_uart(params, port, baud, timeout_s):
    try:
        import serial
    except ImportError as exc:
        raise RuntimeError("pyserial is required for FPGA UART target. Install with: pip install pyserial") from exc

    opt = params.get("option_type", 0)
    payload = [
        int(params["paths"]),
        int(params["steps"]),
        float_to_q16_16(params["S0"]),
        float_to_q16_16(params["K"]),
        float_to_q16_16(params["r"]),
        float_to_q16_16(params["sigma"]),
        float_to_q16_16(params["T"]),
        int(opt) & 1,  # 0=CALL, 1=PUT
    ]

    t0 = time.perf_counter()
    with serial.Serial(port, baud, timeout=timeout_s) as ser:
        for word in payload:
            ser.write(struct.pack("<i", int(word)))

        echoes = []
        for _ in range(8):
            raw = ser.read(4)
            if len(raw) != 4:
                raise TimeoutError("Timed out while waiting for UART echo words.")
            echoes.append(struct.unpack("<i", raw)[0])

        extra = []
        deadline = time.perf_counter() + timeout_s
        while time.perf_counter() < deadline and len(extra) < 5:
            if ser.in_waiting >= 4:
                extra.append(struct.unpack("<I", ser.read(4))[0])
            else:
                time.sleep(0.01)

    elapsed = time.perf_counter() - t0
    return echoes, extra, elapsed


def build_cpu_baseline(baseline_dir, use_boost, boost_include):
    cmd = ["g++", "-std=c++17"]
    if use_boost:
        cmd.append("-DUSE_BOOST_SOBOL")
    if boost_include:
        cmd.append(f"-I{boost_include}")
    cmd += ["main.cpp", "pricing.cpp", "linalg.cpp", "sobol_wrapper.cpp", "utils.cpp", "-o", "fixed_baseline"]
    subprocess.run(cmd, cwd=baseline_dir, check=True)


def run_cpu_baseline(params, baseline_dir):
    exe_path = Path(baseline_dir) / "fixed_baseline.exe"
    if not exe_path.exists():
        exe_path = Path(baseline_dir) / "fixed_baseline"
    exe = str(exe_path)
    cmd = [
        exe,
        "--paths", str(int(params["paths"])),
        "--steps", str(int(params["steps"])),
        "--S0", str(params["S0"]),
        "--K", str(params["K"]),
        "--r", str(params["r"]),
        "--sigma", str(params["sigma"]),
        "--T", str(params["T"]),
    ]
    proc = subprocess.run(cmd, cwd=baseline_dir, check=True, capture_output=True, text=True)
    out = (proc.stdout or "") + (proc.stderr or "")
    price_match = re.search(r"Estimated Option Price \(double\):\s*([0-9eE\+\-\.]+)", out)
    time_match = re.search(r"Elapsed Time:\s*([0-9eE\+\-\.]+)\s*seconds", out)
    price = float(price_match.group(1)) if price_match else None
    elapsed = float(time_match.group(1)) if time_match else None
    return out, price, elapsed


def print_params(params):
    opt_label = "PUT" if params.get("option_type", 0) else "CALL"
    print("Parameters:")
    print(f"  paths={params['paths']} steps={params['steps']} S0={params['S0']:.6f} K={params['K']:.6f}")
    print(f"  r={params['r']:.6f} sigma={params['sigma']:.6f} T={params['T']:.6f} option_type={opt_label}")


def main():
    parser = argparse.ArgumentParser(description="CPU/FPGA benchmark, live runner, and convergence sweep")
    parser.add_argument("--mode", choices=["benchmark", "live", "sweep"], required=True)
    parser.add_argument("--target", choices=["cpu", "fpga", "both"], required=True)
    parser.add_argument("--param-file", default="", help="Benchmark mode input file (key=value)")
    parser.add_argument("--symbol", default="SPY", help="Live mode symbol for Yahoo Finance")
    parser.add_argument("--strike", type=float, default=None, help="Live mode strike; default is ATM")
    parser.add_argument("--r", type=float, default=0.05, help="Risk-free rate for live mode")
    parser.add_argument("--maturity", type=float, default=1.0, help="Maturity in years for live mode")
    parser.add_argument("--sweep-n", default="", help="Comma-separated N values for sweep mode (default: 64,128,256,512,1024,2048,4096)")
    parser.add_argument("--port", default="COM4", help="UART serial port")
    parser.add_argument("--baud", type=int, default=115200, help="UART baud rate")
    parser.add_argument("--timeout", type=float, default=2.0, help="UART read timeout seconds")
    parser.add_argument("--fpga-fclk-hz", type=float, default=0.0, help="FPGA core clock for cycle->time conversion")
    parser.add_argument("--build-cpu", action="store_true", help="Build C++ baseline before run")
    parser.add_argument("--use-boost", action="store_true", help="Build C++ baseline with Boost Sobol")
    parser.add_argument("--boost-include", default="", help="Boost include path if needed")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[1]
    baseline_dir = repo_root / "baseline" / "cpp_fixed"

    if args.mode in ("benchmark", "sweep"):
        if not args.param_file:
            raise ValueError("--param-file is required for benchmark/sweep mode.")
        params = load_params_file(args.param_file)
    else:
        params = fetch_live_params(args.symbol, args.strike, args.r, args.maturity)

    print_params(params)

    if args.mode == "live":
        from datetime import datetime
        snapshot = {
            "ticker": args.symbol,
            "date": datetime.now().isoformat(),
            "params": params.copy(),
        }
        print("\n[LIVE] Input snapshot (for repeatability):")
        print(f"  ticker={snapshot['ticker']} date={snapshot['date']}")
        for k, v in snapshot["params"].items():
            print(f"  {k}={v}")

    if args.build_cpu and args.target in ("cpu", "both"):
        build_cpu_baseline(str(baseline_dir), args.use_boost, args.boost_include)

    cpu_price = None
    cpu_elapsed = None
    fpga_price = None
    fpga_cycles = None
    fpga_compute_s = None

    if args.target in ("cpu", "both"):
        out, price, elapsed = run_cpu_baseline(params, str(baseline_dir))
        cpu_price = price
        cpu_elapsed = elapsed
        print("\n[CPU] Output")
        print(out)
        if price is not None and elapsed is not None:
            print(f"[CPU] price={price:.8f} runtime_s={elapsed:.6f}")

    if args.target in ("fpga", "both"):
        echoes, extra, uart_elapsed = send_params_uart(params, args.port, args.baud, args.timeout)
        print("\n[FPGA] UART echo")
        for i, val in enumerate(echoes):
            decoded = q16_16_to_float(val) if i >= 2 else val
            print(f"  echo[{i}] raw=0x{val & 0xFFFFFFFF:08X} decoded={decoded}")
        if len(extra) >= 4 and extra[0] in (0xABCD0001, 0xABCD0002):
            price_raw = int(extra[1])
            fpga_cycles = (int(extra[3]) << 32) | int(extra[2])
            fpga_price = q16_16_to_float(price_raw)
            print(f"[FPGA] result_marker=0x{extra[0]:08X}")
            print(f"[FPGA] price_raw=0x{price_raw:08X} price={fpga_price:.8f}")
            print(f"[FPGA] core_cycles={fpga_cycles}")
            if args.fpga_fclk_hz > 0:
                fpga_compute_s = fpga_cycles / args.fpga_fclk_hz
                print(f"[FPGA] compute_time_s={fpga_compute_s:.9f}")
            else:
                print("[FPGA] compute_time_s = core_cycles / fclk_hz (use --fpga-fclk-hz)")
            if len(extra) >= 5:
                status = int(extra[4])
                flags = []
                if status & 1:
                    flags.append("TIMEOUT")
                if status & 2:
                    flags.append("SINGULAR_REGRESSION")
                flag_str = ", ".join(flags) if flags else "OK"
                print(f"[FPGA] status=0x{status:08X} ({flag_str})")
        elif len(extra) > 0:
            print(f"[FPGA] extra_words={extra} (unexpected format)")
        else:
            print("[FPGA] no result payload received.")
        print(f"[FPGA] uart_roundtrip_s={uart_elapsed:.6f}")

    # Sweep mode: run at increasing N and print convergence table
    if args.mode == "sweep":
        sweep_ns = [64, 128, 256, 512, 1024, 2048, 4096]
        if args.sweep_n:
            sweep_ns = [int(x.strip()) for x in args.sweep_n.split(",")]

        rows = []
        prev_price = None
        print("\n" + "=" * 60)
        print("CONVERGENCE SWEEP")
        print("=" * 60)
        for n in sweep_ns:
            params_n = dict(params)
            params_n["paths"] = n
            price, elapsed = None, None
            if args.target in ("cpu", "both"):
                try:
                    _, price, elapsed = run_cpu_baseline(params_n, str(baseline_dir))
                except Exception as e:
                    print(f"  N={n}: CPU error: {e}")
                    continue
            if args.target in ("fpga", "both"):
                try:
                    _, extra, uart_elapsed = send_params_uart(params_n, args.port, args.baud, args.timeout)
                    if len(extra) >= 4 and extra[0] in (0xABCD0001, 0xABCD0002):
                        price = q16_16_to_float(int(extra[1]))
                        elapsed = uart_elapsed
                except Exception as e:
                    print(f"  N={n}: FPGA error: {e}")
                    continue
            if price is not None:
                delta = abs(price - prev_price) if prev_price is not None else float("inf")
                rows.append((n, price, delta, elapsed))
                prev_price = price

        print(f"\n{'N':>6}  {'Price':>12}  {'Delta':>12}  {'Time(s)':>10}")
        print("-" * 48)
        for n, p, d, t in rows:
            d_str = f"{d:.6f}" if d != float("inf") else "---"
            t_str = f"{t:.4f}" if t is not None else "---"
            print(f"{n:6d}  {p:12.6f}  {d_str:>12}  {t_str:>10}")
        print("=" * 60)
        return

    # Benchmark comparison report (when both targets run)
    if args.mode == "benchmark" and args.target == "both" and cpu_price is not None and fpga_price is not None:
        print("\n" + "=" * 50)
        print("BENCHMARK COMPARISON")
        print("=" * 50)
        print(f"  CPU price:  {cpu_price:.8f}")
        print(f"  FPGA price: {fpga_price:.8f}")
        delta = abs(fpga_price - cpu_price)
        rel_err = delta / cpu_price if cpu_price != 0 else float("inf")
        print(f"  Price delta: {delta:.8f} (rel_err={rel_err*100:.4f}%)")
        if cpu_elapsed is not None:
            print(f"  CPU wall time: {cpu_elapsed:.6f} s")
        if fpga_compute_s is not None and cpu_elapsed is not None and cpu_elapsed > 0:
            speedup = cpu_elapsed / fpga_compute_s
            print(f"  FPGA compute time: {fpga_compute_s:.9f} s")
            print(f"  Speedup (CPU_wall / FPGA_compute): {speedup:.2f}x")
        elif fpga_cycles is not None:
            print(f"  FPGA core_cycles: {fpga_cycles} (use --fpga-fclk-hz for speedup)")
        print("=" * 50)


if __name__ == "__main__":
    main()
