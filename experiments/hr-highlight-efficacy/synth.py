"""
Synthetic workout-session generator for the HR-highlight-efficacy spike.

⚠️ HONESTY NOTE — read before trusting any output:
This generator INVENTS the relationship between heart rate and "memorable" moments.
It therefore CANNOT prove the product premise (that a real user's own HR picks the
highlights *they* prefer). What it CAN do is (a) exercise the whole harness end-to-end
and (b) show how the verdict depends on one unknown we can only learn from real users:
the fraction of memorable moments that are effort-driven (HR-capturable) vs scenic/social
(not HR-capturable). See RESULTS.md.

Model
-----
- HR(t): warmup ramp + interval surges + noise, 1 Hz.
- Latent engagement E(t) = effort_mix * effort_signal + (1-effort_mix) * scenic_signal
    * effort_signal  : peaks slightly AFTER effort onsets but BEFORE the HR peak
                       (HR physiologically lags the moment — tests the "bias earlier" logic).
    * scenic_signal  : random memorable events uncorrelated with HR (a view, a friend, a laugh).
- Visual saliency V(t): what a content/scene detector sees = scenic + some motion(effort) + noise.
- Ground truth picks: top-K of E(t) within filmed ranges, with human jitter/dropout/extra.
"""

import math
import random
from dataclasses import dataclass, field
from typing import List, Tuple


@dataclass
class Session:
    duration: int
    hr: List[float]                 # bpm at 1 Hz, len == duration
    rest_bpm: float
    max_bpm: float
    engagement: List[float]         # latent E(t), 1 Hz (ground-truth-generating; selectors NEVER see this)
    visual: List[float]             # V(t), 1 Hz (scene-detector input)
    filmed: List[Tuple[int, int]]   # (start, end) intervals with media
    candidates: List[int]           # candidate moment times (within filmed ranges)
    ground_truth: List[int]         # user's manual highlight picks (within filmed ranges)
    meta: dict = field(default_factory=dict)


def _moving_avg(xs: List[float], w: int) -> List[float]:
    if w <= 1:
        return list(xs)
    half = w // 2
    out = []
    for i in range(len(xs)):
        a, b = max(0, i - half), min(len(xs), i + half + 1)
        out.append(sum(xs[a:b]) / (b - a))
    return out


def _normalize(xs: List[float]) -> List[float]:
    lo, hi = min(xs), max(xs)
    if hi - lo < 1e-9:
        return [0.0 for _ in xs]
    return [(x - lo) / (hi - lo) for x in xs]


def generate_session(
    rng: random.Random,
    duration: int = 3600,
    activity: str = "running",
    effort_mix: float = 0.5,
    n_ground_truth: int = 8,
    filmed_fraction: float = 0.4,
) -> Session:
    rest_bpm, max_bpm = 60.0, 190.0

    # ── HR series: warmup ramp toward a moderate plateau, plus effort surges ──
    if activity == "climbing":
        n_surges = rng.randint(10, 16)      # bursty
        surge_width = (8, 25)
    else:  # running
        n_surges = rng.randint(5, 9)        # fewer, broader intervals
        surge_width = (40, 120)

    plateau = rng.uniform(0.45, 0.6)        # fraction of HRR at steady state
    hr = []
    for t in range(duration):
        warm = min(1.0, t / 300.0)          # 5-min warmup
        base = rest_bpm + warm * plateau * (max_bpm - rest_bpm)
        hr.append(base)

    surge_onsets = sorted(rng.sample(range(300, duration - 130), n_surges))
    surge_amp = []
    for onset in surge_onsets:
        amp = rng.uniform(0.18, 0.40) * (max_bpm - rest_bpm)   # bpm added at peak
        width = rng.randint(*surge_width)
        surge_amp.append((onset, width, amp))
        for t in range(onset, min(duration, onset + width + 60)):
            # rise to peak over `width`, then decay
            if t <= onset + width:
                frac = (t - onset) / max(1, width)
                hr[t] += amp * math.sin(frac * math.pi / 2)     # ramp up
            else:
                decay = (t - onset - width) / 60.0
                hr[t] += amp * math.exp(-3 * decay)             # exp decay
    # sensor noise
    hr = [min(max_bpm, max(rest_bpm, v + rng.gauss(0, 1.6))) for v in hr]

    # ── effort_signal: the MOMENT is ~HR_LAG sec BEFORE the HR peak ──
    HR_LAG = 6  # seconds HR trails the real moment
    effort = [0.0] * duration
    for (onset, width, amp) in surge_amp:
        moment = max(0, onset + width - HR_LAG)   # exciting instant precedes HR peak
        strength = amp / (0.40 * (max_bpm - rest_bpm))
        for t in range(duration):
            effort[t] += strength * math.exp(-((t - moment) ** 2) / (2 * (12 ** 2)))

    # ── scenic_signal: random memorable events, uncorrelated with HR ──
    scenic = [0.0] * duration
    n_scenic = rng.randint(4, 9)
    scenic_times = rng.sample(range(60, duration - 60), n_scenic)
    for st in scenic_times:
        s = rng.uniform(0.6, 1.0)
        for t in range(duration):
            scenic[t] += s * math.exp(-((t - st) ** 2) / (2 * (10 ** 2)))

    effort_n, scenic_n = _normalize(effort), _normalize(scenic)
    engagement = [effort_mix * effort_n[t] + (1 - effort_mix) * scenic_n[t] for t in range(duration)]

    # ── visual saliency: scenic + a little motion(effort) + noise ──
    motion = _normalize(_moving_avg([abs(hr[t] - hr[t - 1]) if t else 0 for t in range(duration)], 5))
    visual = [
        0.7 * scenic_n[t] + 0.25 * motion[t] + 0.05 * rng.random()
        for t in range(duration)
    ]

    # ── filmed coverage: clips covering ~filmed_fraction of the session ──
    filmed: List[Tuple[int, int]] = []
    covered, guard = 0, 0
    target = int(filmed_fraction * duration)
    while covered < target and guard < 200:
        guard += 1
        start = rng.randint(0, duration - 30)
        length = rng.randint(20, 180)
        end = min(duration, start + length)
        if all(end < s or start > e for (s, e) in filmed):  # non-overlapping
            filmed.append((start, end))
            covered += end - start
    filmed.sort()

    def in_filmed(t: int) -> bool:
        return any(s <= t <= e for (s, e) in filmed)

    # candidate moments: every 3 s within filmed ranges
    candidates = [t for t in range(0, duration, 3) if in_filmed(t)]

    # ── ground truth: top-K engagement within filmed ranges, w/ human noise ──
    filmed_cands = sorted(candidates, key=lambda t: engagement[t], reverse=True)
    picks: List[int] = []
    for t in filmed_cands:
        jittered = min(duration - 1, max(0, t + int(rng.gauss(0, 3))))  # imperfect memory of exact instant
        if in_filmed(jittered) and all(abs(jittered - p) > 20 for p in picks):
            picks.append(jittered)
        if len(picks) >= n_ground_truth:
            break
    # human inconsistency: drop one real pick, add one arbitrary filmed moment
    if len(picks) > 3 and rng.random() < 0.7:
        picks.pop(rng.randrange(len(picks)))
    extra_pool = [t for t in candidates if all(abs(t - p) > 20 for p in picks)]
    if extra_pool and rng.random() < 0.6:
        picks.append(rng.choice(extra_pool))

    return Session(
        duration=duration, hr=hr, rest_bpm=rest_bpm, max_bpm=max_bpm,
        engagement=engagement, visual=visual, filmed=filmed,
        candidates=candidates, ground_truth=sorted(picks),
        meta={"activity": activity, "effort_mix": effort_mix, "hr_lag": HR_LAG},
    )
