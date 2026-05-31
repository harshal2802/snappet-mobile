"""
HR-highlight-efficacy spike runner.

Runs the three selectors over many synthetic sessions across a sweep of the ONE
unknown that decides everything — the effort:scenic mix of memorable moments — and
reports agreement with synthetic ground truth.

Usage:  python3 run.py [n_sessions]
Output: a markdown report on stdout (paste into / regenerate RESULTS.md).
"""

import random
import statistics
import sys
from typing import Dict, List

from metrics import score_at_n, spearman
from selectors import SELECTORS
from synth import generate_session

N_PICKS = 8
TOL = 8  # seconds


def mean_std(xs: List[float]):
    return (statistics.mean(xs), statistics.pstdev(xs) if len(xs) > 1 else 0.0)


def run_scenario(n_sessions: int, activity: str, effort_mix: float, base_seed: int) -> Dict:
    acc = {name: {"f1": [], "precision": [], "recall": [], "spear": []} for name in SELECTORS}
    for i in range(n_sessions):
        rng = random.Random(base_seed + i)
        s = generate_session(rng, activity=activity, effort_mix=effort_mix, n_ground_truth=N_PICKS)
        if len(s.ground_truth) < 2:
            continue
        for name, fn in SELECTORS.items():
            picks = fn(s, N_PICKS, seed=base_seed + i) if name == "Random" else fn(s, N_PICKS)
            m = score_at_n(picks, s.ground_truth, tol=TOL)
            acc[name]["f1"].append(m["f1"])
            acc[name]["precision"].append(m["precision"])
            acc[name]["recall"].append(m["recall"])
            # how well does the selector's score track latent engagement over candidates?
            cand_scores = _score_map(name, fn, s)
            acc[name]["spear"].append(
                spearman([cand_scores[t] for t in s.candidates],
                         [s.engagement[t] for t in s.candidates])
            )
    return acc


def _score_map(name, fn, s):
    # Re-derive per-candidate scores for the Spearman diagnostic (mirrors selectors.py).
    from synth import _moving_avg
    if name == "HR":
        hr_s = _moving_avg(s.hr, 9)
        hrr = [max(0.0, min(1.0, (v - s.rest_bpm) / (s.max_bpm - s.rest_bpm))) for v in hr_s]
        slope = [0.0] * len(hr_s)
        for t in range(1, len(hr_s) - 1):
            slope[t] = (hr_s[t + 1] - hr_s[t - 1]) / 2.0
        ms = max(slope) or 1.0
        return {t: 0.6 * hrr[min(len(hr_s) - 1, t + 6)] + 0.4 * max(0.0, slope[min(len(hr_s) - 1, t + 6)] / ms)
                for t in s.candidates}
    if name == "Scene":
        vis = _moving_avg(s.visual, 5)
        return {t: vis[t] for t in s.candidates}
    if name == "Fusion":
        from selectors import _hr_scores, _normalize
        hr_n = _normalize(_hr_scores(s))
        scene_n = _normalize({t: _moving_avg(s.visual, 5)[t] for t in s.candidates})
        return {t: 0.7 * hr_n[t] + 0.3 * scene_n[t] for t in s.candidates}
    rng = random.Random(0)
    return {t: rng.random() for t in s.candidates}


def fmt(m):
    return f"{m[0]:.2f} ± {m[1]:.2f}"


def main():
    n_sessions = int(sys.argv[1]) if len(sys.argv) > 1 else 40
    scenarios = [
        ("running", 0.3), ("running", 0.5), ("running", 0.7),
        ("climbing", 0.5),
    ]
    print(f"# HR-highlight efficacy — synthetic results\n")
    print(f"_{n_sessions} sessions/scenario · top-{N_PICKS} picks · ±{TOL}s match tolerance · seeded, reproducible_\n")
    print("`effort_mix` = fraction of memorable moments that are effort-driven (HR-capturable). "
          "The rest are scenic/social (NOT HR-capturable). **This is the unknown only real users can pin down.**\n")

    summary = []
    for activity, mix in scenarios:
        acc = run_scenario(n_sessions, activity, mix, base_seed=1000)
        stats = {name: {k: mean_std(v[k]) for k in v} for name, v in acc.items()}
        print(f"## {activity}, effort_mix = {mix}\n")
        print("| selector | F1@8 | precision@8 | recall@8 | Spearman(score, engagement) |")
        print("|---|---|---|---|---|")
        for name in ("HR", "Scene", "Fusion", "Random"):
            st = stats[name]
            print(f"| {name} | {fmt(st['f1'])} | {fmt(st['precision'])} | {fmt(st['recall'])} | {fmt(st['spear'])} |")
        hr_f1, scene_f1, rand_f1 = stats["HR"]["f1"][0], stats["Scene"]["f1"][0], stats["Random"]["f1"][0]
        fus_f1 = stats["Fusion"]["f1"][0]
        verdict = (
            "HR ≫ Scene" if hr_f1 > scene_f1 + 0.05 else
            "HR ≈ Scene" if abs(hr_f1 - scene_f1) <= 0.05 else
            "Scene ≫ HR"
        )
        beats_floor = "yes" if hr_f1 > rand_f1 + 0.05 else "NO"
        print(f"\n→ HR vs Scene: **{verdict}** · Fusion F1: **{fus_f1:.2f}** · "
              f"HR beats random floor: **{beats_floor}**\n")
        summary.append((f"{activity}/{mix}", hr_f1, scene_f1, fus_f1, rand_f1, verdict))

    print("## One-line summary\n")
    print("| scenario | HR F1 | Scene F1 | Fusion F1 | Random F1 | HR vs Scene |")
    print("|---|---|---|---|---|---|")
    for name, h, sc, fu, r, v in summary:
        print(f"| {name} | {h:.2f} | {sc:.2f} | {fu:.2f} | {r:.2f} | {v} |")

    _tolerance_sweep(n_sessions)
    print("\n_See RESULTS.md for interpretation and the GO/NO-GO/NEEDS-REAL-DATA verdict._")


def _tolerance_sweep(n_sessions: int, tolerances=(5, 8, 12, 15)):
    """The spike flagged match tolerance as decisive (RESULTS.md interp #3): HR picks land
    in the right region but miss the exact instant, so a wider window should favor HR/Fusion.
    Sweep it on one representative scenario (climbing, effort_mix=0.5)."""
    activity, mix = "climbing", 0.5
    print(f"\n## Match-tolerance sweep ({activity}, effort_mix={mix})\n")
    print("Mean F1 as the ±match-tolerance window widens. Watch whether HR/Fusion close on Scene as "
          "tolerance grows (the spike's predicted effect).\n")
    print("| ±tol (s) | HR | Scene | Fusion | Random |")
    print("|---|---|---|---|---|")
    for tol in tolerances:
        f1 = {name: [] for name in SELECTORS}
        for i in range(n_sessions):
            rng = random.Random(1000 + i)
            s = generate_session(rng, activity=activity, effort_mix=mix, n_ground_truth=N_PICKS)
            if len(s.ground_truth) < 2:
                continue
            for name, fn in SELECTORS.items():
                picks = fn(s, N_PICKS, seed=1000 + i) if name == "Random" else fn(s, N_PICKS)
                f1[name].append(score_at_n(picks, s.ground_truth, tol=tol)["f1"])
        means = {name: (sum(v) / len(v) if v else 0.0) for name, v in f1.items()}
        print(f"| {tol} | {means['HR']:.2f} | {means['Scene']:.2f} | "
              f"{means['Fusion']:.2f} | {means['Random']:.2f} |")


if __name__ == "__main__":
    main()
