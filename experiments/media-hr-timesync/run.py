"""
media <-> HR time-sync spike runner (Phase 0b).

Runs the three alignment strategies over many seeded synthetic sessions and reports
the alignment-error distribution (median / p95 / max, in seconds) per strategy, plus
the residual drift over a session. The p95 of the best *practical* strategy is the
clip-padding the app should use.

Usage:  python3 run.py [n_sessions]
Output: a markdown report on stdout (paste into / regenerate RESULTS.md).
"""

import random
import statistics
import sys
from typing import Dict, List

from strategies import STRATEGIES, errors_for
from synth import generate_session


def pct(xs: List[float], p: float) -> float:
    if not xs:
        return 0.0
    s = sorted(xs)
    i = min(len(s) - 1, max(0, int(round(p * (len(s) - 1)))))
    return s[i]


def summarize(xs: List[float]) -> Dict[str, float]:
    return {
        "median": statistics.median(xs) if xs else 0.0,
        "p95": pct(xs, 0.95),
        "max": max(xs) if xs else 0.0,
    }


def run(n_sessions: int, allow_tz_error: bool, base_seed: int = 7000) -> Dict[str, Dict[str, float]]:
    bucket: Dict[str, List[float]] = {name: [] for name in STRATEGIES}
    for i in range(n_sessions):
        rng = random.Random(base_seed + i)
        s = generate_session(rng, allow_tz_error=allow_tz_error)
        for name in STRATEGIES:
            bucket[name].extend(errors_for(name, s))
    return {name: summarize(xs) for name, xs in bucket.items()}


def drift_only_p95(n_sessions: int, base_seed: int = 9000) -> float:
    """Residual error from crystal drift alone (session_sync removes skew+tz)."""
    xs: List[float] = []
    for i in range(n_sessions):
        rng = random.Random(base_seed + i)
        s = generate_session(rng, allow_tz_error=True)
        xs.extend(errors_for("session_sync", s))
    return pct(xs, 0.95)


def fmt_row(name: str, st: Dict[str, float]) -> str:
    return f"| {name} | {st['median']:.2f} | {st['p95']:.2f} | {st['max']:.1f} |"


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 200
    print("# media ↔ HR time-sync — modeled results\n")
    print(f"_{n} synthetic sessions · seeded, reproducible · error in seconds vs stopwatch ground truth_\n")
    print("> ⚠️ **Modeled, not measured on a device.** Parameters (skew/drift/TZ) are conservative "
          "guesses; the numbers below are an error-budget estimate, not field data. See the re-run plan.\n")

    print("## With gross timezone errors present (realistic worst case)\n")
    print("| strategy | median err | p95 err | max err |")
    print("|---|---|---|---|")
    with_tz = run(n, allow_tz_error=True)
    for name in STRATEGIES:
        print(fmt_row(name, with_tz[name]))

    print("\n## With timezone already correct (drift + skew only)\n")
    print("| strategy | median err | p95 err | max err |")
    print("|---|---|---|---|")
    no_tz = run(n, allow_tz_error=False)
    for name in STRATEGIES:
        print(fmt_row(name, no_tz[name]))

    drift_p95 = drift_only_p95(n)
    print("\n## Headline\n")
    print(f"- Naive matching with a possible TZ mislabel: **p95 ≈ {with_tz['naive']['p95']:.0f} s**, "
          f"max **{with_tz['naive']['max']:.0f} s** — hours, not seconds, when TZ is wrong.")
    print(f"- TZ-resolved (snap gross hour offsets): p95 ≈ **{with_tz['tz_resolved']['p95']:.0f} s** "
          "— removes the catastrophic case, leaves skew.")
    print(f"- Session-sync (one start reference): residual is drift only, p95 ≈ **{drift_p95:.1f} s**.")
    print(f"\n→ **~1 s alignment is only achievable with session-sync** (or a tight skew). Without it, "
          f"pad generously. See RESULTS.md for the recommended padding.")


if __name__ == "__main__":
    main()
