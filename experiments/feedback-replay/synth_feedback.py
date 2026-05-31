"""
Seeded synthetic feedback generator — lets the replay tuner run BEFORE any real
`highlight-feedback.jsonl` exists. It emits the exact JSON shape the app writes
(HighlightFeedbackEvent), including OMITTED nil optionals, so the loader is exercised
the same way it will be on real data.

This proves the TOOLING, not the product. Real verdicts need the real on-device log.
"""

import json
from typing import Dict, List


def _event(workout_id: str, activity: str, action: str, selector: str, fp: str,
           ts: float, at_offset=None, score=None, kind=None) -> str:
    """Build one JSONL line, omitting nil optionals exactly like Swift's JSONEncoder."""
    d: Dict = {
        "workoutId": workout_id,
        "activity": activity,
        "action": action,
        "selectorName": selector,
        "configFingerprint": fp,
        "timestamp": ts,
    }
    if at_offset is not None:
        d["atOffset"] = at_offset
    if score is not None:
        d["score"] = score
    if kind is not None:
        d["highlightKind"] = kind
    return json.dumps(d)


def generate(rng, n_workouts: int = 12) -> List[str]:
    """Two competing configs. Config A is 'good' (users keep/pin/export, mostly effort
    moments); config B is 'worse' (more removals + regenerates). Seeded → reproducible."""
    lines: List[str] = []
    selector = "HRHighlightSelector"
    configs = {
        "A": {"fp": "sm9_lag6_l60_s40_g20", "keep": 0.75, "pin": 0.30, "regen": 0.05, "high_bias": 0.7},
        "B": {"fp": "sm13_lag6_l70_s30_g25", "keep": 0.55, "pin": 0.12, "regen": 0.25, "high_bias": 0.5},
    }
    ts = 1_700_000_000.0
    for w in range(n_workouts):
        cfg_name = "A" if w % 2 == 0 else "B"
        cfg = configs[cfg_name]
        activity = rng.choice(["running", "climbing", "dance"])
        wid = f"wk-{cfg_name}-{w}"
        n_highlights = rng.randint(6, 9)

        # The whole set is shown.
        highlights = []
        for i in range(n_highlights):
            kind = "high" if rng.random() < cfg["high_bias"] else "low"
            score = round(rng.uniform(0.3, 0.95), 3)
            at = round(rng.uniform(0, 1800), 1)
            highlights.append((at, score, kind))
            ts += 0.5
            lines.append(_event(wid, activity, "shown", selector, cfg["fp"], ts,
                                 at_offset=at, score=score, kind=kind))

        # Sometimes the user regenerates (weak whole-set negative).
        if rng.random() < cfg["regen"]:
            ts += 1.0
            lines.append(_event(wid, activity, "regenerated", selector, cfg["fp"], ts))

        # Per-highlight edits: keep / remove / pin.
        kept = []
        for (at, score, kind) in highlights:
            r = rng.random()
            ts += 0.3
            if r < cfg["pin"]:
                lines.append(_event(wid, activity, "pinned", selector, cfg["fp"], ts,
                                    at_offset=at, score=score, kind=kind))
                kept.append((at, score, kind))
            elif r < cfg["keep"]:
                kept.append((at, score, kind))
            else:
                lines.append(_event(wid, activity, "removed", selector, cfg["fp"], ts,
                                    at_offset=at, score=score, kind=kind))

        # Export: survivors logged kept + exported.
        for (at, score, kind) in kept:
            ts += 0.2
            lines.append(_event(wid, activity, "kept", selector, cfg["fp"], ts,
                                at_offset=at, score=score, kind=kind))
        for (at, score, kind) in kept:
            ts += 0.2
            lines.append(_event(wid, activity, "exported", selector, cfg["fp"], ts,
                                at_offset=at, score=score, kind=kind))
    return lines
