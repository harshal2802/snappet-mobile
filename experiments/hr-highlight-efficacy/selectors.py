"""
Three candidate highlight selectors. Each scores candidate moments; none ever sees
the latent engagement signal. Selection is top-N with non-maximum suppression so
picks aren't clustered (a reel wants spread-out moments).
"""

import random
from typing import Callable, Dict, List

from synth import Session, _moving_avg


def _select_top_n(scores: Dict[int, float], n: int, min_gap: int = 20) -> List[int]:
    """Greedy top-N with a minimum temporal gap between picks (NMS)."""
    picks: List[int] = []
    for t in sorted(scores, key=lambda x: scores[x], reverse=True):
        if all(abs(t - p) >= min_gap for p in picks):
            picks.append(t)
        if len(picks) >= n:
            break
    return sorted(picks)


# ── HR-based selector (the candidate under test) — implements #60 §4 ──────────
def hr_selector(
    s: Session,
    n: int,
    smooth_window: int = 9,     # seconds
    look_ahead: int = 6,        # HR lags the moment → score the moment by HR just after it
    w_level: float = 0.6,       # weight on %HRR peak
    w_slope: float = 0.4,       # weight on rate-of-change dHR/dt
) -> List[int]:
    hr_s = _moving_avg(s.hr, smooth_window)
    hrr = [max(0.0, min(1.0, (v - s.rest_bpm) / (s.max_bpm - s.rest_bpm))) for v in hr_s]
    # central-difference derivative on smoothed series, then normalize positive slope
    slope = [0.0] * len(hr_s)
    for t in range(1, len(hr_s) - 1):
        slope[t] = (hr_s[t + 1] - hr_s[t - 1]) / 2.0
    max_slope = max(slope) or 1.0
    slope_n = [max(0.0, v / max_slope) for v in slope]

    scores = {}
    for t in s.candidates:
        u = min(len(hr_s) - 1, t + look_ahead)   # bias earlier: look at HR after the moment
        scores[t] = w_level * hrr[u] + w_slope * slope_n[u]
    return _select_top_n(scores, n)


# ── Scene-detection baseline (content/visual saliency) ────────────────────────
def scene_selector(s: Session, n: int, smooth_window: int = 5) -> List[int]:
    vis = _moving_avg(s.visual, smooth_window)
    scores = {t: vis[t] for t in s.candidates}
    return _select_top_n(scores, n)


# ── Random baseline (the floor) ───────────────────────────────────────────────
def random_selector(s: Session, n: int, seed: int = 0) -> List[int]:
    rng = random.Random(seed)
    scores = {t: rng.random() for t in s.candidates}
    return _select_top_n(scores, n)


# ── Fusion (HR + Scene) — the spike's predicted real-world winner (#60 §4) ────
# Mirrors the Swift `FusionSelector.hrLeaning` (0.7 HR / 0.3 Scene). Both component
# scores are normalized to 0..1 over the candidate set so the weights are meaningful.
def fusion_selector(s: Session, n: int, w_hr: float = 0.7, w_scene: float = 0.3) -> List[int]:
    hr_n = _normalize(_hr_scores(s))
    scene_n = _normalize({t: _moving_avg(s.visual, 5)[t] for t in s.candidates})
    scores = {t: w_hr * hr_n[t] + w_scene * scene_n[t] for t in s.candidates}
    return _select_top_n(scores, n)


def _hr_scores(s: Session, smooth_window: int = 9, look_ahead: int = 6,
               w_level: float = 0.6, w_slope: float = 0.4) -> Dict[int, float]:
    """Per-candidate HR score (same math as hr_selector, factored out for fusion)."""
    hr_s = _moving_avg(s.hr, smooth_window)
    hrr = [max(0.0, min(1.0, (v - s.rest_bpm) / (s.max_bpm - s.rest_bpm))) for v in hr_s]
    slope = [0.0] * len(hr_s)
    for t in range(1, len(hr_s) - 1):
        slope[t] = (hr_s[t + 1] - hr_s[t - 1]) / 2.0
    max_slope = max(slope) or 1.0
    slope_n = [max(0.0, v / max_slope) for v in slope]
    out = {}
    for t in s.candidates:
        u = min(len(hr_s) - 1, t + look_ahead)
        out[t] = w_level * hrr[u] + w_slope * slope_n[u]
    return out


def _normalize(scores: Dict[int, float]) -> Dict[int, float]:
    vals = list(scores.values())
    lo, hi = (min(vals), max(vals)) if vals else (0.0, 1.0)
    span = (hi - lo) or 1.0
    return {t: (v - lo) / span for t, v in scores.items()}


SELECTORS: Dict[str, Callable] = {
    "HR": hr_selector,
    "Scene": scene_selector,
    "Fusion": fusion_selector,
    "Random": random_selector,
}
