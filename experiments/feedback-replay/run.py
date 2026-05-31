"""
Feedback-replay tuner runner.

Usage:
    python3 run.py                       # run on seeded SYNTHETIC feedback (no real data needed)
    python3 run.py path/to/feedback.jsonl   # run on a real on-device log

Output: a markdown report ranking each (selector, configFingerprint) by satisfaction,
with keep/pin/removal/export rates and an empirical effort_mix estimate, plus a
recommended tuning direction.

The on-device log lives in the app's Application Support dir as `highlight-feedback.jsonl`
(FeedbackStore). Pull it via Xcode's device container or the app's future "export my data".
"""

import random
import sys
from typing import List

from loader import Event, load, parse_line
from replay import recommend, replay
from synth_feedback import generate


def _load_or_synth(argv: List[str]) -> tuple[List[Event], bool]:
    if len(argv) > 1:
        return load(argv[1]), False
    rng = random.Random(42)
    lines = generate(rng)
    events = [e for e in (parse_line(ln) for ln in lines) if e is not None]
    return events, True


def main():
    events, synthetic = _load_or_synth(sys.argv)
    stats = replay(events)

    print("# Highlight-feedback replay — tuning report\n")
    if synthetic:
        print("> ⚠️ **SYNTHETIC feedback** (seeded). This proves the *tooling*, not the product. "
              "Pass a real `highlight-feedback.jsonl` path to analyze on-device data.\n")
    print(f"_{len(events)} events · {len(stats)} config(s)_\n")

    print("| selector | config | shown | keep | pin | remove | export | regen/shown | effort_mix | satisfaction |")
    print("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    for st in sorted(stats.values(), key=lambda s: s.satisfaction, reverse=True):
        sel, fp = st.key.split(" | ", 1)
        print(f"| {sel} | {fp} | {st.shown} | {st.keep_rate:.2f} | {st.pin_rate:.2f} | "
              f"{st.removal_rate:.2f} | {st.export_survivorship:.2f} | {st.regen_per_shown:.2f} | "
              f"{st.effort_mix:.2f} | **{st.satisfaction:.2f}** |")

    print("\n## Recommendation\n")
    print(recommend(stats))

    print("\n## How this closes the loop\n")
    print("- `satisfaction` ranks configs by what users *did* (keep/pin/export vs remove/regenerate).")
    print("- `effort_mix` is measured from endorsed highlights' high/low kind — the exact unknown the "
          "efficacy spike (`../hr-highlight-efficacy/RESULTS.md`) had to *assume*. With enough real "
          "sessions it sets the HR-vs-content weighting and applies the GO / fusion / NO-GO rule.")


if __name__ == "__main__":
    main()
