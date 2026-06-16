# Prompt: Vision scene scorer → FusionSelector (#83 Step 1, closes #83)

**File**: pdd/prompts/features/60-ios-vision-scene-scorer.md
**Created**: 2026-06-15
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Product-review roadmap [#100](https://github.com/harshal2802/snappet-mobile/issues/100) → #83 flagship intelligence (Step 1 of 2; PR B, stacked on PR A / #141)
**Source**: GitHub issue [#83](https://github.com/harshal2802/snappet-mobile/issues/83)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Reels were effectively HR-only: `SceneHighlightSelector` "returns 0 until a real vision pipeline is
wired", so the engine could pick a blurry pocket-shot over the visible crux move. This wires a **real
on-device Vision scene scorer** into the fusion via the existing `visualScore` seam — closing #83's
half-built intelligence. The HR-vs-scene weighting comes from PR A's replay-derived `tunedWeighting`,
so the scene term enters the blend ONLY once the user's own feedback justifies it.

## Context the implementer needs

- `SceneHighlightSelector` (`HighlightEngine/HighlightSelector.swift`) already has the pluggable
  `visualScore: (@Sendable (Double) -> Double)?` seam — today injected only in a unit test. **The engine
  must stay platform-free**: only the scalar score crosses in; all Vision/AVFoundation I/O lives in
  `ios/App/Snappet/Services/`.
- Vision is currently used only for receipt OCR — no scene scorer exists.
- Both reel paths build the engine via `AppModel.engine(boosting:)`: `ReelViewModel` (flagship) and
  `SessionHighlightViewModel` (WorkoutTracker session reel). Neither evaluated visual content.
- The engine timeline is **seconds from workout start**; a `MediaItem` carries `startOffset`. A frame
  sampled at media-time `t` in an item at `startOffset S` maps to engine-offset `S + t`.

## Approach

- **`Services/SceneScorer.swift`** (platform edge): for each video `MediaItem`, sample frames on a 1 s
  grid (`AVAssetImageGenerator`, downscaled to ≤480 px), and per frame compute three signals —
  **sharpness** (variance-of-Laplacian focus energy, Core Image), **saliency** (Vision
  `VNGenerateAttentionBasedSaliencyImageRequest`, mean), **presence** (Vision face + human rectangles,
  largest-box coverage). Relative-normalize sharpness/saliency across the sampled frames (scale-free),
  then combine via the **pure** `SceneScoring.score` (sharpness weighted highest so blur can't win).
  Emit `(workout-offset, score)` pairs; `SceneScorer.visualScore(from:)` gives the nearest-sample lookup.
- **`AppModel`**: `engine(boosting:scene:)` adds the scene term to the fusion **only when
  `feedbackTuning != nil`** — HR weight = `tuning.hrWeight`, scene weight = `tuning.sceneWeight`, effort
  stays 0.4. `sceneSelector(for:)` runs the Vision scorer only when tuning exists (else returns an empty
  selector — no cost, no change). Both reel paths pass the scene selector through.
- Real per-frame scoring is normalized/combined in the **pure** `SceneScoring`; the Vision/CI calls are
  the only impure part, kept behind an internal `frameSignals(_:)` the fixture test drives directly.

## Output

- `Services/SceneScorer.swift` (`SceneFrameSignals`, pure `SceneScoring`, `SceneScorer`).
- `AppModel.swift`: `sceneScorer`, `engine(boosting:scene:)`, `sceneSelector(for:)`.
- `ReelViewModel.swift`, `SessionHighlightViewModel.swift`: pass the scene selector.
- `SnappetTests/SceneScorerTests.swift`: synthesized sharp-vs-blurry/empty fixture proof + pure combiner tests.

## Acceptance criteria

- [ ] `FusionSelector` receives non-zero scene scores from real footage; a fixture test demonstrably
      penalizes blurry/empty frames.
- [ ] Re-weighting runs on-device from local JSONL only; weights change only via replayed feedback
      (scene term gated behind `feedbackTuning`).
- [ ] No platform imports added to `HighlightEngine`; `cd ios/HighlightEngine && swift test` stays green.
- [ ] App type-checks Swift 6; unit suite green; device-verified on real footage.

## Constraints

- Engine platform-free; Vision I/O in Services/; only scalar scores cross the boundary. No UI change.
- The scene term must NOT regress the existing `effortAligned`/achievement-window selection when there's
  no tuning (gated) — the engine's other selector tests must still pass.

## Test plan

1. `cd ios/HighlightEngine && swift test` — engine stays green + platform-free (no Vision import).
2. App unit suite (incl. `SceneScorerTests`: real CI/Vision metrics on synthesized frames) green.
3. Device: with feedback present (tuning active), generate a reel and confirm scene scores influence
   selection on real footage; sanity-check by eye. (Real-footage quality = device-verified.)
