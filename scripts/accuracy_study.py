#!/usr/bin/env python3
"""
Financial accuracy study for the bit-exact FPGA-style pricing method.

This script compares the C++ FPGA-style hardware proxy against an in-repo
American CRR reference and writes bps-focused reports.
"""
from __future__ import annotations

import argparse
import csv
import math
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from statistics import NormalDist

from financial_reference import (
    DEFAULT_REFERENCE_STEPS,
    american_binomial_crr,
    european_black_scholes,
    single_exercise_tree,
)

REGRESSION_BETA_ABS_CAP = 4096.0


@dataclass(frozen=True)
class StudyCase:
    paths: int
    steps: int
    S0: float
    K: float
    r: float
    sigma: float
    T: float
    option_type: int


@dataclass
class MultiLsmResult:
    price: float
    summary: dict[str, object]
    step_rows: list[dict[str, object]]


def parse_float_list(text: str) -> list[float]:
    return [float(item.strip()) for item in text.split(",") if item.strip()]


def parse_int_list(text: str) -> list[int]:
    return [int(item.strip()) for item in text.split(",") if item.strip()]


def parse_option_types(text: str) -> list[int]:
    out: list[int] = []
    for item in text.split(","):
        val = item.strip().lower()
        if not val:
            continue
        if val in ("put", "p", "1"):
            out.append(1)
        elif val in ("call", "c", "0"):
            out.append(0)
        else:
            raise ValueError(f"Unknown option type: {item}")
    return out


def option_name(option_type: int) -> str:
    return "PUT" if option_type & 1 else "CALL"


def preset_values(name: str) -> dict[str, list[float] | list[int]]:
    if name == "smoke":
        return {
            "paths": [64],
            "steps": [12],
            "moneyness": [0.9, 1.0, 1.1],
            "sigma": [0.2, 0.4],
            "T": [1.0],
            "r": [0.05],
            "option_types": [1, 0],
        }
    if name == "default":
        return {
            "paths": [64, 256, 1024],
            "steps": [12, 20],
            "moneyness": [0.8, 0.9, 1.0, 1.1, 1.2],
            "sigma": [0.1, 0.2, 0.4],
            "T": [0.25, 1.0, 2.0],
            "r": [0.0, 0.05],
            "option_types": [1, 0],
        }
    raise ValueError(f"Unknown preset: {name}")


def repo_root_from_script() -> Path:
    return Path(__file__).resolve().parents[1]


def build_cpu_baseline(baseline_dir: Path, repo_root: Path) -> None:
    tmp_dir = repo_root / ".tmp"
    tmp_dir.mkdir(exist_ok=True)
    env = os.environ.copy()
    env["TEMP"] = str(tmp_dir)
    env["TMP"] = str(tmp_dir)
    env["TMPDIR"] = str(tmp_dir)
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
    subprocess.run(cmd, cwd=baseline_dir, check=True, env=env)


def find_cpu_exe(baseline_dir: Path) -> Path:
    for name in ("fixed_baseline.exe", "fixed_baseline"):
        exe = baseline_dir / name
        if exe.exists():
            return exe
    raise FileNotFoundError(
        f"C++ baseline not built. Run: cd {baseline_dir} && "
        "g++ -std=c++17 main.cpp pricing.cpp linalg.cpp rtl_math.cpp sobol_wrapper.cpp utils.cpp -o fixed_baseline"
    )


def run_fpga_style(
    case: StudyCase,
    exe: Path,
    repo_root: Path,
    baseline_dir: Path,
    exercise_mode: str,
) -> tuple[float, int]:
    cmd = [
        str(exe),
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
        str(case.option_type & 1),
        "--exercise-mode",
        exercise_mode,
        "--direction-file",
        str(repo_root / "src" / "gen" / "direction.mem"),
        "--lut-dir",
        str(repo_root / "src" / "gen"),
    ]
    proc = subprocess.run(cmd, cwd=baseline_dir, capture_output=True, text=True, check=True, timeout=240)
    out = proc.stdout + proc.stderr
    price_d = re.search(r"Estimated Option Price \(double\):\s*([0-9eE+\-.]+)", out)
    price_q = re.search(r"Estimated Option Price \(Q16\.16\):\s*(-?[0-9]+)", out)
    if not price_d or not price_q:
        raise RuntimeError(f"Could not parse C++ baseline output:\n{out}")
    return float(price_d.group(1)), int(price_q.group(1))


def load_direction_file(path: Path) -> list[int]:
    values: list[int] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            token = line.strip()
            if not token or token.startswith("#"):
                continue
            values.append(int(token, 16))
    if not values:
        raise ValueError(f"Direction file is empty: {path}")
    return values


def sobol_raw(direction: list[int], index: int, dim: int) -> int:
    gray = index ^ (index >> 1)
    value = 0
    base = dim * 32
    for bit in range(32):
        if (gray >> bit) & 1:
            value ^= direction[base + bit]
    return value


def sobol_u(direction: list[int], path_idx: int, dim: int) -> float:
    raw = sobol_raw(direction, path_idx + 1, dim)
    q16 = raw >> 16
    if q16 == 0:
        q16 = 1
    return q16 / 65536.0


def solve_3x3_double(A: list[list[float]], b: list[float]) -> list[float] | None:
    aug = [A[i][:] + [b[i]] for i in range(3)]
    for pivot in range(3):
        best = max(range(pivot, 3), key=lambda row: abs(aug[row][pivot]))
        if abs(aug[best][pivot]) < 1e-12:
            return None
        if best != pivot:
            aug[pivot], aug[best] = aug[best], aug[pivot]
        diag = aug[pivot][pivot]
        for col in range(pivot, 4):
            aug[pivot][col] /= diag
        for row in range(pivot + 1, 3):
            factor = aug[row][pivot]
            if abs(factor) < 1e-15:
                continue
            for col in range(pivot, 4):
                aug[row][col] -= factor * aug[pivot][col]

    x = [0.0, 0.0, 0.0]
    for row in range(2, -1, -1):
        value = aug[row][3]
        for col in range(row + 1, 3):
            value -= aug[row][col] * x[col]
        x[row] = value
    return x


def payoff_float(spot: float, strike: float, option_type: int) -> float:
    return max(strike - spot, 0.0) if option_type & 1 else max(spot - strike, 0.0)


def float_lsm_sobol(case: StudyCase, direction: list[int]) -> float:
    normal = NormalDist()
    dt = case.T / case.steps
    drift = (case.r - 0.5 * case.sigma * case.sigma) * dt
    vol_sqrt_dt = case.sigma * math.sqrt(dt)
    discount = math.exp(-case.r * dt)
    disc_total = math.exp(-case.r * dt * max(1, case.steps - 1))
    exercise_step = max(1, case.steps - 1)

    paths: list[list[float]] = []
    for i in range(case.paths):
        path = [case.S0]
        spot = case.S0
        for j in range(case.steps):
            u = sobol_u(direction, i, j)
            z = normal.inv_cdf(u)
            spot *= math.exp(drift + vol_sqrt_dt * z)
            path.append(spot)
        paths.append(path)

    x_vals: list[float] = []
    y_vals: list[float] = []
    continuations: list[float] = []
    for path in paths:
        terminal_payoff = max(case.K - path[-1], 0.0) if case.option_type & 1 else max(path[-1] - case.K, 0.0)
        continuation = discount * terminal_payoff
        x_norm = path[exercise_step] / case.K
        x_vals.append(x_norm)
        y_vals.append(continuation)
        continuations.append(continuation)

    sums = {
        "s0": float(case.paths),
        "s1": sum(x_vals),
        "s2": sum(x * x for x in x_vals),
        "s3": sum(x * x * x for x in x_vals),
        "s4": sum(x * x * x * x for x in x_vals),
        "sy": sum(y_vals),
        "sxy": sum(x * y for x, y in zip(x_vals, y_vals)),
        "sx2y": sum(x * x * y for x, y in zip(x_vals, y_vals)),
    }
    beta = solve_3x3_double(
        [
            [sums["s0"], sums["s1"], sums["s2"]],
            [sums["s1"], sums["s2"], sums["s3"]],
            [sums["s2"], sums["s3"], sums["s4"]],
        ],
        [sums["sy"], sums["sxy"], sums["sx2y"]],
    )
    if beta is None:
        mean_y = sums["sy"] / case.paths if case.paths else 0.0
        beta = [mean_y, 0.0, 0.0]

    sum_pv = 0.0
    for path, continuation in zip(paths, continuations):
        s_ex = path[exercise_step]
        immediate = max(case.K - s_ex, 0.0) if case.option_type & 1 else max(s_ex - case.K, 0.0)
        s_norm = s_ex / case.K
        cont_est = beta[0] + beta[1] * s_norm + beta[2] * s_norm * s_norm
        chosen = immediate if immediate >= cont_est else continuation
        sum_pv += chosen * disc_total
    return sum_pv / case.paths


def float_multi_lsm_sobol(case: StudyCase, direction: list[int]) -> float:
    return float_multi_lsm_sobol_with_health(case, direction).price


def float_multi_lsm_sobol_with_health(
    case: StudyCase,
    direction: list[int],
    case_id: int | None = None,
) -> MultiLsmResult:
    allow_early_exercise = case.option_type != 0
    normal = NormalDist()
    dt = case.T / case.steps
    drift = (case.r - 0.5 * case.sigma * case.sigma) * dt
    vol_sqrt_dt = case.sigma * math.sqrt(dt)
    discount = math.exp(-case.r * dt)

    paths: list[list[float]] = []
    for i in range(case.paths):
        path = [case.S0]
        spot = case.S0
        for j in range(case.steps):
            u = sobol_u(direction, i, j)
            z = normal.inv_cdf(u)
            spot *= math.exp(drift + vol_sqrt_dt * z)
            path.append(spot)
        paths.append(path)

    cashflows = [payoff_float(path[-1], case.K, case.option_type) for path in paths]
    step_rows: list[dict[str, object]] = []
    itm_counts: list[int] = []
    fallback_step_count = 0
    max_abs_beta = [0.0, 0.0, 0.0]
    global_min_cont_est = math.inf
    global_max_cont_est = -math.inf
    negative_cont_est_count = 0
    early_exercise_count = 0
    weighted_exercise_step_sum = 0.0
    early_exercise_steps: list[int] = []
    exercise_step_counts: dict[int, int] = {}

    for step in range(case.steps - 1, 0, -1):
        continuation = [discount * cashflow for cashflow in cashflows]
        itm_indexes = [
            idx for idx, path in enumerate(paths)
            if payoff_float(path[step], case.K, case.option_type) > 0.0
        ]
        itm_count = len(itm_indexes)
        itm_counts.append(itm_count)

        beta = [0.0, 0.0, 0.0]
        fallback_used = False
        if not allow_early_exercise:
            fallback_used = False
        elif itm_indexes:
            x_vals = [(paths[idx][step] / case.K) - 1.0 for idx in itm_indexes]
            y_vals = [continuation[idx] for idx in itm_indexes]
            if len(itm_indexes) < 3:
                fallback_used = True
                beta[0] = sum(y_vals) / len(y_vals)
            else:
                sums = {
                    "s0": float(len(itm_indexes)),
                    "s1": sum(x_vals),
                    "s2": sum(x * x for x in x_vals),
                    "s3": sum(x * x * x for x in x_vals),
                    "s4": sum(x * x * x * x for x in x_vals),
                    "sy": sum(y_vals),
                    "sxy": sum(x * y for x, y in zip(x_vals, y_vals)),
                    "sx2y": sum(x * x * y for x, y in zip(x_vals, y_vals)),
                }
                solved = solve_3x3_double(
                    [
                        [sums["s0"], sums["s1"], sums["s2"]],
                        [sums["s1"], sums["s2"], sums["s3"]],
                        [sums["s2"], sums["s3"], sums["s4"]],
                    ],
                    [sums["sy"], sums["sxy"], sums["sx2y"]],
                )
                if solved is None:
                    fallback_used = True
                    beta = [sums["sy"] / sums["s0"], 0.0, 0.0]
                else:
                    beta = solved
                    if max(abs(value) for value in beta) > REGRESSION_BETA_ABS_CAP:
                        fallback_used = True
                        beta = [sums["sy"] / sums["s0"], 0.0, 0.0]
        else:
            fallback_used = True
        if fallback_used:
            fallback_step_count += 1
        for i, value in enumerate(beta):
            max_abs_beta[i] = max(max_abs_beta[i], abs(value))

        next_cashflows: list[float] = []
        step_min_cont_est = math.inf
        step_max_cont_est = -math.inf
        step_negative_cont_est_count = 0
        step_early_exercise_count = 0
        exercised_spots: list[float] = []
        for path, cont in zip(paths, continuation):
            immediate = payoff_float(path[step], case.K, case.option_type)
            chosen = cont
            if immediate > 0.0:
                if allow_early_exercise:
                    x_basis = (path[step] / case.K) - 1.0
                    cont_est = beta[0] + beta[1] * x_basis + beta[2] * x_basis * x_basis
                else:
                    cont_est = cont
                step_min_cont_est = min(step_min_cont_est, cont_est)
                step_max_cont_est = max(step_max_cont_est, cont_est)
                global_min_cont_est = min(global_min_cont_est, cont_est)
                global_max_cont_est = max(global_max_cont_est, cont_est)
                if cont_est < 0.0:
                    negative_cont_est_count += 1
                    step_negative_cont_est_count += 1
                if allow_early_exercise and immediate >= cont_est:
                    chosen = immediate
                    early_exercise_count += 1
                    step_early_exercise_count += 1
                    weighted_exercise_step_sum += step
                    early_exercise_steps.append(step)
                    exercise_step_counts[step] = exercise_step_counts.get(step, 0) + 1
                    exercised_spots.append(path[step])
            next_cashflows.append(chosen)
        cashflows = next_cashflows
        if math.isinf(step_min_cont_est):
            step_min_cont_est = math.nan
        if math.isinf(step_max_cont_est):
            step_max_cont_est = math.nan
        step_rows.append(
            {
                "case_id": case_id if case_id is not None else "",
                "option": option_name(case.option_type),
                "paths": case.paths,
                "steps": case.steps,
                "K": case.K,
                "S0": case.S0,
                "moneyness": case.K / case.S0,
                "sigma": case.sigma,
                "T": case.T,
                "r": case.r,
                "exercise_step": step,
                "itm_count": itm_count,
                "fallback_used": fallback_used,
                "beta0": beta[0],
                "beta1": beta[1],
                "beta2": beta[2],
                "min_cont_est": step_min_cont_est,
                "max_cont_est": step_max_cont_est,
                "early_exercise_count": step_early_exercise_count,
                "avg_exercise_boundary": average(exercised_spots),
                "negative_cont_est_count": step_negative_cont_est_count,
                "early_exercise_policy": "lsm" if allow_early_exercise else "suppressed_non_dividend_call",
                "regression_basis": "centered_moneyness",
                "beta_abs_cap": REGRESSION_BETA_ABS_CAP,
            }
        )

    price = sum(discount * cashflow for cashflow in cashflows) / case.paths
    exercise_steps = max(1, case.steps - 1)
    if not itm_counts:
        itm_counts = [0]
    if math.isinf(global_min_cont_est):
        global_min_cont_est = math.nan
    if math.isinf(global_max_cont_est):
        global_max_cont_est = math.nan
    worst_exercise_step = ""
    if exercise_step_counts:
        worst_exercise_step = max(exercise_step_counts.items(), key=lambda item: item[1])[0]
    summary = {
        "min_itm_count": min(itm_counts),
        "avg_itm_count": average([float(count) for count in itm_counts]),
        "max_itm_count": max(itm_counts),
        "fallback_step_count": fallback_step_count,
        "fallback_step_ratio": fallback_step_count / exercise_steps,
        "worst_exercise_step": worst_exercise_step,
        "max_abs_beta0": max_abs_beta[0],
        "max_abs_beta1": max_abs_beta[1],
        "max_abs_beta2": max_abs_beta[2],
        "min_cont_est": global_min_cont_est,
        "max_cont_est": global_max_cont_est,
        "negative_cont_est_count": negative_cont_est_count,
        "early_exercise_count": early_exercise_count,
        "early_exercise_rate": early_exercise_count / max(1, case.paths * exercise_steps),
        "avg_exercise_step": weighted_exercise_step_sum / early_exercise_count if early_exercise_count else math.nan,
        "min_exercise_step": min(early_exercise_steps) if early_exercise_steps else math.nan,
        "max_exercise_step": max(early_exercise_steps) if early_exercise_steps else math.nan,
        "early_exercise_policy": "lsm" if allow_early_exercise else "suppressed_non_dividend_call",
        "regression_basis": "centered_moneyness",
        "beta_abs_cap": REGRESSION_BETA_ABS_CAP,
    }
    return MultiLsmResult(price=price, summary=summary, step_rows=step_rows)


def float_terminal_sobol(case: StudyCase, direction: list[int]) -> float:
    normal = NormalDist()
    dt = case.T / case.steps
    drift = (case.r - 0.5 * case.sigma * case.sigma) * dt
    vol_sqrt_dt = case.sigma * math.sqrt(dt)
    discount_total = math.exp(-case.r * case.T)

    sum_payoff = 0.0
    for i in range(case.paths):
        spot = case.S0
        for j in range(case.steps):
            u = sobol_u(direction, i, j)
            z = normal.inv_cdf(u)
            spot *= math.exp(drift + vol_sqrt_dt * z)
        if case.option_type & 1:
            sum_payoff += max(case.K - spot, 0.0)
        else:
            sum_payoff += max(spot - case.K, 0.0)
    return discount_total * sum_payoff / case.paths


def bps_of_spot(error: float, S0: float) -> float:
    return error / S0 * 10000.0 if S0 != 0.0 else math.inf


def bps_of_reference(error: float, reference: float) -> float:
    return error / reference * 10000.0 if reference != 0.0 else math.inf


def make_cases(args: argparse.Namespace) -> list[StudyCase]:
    preset = preset_values(args.preset)
    paths = parse_int_list(args.paths_list) if args.paths_list else list(preset["paths"])
    steps = parse_int_list(args.steps_list) if args.steps_list else list(preset["steps"])
    moneyness = parse_float_list(args.moneyness_list) if args.moneyness_list else list(preset["moneyness"])
    sigmas = parse_float_list(args.sigma_list) if args.sigma_list else list(preset["sigma"])
    maturities = parse_float_list(args.T_list) if args.T_list else list(preset["T"])
    rates = parse_float_list(args.r_list) if args.r_list else list(preset["r"])
    option_types = parse_option_types(args.option_types) if args.option_types else list(preset["option_types"])

    cases: list[StudyCase] = []
    for n in paths:
        for m in steps:
            for mon in moneyness:
                for sigma in sigmas:
                    for T in maturities:
                        for r in rates:
                            for opt in option_types:
                                cases.append(
                                    StudyCase(
                                        paths=n,
                                        steps=m,
                                        S0=args.S0,
                                        K=args.S0 * mon,
                                        r=r,
                                        sigma=sigma,
                                        T=T,
                                        option_type=opt,
                                    )
                                )
    return cases


def row_for_case(
    case_id: int,
    case: StudyCase,
    fpga_price: float,
    fpga_q16: int,
    exercise_mode: str,
    ref_steps: int,
    direction: list[int] | None,
    attribution: bool,
    health_metrics: bool,
    health_rows: list[dict[str, object]],
    single_fpga: tuple[float, int] | None,
    multi_fpga: tuple[float, int] | None,
    reference_cache: dict[tuple[float, float, float, float, float, int, int], float],
    single_cache: dict[tuple[float, float, float, float, float, int, int, int], float],
    bs_cache: dict[tuple[float, float, float, float, float, int], float],
    convergence_cache: dict[tuple[float, float, float, float, float, int, int], tuple[bool, float, float, float]],
) -> dict[str, object]:
    ref_key = (case.S0, case.K, case.r, case.sigma, case.T, case.option_type, ref_steps)
    single_key = (case.S0, case.K, case.r, case.sigma, case.T, case.option_type, case.steps, ref_steps)
    bs_key = (case.S0, case.K, case.r, case.sigma, case.T, case.option_type)

    if ref_key not in reference_cache:
        reference_cache[ref_key] = american_binomial_crr(
            case.S0, case.K, case.r, case.sigma, case.T, case.option_type, ref_steps
        )
    if single_key not in single_cache:
        single_cache[single_key] = single_exercise_tree(
            case.S0, case.K, case.r, case.sigma, case.T, case.option_type, case.steps, ref_steps
        )
    if bs_key not in bs_cache:
        bs_cache[bs_key] = european_black_scholes(case.S0, case.K, case.r, case.sigma, case.T, case.option_type)
    if ref_key not in convergence_cache:
        coarse_steps = max(1, ref_steps // 2)
        coarse_key = (case.S0, case.K, case.r, case.sigma, case.T, case.option_type, coarse_steps)
        if coarse_key not in reference_cache:
            reference_cache[coarse_key] = american_binomial_crr(
                case.S0, case.K, case.r, case.sigma, case.T, case.option_type, coarse_steps
            )
        coarse_price = reference_cache[coarse_key]
        fine_price = reference_cache[ref_key]
        conv_bps = abs(fine_price - coarse_price) / case.S0 * 10000.0 if case.S0 != 0.0 else math.inf
        convergence_cache[ref_key] = (
            conv_bps > 0.1,
            coarse_price,
            fine_price,
            conv_bps,
        )

    american = reference_cache[ref_key]
    single = single_cache[single_key]
    bs = bs_cache[bs_key]
    warn, coarse, fine, conv_bps = convergence_cache[ref_key]
    error = fpga_price - american
    row: dict[str, object] = {
        "option": option_name(case.option_type),
        "option_type": case.option_type,
        "exercise_mode": exercise_mode,
        "paths": case.paths,
        "steps": case.steps,
        "S0": case.S0,
        "K": case.K,
        "moneyness_K_over_S0": case.K / case.S0,
        "r": case.r,
        "sigma": case.sigma,
        "T": case.T,
        "fpga_style": fpga_price,
        "fpga_style_q16": fpga_q16,
        "american_tree": american,
        "single_exercise_tree": single,
        "european_black_scholes": bs,
        "abs_error": abs(error),
        "signed_error": error,
        "rel_error": abs(error) / american if american != 0.0 else math.inf,
        "signed_bps_spot": bps_of_spot(error, case.S0),
        "abs_bps_spot": abs(bps_of_spot(error, case.S0)),
        "signed_bps_reference": bps_of_reference(error, american),
        "abs_bps_reference": abs(bps_of_reference(error, american)),
        "ref_steps": ref_steps,
        "ref_convergence_bps_spot": conv_bps,
        "ref_convergence_warning": warn,
        "ref_coarse": coarse,
        "ref_fine": fine,
    }

    multi_health: MultiLsmResult | None = None
    if health_metrics and multi_fpga is not None:
        if direction is None:
            raise ValueError("direction data required for health metrics")
        multi_health = float_multi_lsm_sobol_with_health(case, direction, case_id=case_id)
        row.update(multi_health.summary)
        health_rows.extend(multi_health.step_rows)

    if single_fpga is not None:
        single_error = single_fpga[0] - american
        row.update(
            {
                "single_fpga_style": single_fpga[0],
                "single_fpga_style_q16": single_fpga[1],
                "single_total_bps_spot": bps_of_spot(single_error, case.S0),
                "single_abs_bps_spot": abs(bps_of_spot(single_error, case.S0)),
            }
        )
    if multi_fpga is not None:
        multi_error = multi_fpga[0] - american
        row.update(
            {
                "multi_fpga_style": multi_fpga[0],
                "multi_fpga_style_q16": multi_fpga[1],
                "multi_total_bps_spot": bps_of_spot(multi_error, case.S0),
                "multi_abs_bps_spot": abs(bps_of_spot(multi_error, case.S0)),
            }
        )
    if single_fpga is not None and multi_fpga is not None:
        row["multi_vs_single_improvement_bps_spot"] = (
            abs(bps_of_spot(single_fpga[0] - american, case.S0))
            - abs(bps_of_spot(multi_fpga[0] - american, case.S0))
        )

    if attribution:
        if direction is None:
            raise ValueError("direction data required for attribution")
        float_lsm = float_lsm_sobol(case, direction)
        terminal_sobol = float_terminal_sobol(case, direction)
        primary_float = float_lsm
        primary_qmc_error = float_lsm - single
        if exercise_mode != "single":
            if multi_health is None:
                multi_health = float_multi_lsm_sobol_with_health(case, direction, case_id=case_id if health_metrics else None)
                if health_metrics:
                    row.update(multi_health.summary)
                    health_rows.extend(multi_health.step_rows)
            primary_float = multi_health.price
            primary_qmc_error = primary_float - american
        row.update(
            {
                "float_lsm_sobol": float_lsm,
                "float_terminal_sobol": terminal_sobol,
                "single_exercise_model_error": single - american,
                "qmc_regression_error": primary_qmc_error,
                "fixed_point_error": fpga_price - primary_float,
                "total_error": error,
                "terminal_sobol_error_vs_bs": terminal_sobol - bs,
                "lsm_minus_terminal_sobol": float_lsm - terminal_sobol,
                "single_exercise_model_bps_spot": bps_of_spot(single - american, case.S0),
                "qmc_regression_bps_spot": bps_of_spot(primary_qmc_error, case.S0),
                "fixed_point_bps_spot": bps_of_spot(fpga_price - primary_float, case.S0),
                "total_bps_spot": bps_of_spot(error, case.S0),
                "terminal_sobol_bps_spot": bps_of_spot(terminal_sobol - bs, case.S0),
                "lsm_minus_terminal_sobol_bps_spot": bps_of_spot(float_lsm - terminal_sobol, case.S0),
            }
        )
        if single_fpga is not None:
            single_fixed = single_fpga[0] - float_lsm
            row.update(
                {
                    "single_qmc_regression_error": float_lsm - single,
                    "single_fixed_point_error": single_fixed,
                    "single_total_error": single_fpga[0] - american,
                    "single_qmc_regression_bps_spot": bps_of_spot(float_lsm - single, case.S0),
                    "single_fixed_point_bps_spot": bps_of_spot(single_fixed, case.S0),
                }
            )
        if multi_fpga is not None:
            if multi_health is None:
                multi_health = float_multi_lsm_sobol_with_health(case, direction, case_id=case_id if health_metrics else None)
                if health_metrics:
                    row.update(multi_health.summary)
                    health_rows.extend(multi_health.step_rows)
            float_multi = primary_float if exercise_mode != "single" else multi_health.price
            multi_fixed = multi_fpga[0] - float_multi
            row.update(
                {
                    "float_multi_lsm_sobol": float_multi,
                    "multi_qmc_regression_error": float_multi - american,
                    "multi_fixed_point_error": multi_fixed,
                    "multi_total_error": multi_fpga[0] - american,
                    "multi_qmc_regression_bps_spot": bps_of_spot(float_multi - american, case.S0),
                    "multi_fixed_point_bps_spot": bps_of_spot(multi_fixed, case.S0),
                }
            )
    return row


def write_csv(rows: list[dict[str, object]], path: Path) -> None:
    fieldnames: list[str] = []
    for row in rows:
        for key in row:
            if key not in fieldnames:
                fieldnames.append(key)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def fmt(value: object, digits: int = 6) -> str:
    if isinstance(value, float):
        if math.isinf(value):
            return "inf"
        return f"{value:.{digits}f}"
    return str(value)


def average(values: list[float]) -> float:
    return sum(values) / len(values) if values else math.nan


def row_floats(rows: list[dict[str, object]], key: str, absolute: bool = False) -> list[float]:
    values: list[float] = []
    for row in rows:
        if key not in row or row[key] == "":
            continue
        value = float(row[key])
        values.append(abs(value) if absolute else value)
    return values


def path_count_groups(rows: list[dict[str, object]], option: str | None = None) -> list[tuple[int, list[dict[str, object]]]]:
    grouped: dict[int, list[dict[str, object]]] = {}
    for row in rows:
        if option is not None and row["option"] != option:
            continue
        grouped.setdefault(int(row["paths"]), []).append(row)
    return sorted(grouped.items())


def write_summary(rows: list[dict[str, object]], path: Path, attribution: bool) -> None:
    worst = sorted(rows, key=lambda row: float(row["abs_bps_spot"]), reverse=True)
    warnings = [row for row in rows if row["ref_convergence_warning"]]
    with path.open("w", encoding="utf-8") as handle:
        handle.write("# Financial Accuracy Study\n\n")
        handle.write(f"Cases: {len(rows)}\n\n")
        handle.write(f"Worst abs bps of spot: {fmt(worst[0]['abs_bps_spot'])}\n\n")
        handle.write(f"Reference convergence warnings (>0.1 bp spot): {len(warnings)}\n\n")
        if attribution:
            handle.write("## Path Count Summary\n\n")
            handle.write(
                "| option | N | avg abs total bps | max abs total bps | avg abs qmc/reg bps | "
                "avg abs fixed bps | max abs fixed bps | avg abs terminal Sobol bps |\n"
            )
            handle.write("|---|---:|---:|---:|---:|---:|---:|---:|\n")
            for opt in ("PUT", "CALL"):
                for n, group in path_count_groups(rows, opt):
                    total_abs = [abs(float(row["total_bps_spot"])) for row in group]
                    qmc_abs = [abs(float(row["qmc_regression_bps_spot"])) for row in group]
                    fixed_abs = [abs(float(row["fixed_point_bps_spot"])) for row in group]
                    terminal_abs = [abs(float(row["terminal_sobol_bps_spot"])) for row in group]
                    handle.write(
                        f"| {opt} | {n} | {fmt(average(total_abs), 4)} | {fmt(max(total_abs), 4)} "
                        f"| {fmt(average(qmc_abs), 4)} | {fmt(average(fixed_abs), 4)} "
                        f"| {fmt(max(fixed_abs), 4)} | {fmt(average(terminal_abs), 4)} |\n"
                    )
            handle.write("\n")
            if any("multi_total_bps_spot" in row for row in rows):
                handle.write("## Multi-Date Path Count Summary\n\n")
                handle.write(
                    "| option | N | avg abs single bps | avg abs multi bps | "
                    "avg improvement bps | avg abs multi fixed bps | max abs multi fixed bps |\n"
                )
                handle.write("|---|---:|---:|---:|---:|---:|---:|\n")
                for opt in ("PUT", "CALL"):
                    for n, group in path_count_groups(rows, opt):
                        single_abs = row_floats(group, "single_total_bps_spot", absolute=True)
                        multi_abs = row_floats(group, "multi_total_bps_spot", absolute=True)
                        improvement = row_floats(group, "multi_vs_single_improvement_bps_spot")
                        multi_fixed = row_floats(group, "multi_fixed_point_bps_spot", absolute=True)
                        if not multi_abs:
                            continue
                        handle.write(
                            f"| {opt} | {n} | {fmt(average(single_abs), 4) if single_abs else 'n/a'} "
                            f"| {fmt(average(multi_abs), 4)} | {fmt(average(improvement), 4) if improvement else 'n/a'} "
                            f"| {fmt(average(multi_fixed), 4) if multi_fixed else 'n/a'} "
                            f"| {fmt(max(multi_fixed), 4) if multi_fixed else 'n/a'} |\n"
                        )
                handle.write("\n")
        if any("fallback_step_ratio" in row for row in rows):
            handle.write("## Regression Health Summary\n\n")
            handle.write(
                "| option | N | avg min ITM | avg fallback ratio | max beta magnitude | "
                "avg early exercise rate | max negative cont est count |\n"
            )
            handle.write("|---|---:|---:|---:|---:|---:|---:|\n")
            for opt in ("PUT", "CALL"):
                for n, group in path_count_groups(rows, opt):
                    groups_with_health = [row for row in group if "fallback_step_ratio" in row]
                    if not groups_with_health:
                        continue
                    min_itm = row_floats(groups_with_health, "min_itm_count")
                    fallback_ratio = row_floats(groups_with_health, "fallback_step_ratio")
                    early_rate = row_floats(groups_with_health, "early_exercise_rate")
                    neg_counts = row_floats(groups_with_health, "negative_cont_est_count")
                    beta_max = [
                        max(
                            abs(float(row.get("max_abs_beta0", 0.0))),
                            abs(float(row.get("max_abs_beta1", 0.0))),
                            abs(float(row.get("max_abs_beta2", 0.0))),
                        )
                        for row in groups_with_health
                    ]
                    handle.write(
                        f"| {opt} | {n} | {fmt(average(min_itm), 2)} "
                        f"| {fmt(average(fallback_ratio), 4)} | {fmt(max(beta_max), 4)} "
                        f"| {fmt(average(early_rate), 6)} | {fmt(max(neg_counts), 0)} |\n"
                    )
            health_worst = sorted(
                [row for row in rows if "fallback_step_ratio" in row],
                key=lambda row: (
                    float(row["fallback_step_ratio"]),
                    max(
                        abs(float(row.get("max_abs_beta0", 0.0))),
                        abs(float(row.get("max_abs_beta1", 0.0))),
                        abs(float(row.get("max_abs_beta2", 0.0))),
                    ),
                    float(row.get("negative_cont_est_count", 0.0)),
                ),
                reverse=True,
            )
            handle.write("\n## Worst Regression Health Cases\n\n")
            handle.write(
                "| option | N | M | K/S0 | sigma | T | r | min ITM | fallback ratio | "
                "max beta | neg cont | early ex rate | worst step |\n"
            )
            handle.write("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n")
            for row in health_worst[:20]:
                max_beta = max(
                    abs(float(row.get("max_abs_beta0", 0.0))),
                    abs(float(row.get("max_abs_beta1", 0.0))),
                    abs(float(row.get("max_abs_beta2", 0.0))),
                )
                handle.write(
                    f"| {row['option']} | {row['paths']} | {row['steps']} | {fmt(row['moneyness_K_over_S0'], 3)} "
                    f"| {fmt(row['sigma'], 3)} | {fmt(row['T'], 3)} | {fmt(row['r'], 3)} "
                    f"| {fmt(row['min_itm_count'], 0)} | {fmt(row['fallback_step_ratio'], 4)} "
                    f"| {fmt(max_beta, 4)} | {fmt(row['negative_cont_est_count'], 0)} "
                    f"| {fmt(row['early_exercise_rate'], 6)} | {row['worst_exercise_step']} |\n"
                )
            handle.write("\n")
        handle.write("## Worst Cases\n\n")
        handle.write("| option | mode | N | M | K/S0 | sigma | T | r | fpga | american | abs bps spot |\n")
        handle.write("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n")
        for row in worst[:20]:
            handle.write(
                f"| {row['option']} | {row['exercise_mode']} | {row['paths']} | {row['steps']} | {fmt(row['moneyness_K_over_S0'], 3)} "
                f"| {fmt(row['sigma'], 3)} | {fmt(row['T'], 3)} | {fmt(row['r'], 3)} "
                f"| {fmt(row['fpga_style'])} | {fmt(row['american_tree'])} | {fmt(row['abs_bps_spot'])} |\n"
            )
        if attribution:
            handle.write("\n## Attribution For Worst Cases\n\n")
            handle.write("| option | N | M | K/S0 | model bps | qmc/reg bps | fixed bps | total bps |\n")
            handle.write("|---|---:|---:|---:|---:|---:|---:|---:|\n")
            for row in worst[:20]:
                handle.write(
                    f"| {row['option']} | {row['paths']} | {row['steps']} | {fmt(row['moneyness_K_over_S0'], 3)} "
                    f"| {fmt(row['single_exercise_model_bps_spot'])} | {fmt(row['qmc_regression_bps_spot'])} "
                    f"| {fmt(row['fixed_point_bps_spot'])} | {fmt(row['total_bps_spot'])} |\n"
                )


def print_console_summary(rows: list[dict[str, object]]) -> None:
    worst = sorted(rows, key=lambda row: float(row["abs_bps_spot"]), reverse=True)
    print(f"Completed {len(rows)} cases")
    if rows and "fixed_point_bps_spot" in rows[0]:
        print("Path-count attribution summary:")
        for opt in ("PUT", "CALL"):
            for n, group in path_count_groups(rows, opt):
                total_abs = [abs(float(row["total_bps_spot"])) for row in group]
                qmc_abs = [abs(float(row["qmc_regression_bps_spot"])) for row in group]
                fixed_abs = [abs(float(row["fixed_point_bps_spot"])) for row in group]
                terminal_abs = [abs(float(row["terminal_sobol_bps_spot"])) for row in group]
                print(
                    f"  {opt} N={n}: avg_total={average(total_abs):.4f} bps, "
                    f"avg_qmc/reg={average(qmc_abs):.4f} bps, "
                    f"avg_fixed={average(fixed_abs):.4f} bps, "
                    f"avg_terminal_sobol={average(terminal_abs):.4f} bps"
                )
        if any("multi_total_bps_spot" in row for row in rows):
            print("Multi-date path-count summary:")
            for opt in ("PUT", "CALL"):
                for n, group in path_count_groups(rows, opt):
                    multi_abs = row_floats(group, "multi_total_bps_spot", absolute=True)
                    if not multi_abs:
                        continue
                    single_abs = row_floats(group, "single_total_bps_spot", absolute=True)
                    improvement = row_floats(group, "multi_vs_single_improvement_bps_spot")
                    multi_fixed = row_floats(group, "multi_fixed_point_bps_spot", absolute=True)
                    single_text = f"{average(single_abs):.4f}" if single_abs else "n/a"
                    improvement_text = f"{average(improvement):.4f}" if improvement else "n/a"
                    fixed_text = f"{average(multi_fixed):.4f}" if multi_fixed else "n/a"
                    max_fixed_text = f"{max(multi_fixed):.4f}" if multi_fixed else "n/a"
                    print(
                        f"  {opt} N={n}: avg_single={single_text} bps, "
                        f"avg_multi={average(multi_abs):.4f} bps, "
                        f"avg_improvement={improvement_text} bps, "
                        f"avg_multi_fixed={fixed_text} bps, "
                        f"max_multi_fixed={max_fixed_text} bps"
                    )
    if rows and "fallback_step_ratio" in rows[0]:
        print("Regression-health summary:")
        for opt in ("PUT", "CALL"):
            for n, group in path_count_groups(rows, opt):
                group = [row for row in group if "fallback_step_ratio" in row]
                if not group:
                    continue
                fallback_ratio = row_floats(group, "fallback_step_ratio")
                min_itm = row_floats(group, "min_itm_count")
                early_rate = row_floats(group, "early_exercise_rate")
                beta_max = [
                    max(
                        abs(float(row.get("max_abs_beta0", 0.0))),
                        abs(float(row.get("max_abs_beta1", 0.0))),
                        abs(float(row.get("max_abs_beta2", 0.0))),
                    )
                    for row in group
                ]
                print(
                    f"  {opt} N={n}: avg_fallback_ratio={average(fallback_ratio):.4f}, "
                    f"avg_min_itm={average(min_itm):.2f}, "
                    f"max_beta={max(beta_max):.4f}, "
                    f"avg_early_exercise_rate={average(early_rate):.6f}"
                )
    print("Worst cases by abs_bps_spot:")
    for row in worst[:10]:
        print(
            f"  {row['option']} mode={row['exercise_mode']} N={row['paths']} M={row['steps']} "
            f"K/S0={float(row['moneyness_K_over_S0']):.2f} "
            f"sigma={float(row['sigma']):.2f} T={float(row['T']):.2f} r={float(row['r']):.2f}: "
            f"fpga={float(row['fpga_style']):.6f} ref={float(row['american_tree']):.6f} "
            f"abs_bps_spot={float(row['abs_bps_spot']):.4f}"
        )
    warn_count = sum(1 for row in rows if row["ref_convergence_warning"])
    if warn_count:
        print(f"WARNING: {warn_count} reference cases exceeded 0.1 bp spot convergence delta")


def main() -> int:
    parser = argparse.ArgumentParser(description="Run financial accuracy study")
    parser.add_argument("--preset", choices=["smoke", "default"], default="smoke")
    parser.add_argument("--build-cpu", action="store_true")
    parser.add_argument("--ref-steps", type=int, default=DEFAULT_REFERENCE_STEPS)
    parser.add_argument("--output-dir", default=".tmp/accuracy")
    parser.add_argument("--attribution", action="store_true")
    parser.add_argument("--health-metrics", action="store_true")
    parser.add_argument("--exercise-mode", choices=["single", "multi", "both"], default="single")
    parser.add_argument("--S0", type=float, default=100.0)
    parser.add_argument("--paths-list")
    parser.add_argument("--steps-list")
    parser.add_argument("--moneyness-list")
    parser.add_argument("--sigma-list")
    parser.add_argument("--r-list")
    parser.add_argument("--T-list")
    parser.add_argument("--option-types")
    args = parser.parse_args()

    repo_root = repo_root_from_script()
    baseline_dir = repo_root / "baseline" / "cpp_fixed"
    if args.build_cpu:
        build_cpu_baseline(baseline_dir, repo_root)
    exe = find_cpu_exe(baseline_dir)

    cases = make_cases(args)
    output_dir = (repo_root / args.output_dir).resolve() if not Path(args.output_dir).is_absolute() else Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    direction = load_direction_file(repo_root / "src" / "gen" / "direction.mem") if (args.attribution or args.health_metrics) else None
    reference_cache: dict[tuple[float, float, float, float, float, int, int], float] = {}
    single_cache: dict[tuple[float, float, float, float, float, int, int, int], float] = {}
    bs_cache: dict[tuple[float, float, float, float, float, int], float] = {}
    convergence_cache: dict[tuple[float, float, float, float, float, int, int], tuple[bool, float, float, float]] = {}
    rows: list[dict[str, object]] = []
    health_rows: list[dict[str, object]] = []
    for idx, case in enumerate(cases, 1):
        single_result: tuple[float, int] | None = None
        multi_result: tuple[float, int] | None = None
        if args.exercise_mode in ("single", "both"):
            single_result = run_fpga_style(case, exe, repo_root, baseline_dir, "single")
        if args.exercise_mode in ("multi", "both"):
            multi_result = run_fpga_style(case, exe, repo_root, baseline_dir, "multi")
        primary_result = multi_result if args.exercise_mode in ("multi", "both") else single_result
        if primary_result is None:
            raise RuntimeError(f"No C++ price produced for exercise mode {args.exercise_mode}")
        fpga_price, fpga_q16 = primary_result
        row = row_for_case(
            idx,
            case,
            fpga_price,
            fpga_q16,
            args.exercise_mode,
            args.ref_steps,
            direction,
            args.attribution,
            args.health_metrics,
            health_rows,
            single_result,
            multi_result,
            reference_cache,
            single_cache,
            bs_cache,
            convergence_cache,
        )
        rows.append(row)
        mode_text = f" mode={args.exercise_mode}"
        if args.exercise_mode == "both":
            mode_text += (
                f" single_bps={float(row['single_abs_bps_spot']):.4f} "
                f"multi_bps={float(row['multi_abs_bps_spot']):.4f}"
            )
        print(
            f"[{idx}/{len(cases)}] {option_name(case.option_type)}{mode_text} N={case.paths} M={case.steps} "
            f"K/S0={case.K / case.S0:.2f} sigma={case.sigma:.2f} T={case.T:.2f} "
            f"abs_bps_spot={row['abs_bps_spot']:.4f}"
        )

    rows = sorted(rows, key=lambda row: float(row["abs_bps_spot"]), reverse=True)
    csv_path = output_dir / "accuracy_results.csv"
    md_path = output_dir / "accuracy_summary.md"
    write_csv(rows, csv_path)
    write_summary(rows, md_path, args.attribution)
    if args.health_metrics and health_rows:
        health_dir = output_dir / "health"
        health_dir.mkdir(parents=True, exist_ok=True)
        health_path = health_dir / "health_rows.csv"
        write_csv(health_rows, health_path)
    else:
        health_path = None
    print()
    print_console_summary(rows)
    print(f"\nWrote {csv_path}")
    print(f"Wrote {md_path}")
    if health_path is not None:
        print(f"Wrote {health_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
