# Prompt: Feedback-replay scoring in HighlightEngine — close the on-device tuning loop (#83 Step 2)

**File**: pdd/prompts/features/59-ios-feedback-replay-engine.md
**Created**: 2026-06-15
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Product-review roadmap [#100](https://github.com/harshal2802/snappet-mobile/issues/100) → #83 flagship intelligence (Step 2 of 2; PR A of the two stacked PRs)
**Source**: GitHub issue [#83](https://github.com/harshal2802/snappet-mobile/issues/83)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

The product's promised moat — "using the app improves the app" — dead-ended in a file: every reel edit
is logged to `highlight-feedback.jsonl`, but the only thing that replays it is a **Python** harness
(`experiments/feedback-replay/`), off-device, and `FeedbackStore.exportAll()`/`fileURL` had **zero
callers**. This PR ports the replay scoring into `HighlightEngine` as **pure, unit-testable Swift**, so
the app can re-weight the fusion blend on-device from the user's own feedback — honoring the project rule
that **weights change only from replayed feedback data**. (Step 1 / PR B adds the Vision scene scorer
that makes the re-weighted scene term meaningful; this PR is the data half and lands first as the fast
off-device gate.)

## Context the implementer needs

- The Python oracle to mirror **exactly**: `experiments/feedback-replay/replay.py` — `ConfigStats`
  (keep/pin/removal/export/regen rates, `effort_mix` from endorsed high/low, and a `satisfaction` score
  `0.4·keep + 0.9·pin + 0.7·export − 0.6·remove − 0.3·regen`, floored at 0) + `recommend()` thresholds
  (≥5 endorsed; mix ≥0.6 → HR-heavy, ≤0.4 → scene, else balanced; regen>0.15 note). `synth_feedback.py`
  seeds the data (`Random(42)`).
- The engine already owns `HighlightFeedbackEvent` (Codable, `Feedback.swift`) and `Highlight.Kind`
  (`high`/`low`) + `Activity` (string-Codable) — the synthetic JSONL decodes straight into them.
- `HighlightEngine` is a **pure SPM package — keep it platform-free** (no Vision/AVFoundation/UIKit).
- `FeedbackStore.exportAll()` (app side) reads the JSONL back; it needs a first real caller.

## Approach

- **Engine** (`FeedbackReplay.swift`, pure): `replay([HighlightFeedbackEvent]) -> [String: ConfigStats]`
  keyed by `"selectorName | configFingerprint"`, mirroring replay.py field-for-field; `recommend(_:)`
  matching its text; `ranked(_:)`; and `tunedWeighting(from:minEndorsed:) -> TunedWeighting?` — the
  data-driven HR-vs-scene split (HR weight tracks `effort_mix`, both clamped to `[0.2, 0.8]` so the
  fusion never collapses to one signal), returning `nil` until ≥`minEndorsed` endorsements exist.
- **Parity test** (`FeedbackReplayParityTests`): bundle the harness's seeded output as a test resource
  (`Fixtures/synthetic-feedback.jsonl`, from `synth_feedback.generate(Random(42))`), decode it through
  the engine's own `HighlightFeedbackEvent`, replay in Swift, and assert against replay.py's golden
  numbers + recommendation text. Plus the re-weighting invariants.
- **App** (`AppModel`): `recomputeFeedbackTuning()` reads `feedback.exportAll()` (first caller), replays,
  stores `feedbackTuning` + `os_log`s the recommendation; called on `bootstrap`. No engine behavior
  change yet (scene signal is 0 until PR B), so the blend is unchanged — gated by design.

## Output

- `ios/HighlightEngine/Sources/HighlightEngine/FeedbackReplay.swift`
- `ios/HighlightEngine/Tests/HighlightEngineTests/FeedbackReplayParityTests.swift` + `Fixtures/synthetic-feedback.jsonl`; `Package.swift` resource wiring.
- `AppModel.swift`: `feedbackTuning` + `recomputeFeedbackTuning()` + bootstrap call.

## Acceptance criteria

- [x] `HighlightEngine` gains replay scoring with **parity tests against the Python harness's golden outputs**.
- [x] Re-weighting runs on-device from local JSONL only (`exportAll()` first caller); weights change only via replayed feedback (`tunedWeighting` returns `nil` without enough endorsed data).
- [x] No platform imports added to `HighlightEngine`; `cd ios/HighlightEngine && swift test` stays green off-device.
- [x] App type-checks Swift 6; unit suite green.

## Constraints

- Engine stays platform-free + deterministic. Mirror replay.py exactly — the Python harness is the
  parity oracle, not a rough guide.

## Test plan

1. `cd ios/HighlightEngine && swift test` — parity + invariant suite green off-device.
2. App unit suite on device/sim; type-check Swift 6.
3. Re-derive the golden from `python3 run.py` and confirm the Swift assertions still match if replay.py changes.
