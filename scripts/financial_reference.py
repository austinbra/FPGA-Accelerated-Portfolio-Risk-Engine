#!/usr/bin/env python3
"""
Dependency-free financial references for accuracy studies.

These functions answer financial-accuracy questions. They are intentionally
separate from the bit-exact FPGA-style C++/RTL parity oracle.
"""
from __future__ import annotations

import argparse
import math
from statistics import NormalDist


DEFAULT_REFERENCE_STEPS = 4096


def payoff(spot: float, strike: float, option_type: int) -> float:
    """Return intrinsic value for option_type 0=CALL, 1=PUT."""
    if option_type & 1:
        return max(strike - spot, 0.0)
    return max(spot - strike, 0.0)


def european_black_scholes(
    S0: float,
    K: float,
    r: float,
    sigma: float,
    T: float,
    option_type: int,
    q: float = 0.0,
) -> float:
    """European Black-Scholes price, used only as a sanity reference."""
    if T <= 0.0:
        return payoff(S0, K, option_type)

    if sigma <= 0.0:
        forward = S0 * math.exp((r - q) * T)
        discounted = math.exp(-r * T) * payoff(forward, K, option_type)
        return discounted

    sqrt_T = math.sqrt(T)
    d1 = (math.log(S0 / K) + (r - q + 0.5 * sigma * sigma) * T) / (sigma * sqrt_T)
    d2 = d1 - sigma * sqrt_T
    normal = NormalDist()
    if option_type & 1:
        return K * math.exp(-r * T) * normal.cdf(-d2) - S0 * math.exp(-q * T) * normal.cdf(-d1)
    return S0 * math.exp(-q * T) * normal.cdf(d1) - K * math.exp(-r * T) * normal.cdf(d2)


def _deterministic_american(
    S0: float,
    K: float,
    r: float,
    T: float,
    option_type: int,
    q: float,
    exercise_index: int | None,
    steps: int,
    american: bool,
) -> float:
    """Fallback tree for sigma=0 where the CRR up/down factors collapse."""
    dt = T / steps
    values = [payoff(S0 * math.exp((r - q) * T), K, option_type)]
    for step in range(steps - 1, -1, -1):
        t = step * dt
        cont = math.exp(-r * dt) * values[0]
        spot = S0 * math.exp((r - q) * t)
        can_exercise = american or (exercise_index is not None and step == exercise_index)
        values[0] = max(payoff(spot, K, option_type), cont) if can_exercise else cont
    return values[0]


def _binomial_price(
    S0: float,
    K: float,
    r: float,
    sigma: float,
    T: float,
    option_type: int,
    steps: int,
    q: float,
    american: bool,
    exercise_index: int | None = None,
) -> float:
    if steps <= 0:
        raise ValueError("steps must be positive")
    if T <= 0.0:
        return payoff(S0, K, option_type)
    if sigma <= 0.0:
        return _deterministic_american(S0, K, r, T, option_type, q, exercise_index, steps, american)

    dt = T / steps
    u = math.exp(sigma * math.sqrt(dt))
    d = 1.0 / u
    growth = math.exp((r - q) * dt)
    p = (growth - d) / (u - d)
    if p < -1e-12 or p > 1.0 + 1e-12:
        raise ValueError(f"CRR risk-neutral probability out of range: p={p}")
    p = min(max(p, 0.0), 1.0)
    disc = math.exp(-r * dt)

    values = [0.0] * (steps + 1)
    ud_ratio = u / d
    spot = S0 * (d ** steps)
    for j in range(steps + 1):
        values[j] = payoff(spot, K, option_type)
        spot *= ud_ratio

    for step in range(steps - 1, -1, -1):
        can_exercise = american or (exercise_index is not None and step == exercise_index)
        spot = S0 * (d ** step)
        for j in range(step + 1):
            continuation = disc * (p * values[j + 1] + (1.0 - p) * values[j])
            if can_exercise:
                values[j] = max(payoff(spot, K, option_type), continuation)
            else:
                values[j] = continuation
            spot *= ud_ratio

    return values[0]


def american_binomial_crr(
    S0: float,
    K: float,
    r: float,
    sigma: float,
    T: float,
    option_type: int,
    steps: int = DEFAULT_REFERENCE_STEPS,
    q: float = 0.0,
) -> float:
    """High-precision American option reference using a CRR tree."""
    return _binomial_price(S0, K, r, sigma, T, option_type, steps, q, american=True)


def single_exercise_tree(
    S0: float,
    K: float,
    r: float,
    sigma: float,
    T: float,
    option_type: int,
    model_steps: int,
    reference_steps: int = DEFAULT_REFERENCE_STEPS,
    q: float = 0.0,
) -> float:
    """CRR tree where early exercise is allowed only at the RTL's M-1 date."""
    if model_steps <= 0:
        raise ValueError("model_steps must be positive")
    exercise_fraction = max(1, model_steps - 1) / float(model_steps)
    exercise_index = int(round(reference_steps * exercise_fraction))
    exercise_index = min(max(exercise_index, 0), reference_steps - 1)
    return _binomial_price(
        S0,
        K,
        r,
        sigma,
        T,
        option_type,
        reference_steps,
        q,
        american=False,
        exercise_index=exercise_index,
    )


def convergence_bps_spot(
    coarse_price: float,
    fine_price: float,
    S0: float,
) -> float:
    return abs(fine_price - coarse_price) / S0 * 10000.0 if S0 != 0.0 else math.inf


def reference_convergence_warning(
    S0: float,
    K: float,
    r: float,
    sigma: float,
    T: float,
    option_type: int,
    ref_steps: int = DEFAULT_REFERENCE_STEPS,
    threshold_bps_spot: float = 0.1,
    q: float = 0.0,
) -> tuple[bool, float, float, float]:
    """Return (warn, coarse, fine, bps_spot) for ref_steps/2 vs ref_steps."""
    coarse_steps = max(1, ref_steps // 2)
    coarse = american_binomial_crr(S0, K, r, sigma, T, option_type, coarse_steps, q)
    fine = american_binomial_crr(S0, K, r, sigma, T, option_type, ref_steps, q)
    bps = convergence_bps_spot(coarse, fine, S0)
    return bps > threshold_bps_spot, coarse, fine, bps


def _self_test() -> None:
    S0 = 100.0
    K = 100.0
    r = 0.05
    sigma = 0.2
    T = 1.0
    call_tree = american_binomial_crr(S0, K, r, sigma, T, 0, 2048)
    call_bs = european_black_scholes(S0, K, r, sigma, T, 0)
    put_tree = american_binomial_crr(S0, K, r, sigma, T, 1, 2048)
    put_bs = european_black_scholes(S0, K, r, sigma, T, 1)
    warn, coarse, fine, bps = reference_convergence_warning(S0, K, r, sigma, T, 1, 4096)

    call_bps = convergence_bps_spot(call_tree, call_bs, S0)
    print(f"American non-dividend CALL tree={call_tree:.8f} BS={call_bs:.8f} diff_bps_spot={call_bps:.4f}")
    print(f"American PUT tree={put_tree:.8f} European PUT={put_bs:.8f}")
    print(f"ATM PUT ref convergence 2048={coarse:.8f} 4096={fine:.8f} diff_bps_spot={bps:.4f}")

    if call_bps > 1.0:
        raise SystemExit("CALL tree did not converge close enough to Black-Scholes")
    if put_tree + 1e-10 < put_bs:
        raise SystemExit("American PUT is below European PUT")
    if warn:
        print("WARNING: 2048 vs 4096 reference convergence exceeds 0.1 bp of spot")


def main() -> int:
    parser = argparse.ArgumentParser(description="Financial reference pricing helpers")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        _self_test()
        return 0
    parser.print_help()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
