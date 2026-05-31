"""
Loader for the on-device highlight-feedback log.

The app writes one JSON object per line to `highlight-feedback.jsonl` via `FeedbackStore`
(see ios/App/Snappet/Core/FeedbackStore.swift). Each line is a Swift-`Codable`
`HighlightFeedbackEvent`. Swift's JSONEncoder OMITS nil optionals, so `atOffset`,
`score`, and `highlightKind` may be absent — this loader tolerates that.

Pure stdlib. No app dependency; we just read the JSON shape.
"""

import json
from dataclasses import dataclass
from typing import Dict, List, Optional


# Mirrors HighlightFeedbackEvent.Action (Feedback.swift).
ACTIONS = {"shown", "kept", "removed", "added", "reordered", "pinned", "regenerated", "exported"}


@dataclass
class Event:
    workout_id: str
    activity: str
    action: str
    selector_name: str
    config_fingerprint: str
    timestamp: float
    at_offset: Optional[float] = None
    score: Optional[float] = None
    highlight_kind: Optional[str] = None   # "high" | "low" | None


def parse_line(line: str) -> Optional[Event]:
    line = line.strip()
    if not line:
        return None
    try:
        d = json.loads(line)
    except json.JSONDecodeError:
        return None
    # Required keys; skip malformed lines rather than crash.
    try:
        return Event(
            workout_id=d["workoutId"],
            activity=d["activity"],
            action=d["action"],
            selector_name=d["selectorName"],
            config_fingerprint=d["configFingerprint"],
            timestamp=float(d["timestamp"]),
            at_offset=_optf(d.get("atOffset")),
            score=_optf(d.get("score")),
            highlight_kind=d.get("highlightKind"),
        )
    except (KeyError, TypeError, ValueError):
        return None


def _optf(v) -> Optional[float]:
    return float(v) if v is not None else None


def load(path: str) -> List[Event]:
    with open(path, "r", encoding="utf-8") as f:
        return [e for e in (parse_line(ln) for ln in f) if e is not None]


def by_config(events: List[Event]) -> Dict[str, List[Event]]:
    """Group events by (selectorName | configFingerprint) — the unit we compare."""
    out: Dict[str, List[Event]] = {}
    for e in events:
        key = f"{e.selector_name} | {e.config_fingerprint}"
        out.setdefault(key, []).append(e)
    return out
