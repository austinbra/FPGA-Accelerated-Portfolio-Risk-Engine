"""Deterministic single-contract bump/revalue across C++ and FPGA targets."""

from __future__ import annotations

import argparse
import csv
import json
import math
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from src.uart_host import (  # noqa: E402
    FpgaSession,
    build_cpu_baseline,
    cpu_baseline_exists,
    load_params_file,
    run_cpu_job,
    validate_fpga_params,
)

SCENARIO_ORDER = ("base", "spot_up", "spot_down", "volatility_up", "volatility_down")
CSV_FIELDS = (
    "scenario", "target", "paths", "steps", "S0", "K", "r", "sigma", "T",
    "option_type", "exercise_mode", "price_raw", "price", "core_cycles",
    "core_seconds", "cpu_reported_seconds", "transport_seconds", "status",
    "delta", "gamma", "vega",
)


def build_scenarios(base, spot_bump_relative=0.01, volatility_bump=0.01):
    """Build five jobs that all restart the same deterministic Sobol sequence."""
    if not math.isfinite(spot_bump_relative) or not 0 < spot_bump_relative < 1:
        raise ValueError("spot_bump_relative must be finite and in (0, 1)")
    if not math.isfinite(volatility_bump) or volatility_bump <= 0:
        raise ValueError("volatility_bump must be finite and positive")
    spot = float(base["S0"])
    volatility = float(base["sigma"])
    spot_step = spot * spot_bump_relative
    if volatility - volatility_bump <= 0:
        raise ValueError("volatility-down scenario must retain positive volatility")

    scenarios = {name: dict(base) for name in SCENARIO_ORDER}
    scenarios["spot_up"]["S0"] = spot + spot_step
    scenarios["spot_down"]["S0"] = spot - spot_step
    scenarios["volatility_up"]["sigma"] = volatility + volatility_bump
    scenarios["volatility_down"]["sigma"] = volatility - volatility_bump
    return scenarios, spot_step, volatility_bump


def calculate_greeks(rows, spot_step, volatility_step):
    by_target = {}
    for row in rows:
        by_target.setdefault(row["target"], {})[row["scenario"]] = float(row["price"])
    output = {}
    for target, prices in by_target.items():
        missing = set(SCENARIO_ORDER) - set(prices)
        if missing:
            raise ValueError(f"missing scenarios for {target}: {sorted(missing)}")
        output[target] = {
            "delta": (prices["spot_up"] - prices["spot_down"]) / (2 * spot_step),
            "gamma": (
                prices["spot_up"] - 2 * prices["base"] + prices["spot_down"]
            ) / (spot_step * spot_step),
            "vega": (
                prices["volatility_up"] - prices["volatility_down"]
            ) / (2 * volatility_step),
        }
        if not all(math.isfinite(value) for value in output[target].values()):
            raise RuntimeError(f"non-finite Greek produced for {target}")
    return output


def _common_row(name, target, params, exercise_mode):
    return {
        "scenario": name, "target": target,
        "paths": int(params["paths"]), "steps": int(params["steps"]),
        "S0": float(params["S0"]), "K": float(params["K"]),
        "r": float(params["r"]), "sigma": float(params["sigma"]),
        "T": float(params["T"]), "option_type": int(params.get("option_type", 1)),
        "exercise_mode": exercise_mode, "status": "OK",
    }


def run_workflow(base, target, baseline_dir, exercise_mode="multi", num_lanes=4,
                 port="COM4", baud=115200, timeout_s=2.0, fclk_hz=105_263_158.0,
                 spot_bump_relative=0.01, volatility_bump=0.01,
                 cpu_runner=run_cpu_job, fpga_session_factory=FpgaSession):
    if target not in ("cpu", "fpga", "both"):
        raise ValueError("target must be cpu, fpga, or both")
    if exercise_mode not in ("single", "multi"):
        raise ValueError("exercise_mode must be single or multi")
    if not math.isfinite(fclk_hz) or fclk_hz <= 0:
        raise ValueError("fclk_hz must be finite and positive")
    scenarios, spot_step, volatility_step = build_scenarios(
        base, spot_bump_relative, volatility_bump
    )
    if target in ("fpga", "both"):
        # Complete preflight before constructing a possibly eager third-party adapter.
        for params in scenarios.values():
            validate_fpga_params(params, num_lanes)

    rows = []
    cpu_raw = {}
    if target in ("cpu", "both"):
        for name in SCENARIO_ORDER:
            params = scenarios[name]
            result = cpu_runner(params, baseline_dir, exercise_mode)
            cpu_raw[name] = result.price_raw
            row = _common_row(name, "cpu", params, exercise_mode)
            row.update({
                "price_raw": result.price_raw, "price": result.price,
                "core_cycles": None, "core_seconds": None,
                "cpu_reported_seconds": result.elapsed_s,
                "transport_seconds": None,
            })
            rows.append(row)

    if target in ("fpga", "both"):
        with fpga_session_factory(
            port=port, baud=baud, timeout_s=timeout_s, num_lanes=num_lanes
        ) as session:
            for name in SCENARIO_ORDER:
                params = scenarios[name]
                result = session.run_job(params)
                if target == "both" and result.price_raw != cpu_raw[name]:
                    raise RuntimeError(
                        f"raw C++/FPGA mismatch for {name}: "
                        f"CPU={cpu_raw[name]}, FPGA={result.price_raw}"
                    )
                row = _common_row(name, "fpga", params, exercise_mode)
                row.update({
                    "price_raw": result.price_raw, "price": result.price,
                    "core_cycles": result.core_cycles,
                    "core_seconds": result.core_cycles / fclk_hz,
                    "cpu_reported_seconds": None,
                    "transport_seconds": result.transport_s,
                })
                rows.append(row)

    greeks = calculate_greeks(rows, spot_step, volatility_step)
    for row in rows:
        row.update(greeks[row["target"]])
    return rows, greeks, {
        "common_random_numbers": True,
        "sobol_policy": "each scenario restarts at Sobol index 1",
        "spot_bump_relative": spot_bump_relative,
        "spot_step": spot_step,
        "volatility_step": volatility_step,
        "fpga_fclk_hz": fclk_hz,
        "num_lanes": num_lanes,
        "exercise_mode": exercise_mode,
    }


def write_outputs(rows, greeks, metadata, csv_path, json_path):
    csv_path, json_path = Path(csv_path), Path(json_path)
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.parent.mkdir(parents=True, exist_ok=True)
    with csv_path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=CSV_FIELDS)
        writer.writeheader()
        writer.writerows(rows)
    document = {"metadata": metadata, "results": rows, "greeks": greeks}
    with json_path.open("w", encoding="utf-8") as stream:
        json.dump(document, stream, indent=2, allow_nan=False)
        stream.write("\n")


def main():
    parser = argparse.ArgumentParser(
        description="Five-job common-random-number bump/revalue runner"
    )
    parser.add_argument("--target", choices=("cpu", "fpga", "both"), default="cpu")
    parser.add_argument(
        "--param-file",
        default=str(REPO_ROOT / "baseline" / "cpp_fixed" / "params_monthly_1024x12.txt"),
    )
    parser.add_argument("--paths", type=int, default=None)
    parser.add_argument("--steps", type=int, default=None)
    parser.add_argument("--S0", dest="spot", type=float, default=None)
    parser.add_argument("--K", dest="strike", type=float, default=None)
    parser.add_argument("--r", dest="rate", type=float, default=None)
    parser.add_argument("--sigma", dest="volatility", type=float, default=None)
    parser.add_argument("--T", dest="maturity", type=float, default=None)
    parser.add_argument("--option-type", type=int, choices=(0, 1), default=None)
    parser.add_argument("--exercise-mode", choices=("single", "multi"), default=None)
    parser.add_argument("--spot-bump-relative", type=float, default=0.01)
    parser.add_argument("--volatility-bump", type=float, default=0.01)
    parser.add_argument("--num-lanes", type=int, default=4)
    parser.add_argument("--port", default="COM4")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--timeout", type=float, default=2.0)
    parser.add_argument("--fpga-fclk-hz", type=float, default=105_263_158.0)
    parser.add_argument("--build-cpu", action="store_true")
    parser.add_argument("--use-boost", action="store_true")
    parser.add_argument("--boost-include", default="")
    parser.add_argument(
        "--output-prefix",
        default=str(REPO_ROOT / ".tmp" / "bump_revalue" / "bump_revalue"),
        help="writes PREFIX.csv and PREFIX.json",
    )
    args = parser.parse_args()

    params = load_params_file(args.param_file)
    file_mode = params.pop("exercise_mode", None)
    if args.exercise_mode and file_mode and args.exercise_mode != file_mode:
        raise ValueError(
            f"--exercise-mode {args.exercise_mode} conflicts with parameter file {file_mode}"
        )
    args.exercise_mode = args.exercise_mode or file_mode or "multi"
    overrides = {
        "paths": args.paths, "steps": args.steps, "S0": args.spot,
        "K": args.strike, "r": args.rate, "sigma": args.volatility,
        "T": args.maturity, "option_type": args.option_type,
    }
    params.update({key: value for key, value in overrides.items() if value is not None})
    baseline_dir = REPO_ROOT / "baseline" / "cpp_fixed"
    if args.target in ("cpu", "both") and (
        args.build_cpu or not cpu_baseline_exists(baseline_dir)
    ):
        build_cpu_baseline(
            baseline_dir, use_boost=args.use_boost, boost_include=args.boost_include
        )
    rows, greeks, metadata = run_workflow(
        params, args.target, baseline_dir, args.exercise_mode, args.num_lanes,
        args.port, args.baud, args.timeout, args.fpga_fclk_hz,
        args.spot_bump_relative, args.volatility_bump,
    )
    prefix = Path(args.output_prefix)
    csv_path, json_path = prefix.with_suffix(".csv"), prefix.with_suffix(".json")
    write_outputs(rows, greeks, metadata, csv_path, json_path)

    print("Bump/revalue complete (identical Sobol start for every scenario).")
    for target, values in greeks.items():
        print(f"  {target}: delta={values['delta']:.8f} "
              f"gamma={values['gamma']:.8f} vega={values['vega']:.8f}")
    print(f"  CSV:  {csv_path}")
    print(f"  JSON: {json_path}")


if __name__ == "__main__":
    main()
