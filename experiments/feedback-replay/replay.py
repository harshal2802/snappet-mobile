"""
Replay highlight-feedback events into per-config quality metrics.

The point (#60 §E): the app ships a best-guess engine and logs what it proposed vs
what the user kept/removed/pinned/exported. Replaying that tells us which
`(selector, configFingerprint)` the user actually preferred — turning the synthetic
NEEDS-REAL-DATA verdict into a data-driven direction, and estimating `effort_mix`
(the one unknown the efficacy spike couldn't settle).

Pure stdlib.
"""

from dataclasses import dataclass
from typing import Dict, List

from loader import Event


@dataclass
class ConfigStats:
    key: str
    shown: int = 0
    kept: int = 0
    removed: int = 0
    pinned: int = 0
    exported: int = 0
    regenerated: int = 0
    added: int = 0
    # effort_mix bookkeeping: of the highlights the user *endorsed* (pinned/exported),
    # how many were "high" (effort) vs "low" (recovery/scenic)?
    endorsed_high: int = 0
    endorsed_total: int = 0

    @property
    def keep_rate(self) -> float:
        return self.kept / self.shown if self.shown else 0.0

    @property
    def removal_rate(self) -> float:
        return self.removed / self.shown if self.shown else 0.0

    @property
    def pin_rate(self) -> float:
        return self.pinned / self.shown if self.shown else 0.0

    @property
    def export_survivorship(self) -> float:
        return self.exported / self.shown if self.shown else 0.0

    @property
    def regen_per_shown(self) -> float:
        return self.regenerated / self.shown if self.shown else 0.0

    @property
    def effort_mix(self) -> float:
        """Empirical effort_mix: share of endorsed moments that were effort (high) —
        this is exactly the unknown the efficacy spike had to assume."""
        return self.endorsed_high / self.endorsed_total if self.endorsed_total else 0.0

    @property
    def satisfaction(self) -> float:
        """A single 0..1-ish score. Positive signals (keep/pin/export) minus negative
        (remove, and regenerate as a weak whole-set negative). Pins weighted highest —
        they are the strongest explicit positive (#60 §E)."""
        s = (0.4 * self.keep_rate
             + 0.9 * self.pin_rate
             + 0.7 * self.export_survivorship
             - 0.6 * self.removal_rate
             - 0.3 * self.regen_per_shown)
        return max(0.0, s)


def replay(events: List[Event]) -> Dict[str, ConfigStats]:
    stats: Dict[str, ConfigStats] = {}
    for e in events:
        key = f"{e.selector_name} | {e.config_fingerprint}"
        st = stats.setdefault(key, ConfigStats(key=key))
        if e.action == "shown":
            st.shown += 1
        elif e.action == "kept":
            st.kept += 1
        elif e.action == "removed":
            st.removed += 1
        elif e.action == "pinned":
            st.pinned += 1
            _endorse(st, e)
        elif e.action == "exported":
            st.exported += 1
            _endorse(st, e)
        elif e.action == "regenerated":
            st.regenerated += 1
        elif e.action == "added":
            st.added += 1
    return stats


def _endorse(st: ConfigStats, e: Event) -> None:
    if e.highlight_kind is not None:
        st.endorsed_total += 1
        if e.highlight_kind == "high":
            st.endorsed_high += 1


def recommend(stats: Dict[str, ConfigStats]) -> str:
    if not stats:
        return "No data — use the app to generate feedback first."
    # Tie-break alphabetically by key so the order is deterministic and matches the Swift port
    # (FeedbackReplay.ranked). A bare satisfaction sort falls back to dict-insertion order, which a
    # Swift Dictionary can't reproduce — so the key tie-break is the canonical, parity-safe choice.
    ranked = sorted(stats.values(), key=lambda s: (-s.satisfaction, s.key))
    best = ranked[0]
    lines = [f"Best config so far: **{best.key}** (satisfaction {best.satisfaction:.2f})."]
    mix = best.effort_mix
    if best.endorsed_total >= 5:
        if mix >= 0.6:
            lines.append(f"Empirical effort_mix ≈ {mix:.2f} → users endorse mostly EFFORT moments: "
                         "lean the selector HR-heavy (raise wLevel/wSlope share).")
        elif mix <= 0.4:
            lines.append(f"Empirical effort_mix ≈ {mix:.2f} → users endorse mostly NON-effort moments: "
                         "a content/scene signal matters — push the fusion toward scene.")
        else:
            lines.append(f"Empirical effort_mix ≈ {mix:.2f} → mixed; a balanced HR+scene fusion fits.")
    else:
        lines.append("Not enough endorsed highlights yet to estimate effort_mix (need ≥5).")
    if best.regen_per_shown > 0.15:
        lines.append("High regenerate rate → the default cut is missing; widen maxHighlights or retune scoring.")
    return "\n".join(lines)
