#!/usr/bin/env python3
"""
Numerical validation: compare FPGA simulation price vs C++ baseline.
Uses identical parameters for both. Expect <1% relative error (QMC variance + Q16.16).
"""
import re
import subprocess
import sys
from pathlib import Path


def q16_16_to_float(x):
    """Convert Q16.16 to float."""
    if x >= 0x8000_0000:
        x = x - 0x1_0000_0000  # sign-extend
    return x / float(1 << 16)


def run_cpu_baseline(paths, steps, S0, K, r, sigma, T, baseline_dir):
    """Run C++ baseline, return (price_double, price_q16_16)."""
    exe = baseline_dir / "fixed_baseline.exe"
    if not exe.exists():
        exe = baseline_dir / "fixed_baseline"
    if not exe.exists():
        raise FileNotFoundError(f"C++ baseline not built. Run: cd {baseline_dir} && g++ -std=c++17 main.cpp pricing.cpp linalg.cpp sobol_wrapper.cpp utils.cpp -o fixed_baseline")

    cmd = [str(exe), "--paths", str(paths), "--steps", str(steps),
           "--S0", str(S0), "--K", str(K), "--r", str(r),
           "--sigma", str(sigma), "--T", str(T)]
    proc = subprocess.run(cmd, cwd=baseline_dir, capture_output=True, text=True, check=True, timeout=60)
    out = proc.stdout + proc.stderr

    price_d = None
    price_q = None
    m_d = re.search(r"Estimated Option Price \(double\):\s*([0-9eE\+\-\.]+)", out)
    m_q = re.search(r"Estimated Option Price \(Q16\.16\):\s*(-?[0-9]+)", out)
    if m_d:
        price_d = float(m_d.group(1))
    if m_q:
        price_q = int(m_q.group(1))

    return price_d, price_q


def run_fpga_sim(paths, steps, S0, K, r, sigma, T, repo_root):
    """
    Run FPGA simulation (xvlog, xelab, xsim) and parse price from output.
    Params must match TB's run_one_batch (paths=64, steps=12, etc.).
    """
    script = repo_root / "scripts" / "run_tb_top_uart_safe.ps1"
    if not script.exists():
        raise FileNotFoundError(f"run_tb_top_uart_safe.ps1 not found at {script}")

    cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
           "-File", str(script), "-ComputeMode", "-NoCleanup",
           "-XvlogTimeoutSeconds", "1800", "-XelabTimeoutSeconds", "600",
           "-XsimTimeoutSeconds", "600"]
    proc = subprocess.run(cmd, cwd=repo_root, capture_output=True, text=True, timeout=1200)
    out = proc.stdout + proc.stderr

    # TB prints: "Batch 0 price = 0xXXXXXXXX" or "Batch 0 price out of plausible range: 0xXXXXXXXX"
    m = re.search(r"Batch 0 price (?:= |out of plausible range: )0x([0-9a-fA-F]+)", out)
    if not m:
        raise RuntimeError(f"Could not parse FPGA price from output. Exit={proc.returncode}\n---\n{out[-2000:]}")
    raw = int(m.group(1), 16)
    price_fpga = q16_16_to_float(raw)
    return price_fpga, raw


def main():
    repo_root = Path(__file__).resolve().parents[1]
    baseline_dir = repo_root / "baseline" / "cpp_fixed"

    # Must match tb_top_option_pricer_uart run_one_batch exactly
    params = {
        "paths": 64,
        "steps": 12,
        "S0": 100.0,
        "K": 100.0,
        "r": 0.05,
        "sigma": 0.2,
        "T": 1.0,
    }

    print("Numerical validation: FPGA sim vs C++ baseline")
    print(f"  paths={params['paths']} steps={params['steps']} S0={params['S0']} K={params['K']}")
    print(f"  r={params['r']} sigma={params['sigma']} T={params['T']}")
    print()

    # Run C++ baseline
    print("[1/2] Running C++ baseline...")
    try:
        price_cpu_d, price_cpu_q = run_cpu_baseline(
            params["paths"], params["steps"],
            params["S0"], params["K"], params["r"], params["sigma"], params["T"],
            baseline_dir
        )
    except FileNotFoundError as e:
        print(f"ERROR: {e}")
        sys.exit(1)
    print(f"  CPU price (double): {price_cpu_d:.8f}")
    print(f"  CPU price (Q16.16): {price_cpu_q}")
    print()

    # Run FPGA sim
    print("[2/2] Running FPGA simulation (this may take several minutes)...")
    try:
        price_fpga, raw_fpga = run_fpga_sim(
            params["paths"], params["steps"],
            params["S0"], params["K"], params["r"], params["sigma"], params["T"],
            repo_root
        )
    except subprocess.TimeoutExpired:
        print("ERROR: FPGA simulation timed out (20 min)")
        sys.exit(1)
    except Exception as e:
        print(f"ERROR: {e}")
        sys.exit(1)
    print(f"  FPGA price (Q16.16 raw=0x{raw_fpga:08X}): {price_fpga:.8f}")
    print()

    # Compare
    ref = price_cpu_d
    if ref == 0:
        print("WARNING: CPU price is 0, cannot compute relative error")
        rel_err = float("inf")
    else:
        rel_err = abs(price_fpga - ref) / ref
        print(f"Relative error: |{price_fpga:.8f} - {ref:.8f}| / {ref:.8f} = {rel_err:.6f} ({rel_err*100:.4f}%)")

    threshold = 0.01
    if rel_err <= threshold:
        print(f"PASS: Relative error {rel_err*100:.4f}% <= {threshold*100}%")
        sys.exit(0)
    else:
        print(f"FAIL: Relative error {rel_err*100:.4f}% > {threshold*100}%")
        sys.exit(1)


if __name__ == "__main__":
    main()
