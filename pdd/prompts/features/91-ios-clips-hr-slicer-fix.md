# Prompt: Clips — HR overlay matches the video (route through HRWindowSlicer)

**File**: pdd/prompts/features/91-ios-clips-hr-slicer-fix.md
**Created**: 2026-06-22
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Clips feed (prompts 82–90) → playback-polish pass (1 of 4); user-reported "HR overlay is not matching the video".
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

On the Clips feed the HR scorebug/curve does **not** track the playing clip: the live BPM + chart dot
freeze (often at the very start, with a blank curve) or sit at a near-constant value, and the still
poster's peak/avg reads as a 1-bpm range. This makes the overlay feel disconnected from the footage.
Fix it so the feed overlay slices the **same** HR window the Studio preview and the burned export use,
and the live dot tracks the video from 0→end.

## Context the implementer needs

Root cause (verified by a deep review, not the obvious suspect):

- `offsetSec` / `durationSec` **are** populated correctly on every capture path
  (`SessionMediaService.offset = max(0, creationDate − startedAt)`, `durationSec = asset.duration`), and
  `HRPoint.t` shares the same session-relative origin — so the window *alignment* is sound. The bug is
  the **slicer**.
- `ClipHROverlay.make` (ios/App/Snappet/Features/Feed/ClipHROverlay.swift:32) slices HR via the **naive**
  `FeedMedia.clipHRWindow` (FeedMedia.swift:84-93): a strict `t >= offset && t <= end` filter with a crude
  `±8s`-of-`offset` fallback — **no interpolated endpoints, no ≥2-point guarantee, no edge-clamp**. This
  is exactly the strict-window regression `HRWindowSlicer` was built to kill (decisions.md prompt-29,
  2026-06-09). The Studio/export already route through `HRWindowSlicer` (StudioHRPlacement); the Clips
  feed silently bypassed it.
- Failure modes that produce the user's symptom:
  1. On sparse/real band data the strict window misses and the ±8s fallback can return a **single**
     sample → `maxT = 0` → `ClipHROverlay.fraction` hits its `maxT > 0` guard and returns `0` → the dot
     **freezes at the left edge** and the curve (needs ≥2 points) **doesn't draw**.
  2. Even with data, `maxT` (last in-window sample's clip-local `t`) is `< durationSec`, so the dot
     **pins at the chart's right edge** for the final `(durationSec − maxT)`s of every loop.
- `HRWindowSlicer.slice(_:start:span:)` (HRWindowSlicer.swift) fixes both at once: it rebases to
  `[0, span]`, **brackets the window with interpolated endpoints at `t=0` and `t=span`** (so the last
  sample's `t == span == durationSec == windowDuration(clip) == the AVPlayerLooper loop boundary`),
  **guarantees ≥2 points**, and stays honestly empty only when the window is `> ±90s` (≈ the media
  discovery pad) outside coverage.

## Approach

- **One slicer.** In `FeedMedia.clipHRWindow(offsetSec:durationSec:hrSeries:)`, replace the strict-filter +
  ±8s body with a single call to
  `HRWindowSlicer.slice(hrSeries, start: offsetSec, span: durationSec ?? Self.photoWindowSec)`. Keep the
  signature + doc-comment contract (clip-local `[0, span]`, honest-empty), now delegating to the hardened
  slicer.
- **Poster chip parity.** Route `FeedMedia.clipHR(offsetSec:durationSec:hrSeries:maxHR:)` (the still
  poster's peak/avg chip) through the **same** sliced window (compute peak/avg/zone over
  `HRWindowSlicer.slice(...)`'s output) so the chip and the inline overlay can't disagree.
- `ClipHROverlay.fraction` needs **no change** — it already divides folded video time by the window's
  `maxT`; that now equals `durationSec`, so it tracks 1:1. The `truncatingRemainder` fold stays as
  defensive code.
- **Tests.** Update the unit tests that bake in the old behavior: `FeedMediaTests` (single-sample
  `count == 1` / strict-window-empty expectations) and `ClipHROverlayTests`
  (`testFractionAlignsWithChartMaxTNotDuration` — now `maxT == span`). Assert the new guarantees: result
  has ≥2 points whenever HR exists within ±90s, the last point's `t == span`, and `fraction(videoTime: span)`
  ≈ 1.0.

## Output

- `ios/App/Snappet/Features/Feed/FeedMedia.swift` — `clipHRWindow` + `clipHR` delegate to `HRWindowSlicer`.
- `ios/App/SnappetTests/FeedMediaTests.swift`, `ios/App/SnappetTests/ClipHROverlayTests.swift` — updated
  expectations + new guarantee assertions.
- `docs/knowledge-graph/data.js` — note the Clips HR overlay now shares the `HRWindowSlicer` SSOT edge.
- `pdd/context/decisions.md` — record "Clips feed HR uses the one hardened slicer (was a second naive
  slicer); fixes feed≠video and feed≠export drift".

## Acceptance criteria

- [ ] Inline + fullscreen Clips HR dot/BPM track the playing clip start→end — no freeze at the start, no
      pin-at-end tail; the curve always draws (≥2 points) when HR exists in/near the window.
- [ ] The still poster's peak/avg chip matches the inline overlay (same sliced window).
- [ ] The feed HR window equals what the Studio preview / export burn for the same clip (one slicer,
      WYSIWYG); honestly blank only when no HR within ±90s of the window.
- [ ] App type-checks against the iOS 18 SDK (Swift 6, 0 warnings); full `SnappetTests` green.
- [ ] No platform imports added to `HighlightEngine`; `decisions.md` updated.

## Constraints

- On-device only; no backend. Keep the change **pure** (Foundation) so it unit-tests in `SnappetTests`.
- Do **not** add a third slice path — delete/forward the second so a strict-filter slicer can't drift back.
- Type-check ≠ device run: the live sweep is device-verifiable; flag it.

## Test plan

1. `xcodebuild test … -only-testing:SnappetTests` — 0-warning build, suite green incl. the updated
   `FeedMediaTests` / `ClipHROverlayTests`.
2. On a device/sim with a real clip: play it inline + fullscreen and confirm the BPM/curve/dot sweep with
   the video (no frozen overlay), and the poster chip matches.
