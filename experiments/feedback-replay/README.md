# feedback-replay — offline tuner for the highlight engine

Reads the on-device `highlight-feedback.jsonl` the app writes (every reel logs what the engine
proposed vs what the user kept / removed / pinned / regenerated / exported — see
`ios/App/Snappet/Core/FeedbackStore.swift` and `HighlightEngine/.../Feedback.swift`), reconstructs
per-highlight outcomes, and scores each `(selector, configFingerprint)` so we can see **which config
users actually preferred** — and measure `effort_mix` empirically. Refs
[Snappet#60](https://github.com/harshal2802/Snappet/issues/60) §E. Prompt:
`pdd/prompts/features/06-feedback-replay-tuner.md`.

This is the back half of the data loop the app was built to feed: *using the app produces the dataset
that optimizes the app.*

## Run

```bash
cd experiments/feedback-replay
python3 run.py                          # seeded SYNTHETIC feedback — runs with no real data
python3 run.py /path/to/highlight-feedback.jsonl   # a real on-device log
```

Pure stdlib, seeded.

## Getting the real log off a device

`FeedbackStore` writes to the app's Application Support directory. Pull it via Xcode → Devices &
Simulators → the app's container, or via the app's future "export my data" affordance.

## Files

- `loader.py` — tolerant JSONL parser (handles Swift's omitted-nil-optional encoding).
- `replay.py` — per-config metrics (keep/pin/removal/export/regen rates), a single `satisfaction`
  score (pins weighted highest), and an empirical `effort_mix`; plus a tuning recommendation.
- `synth_feedback.py` — seeded generator emitting the exact app JSON shape, so the tool runs today.
- `run.py` — report runner.

## What it proves (and doesn't)

The synthetic run proves the **tooling** end-to-end (parse → reconstruct → rank → recommend). It says
**nothing** about the product — that needs the real on-device log across enough sessions, at which
point `effort_mix` + the per-config satisfaction apply the GO / fusion / NO-GO rule in
`../hr-highlight-efficacy/RESULTS.md`.
