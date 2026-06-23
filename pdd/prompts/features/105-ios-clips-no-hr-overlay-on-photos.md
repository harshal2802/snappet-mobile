# Prompt: Clips — no HR overlay on photos (stills are an instant, not a span)

**File**: pdd/prompts/features/105-ios-clips-no-hr-overlay-on-photos.md
**Created**: 2026-06-23
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Clips feed (prompts 82–94) → polish; user-reported "an HR overlay on a photo doesn't make sense".
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

In the Clips feed a captured **photo** renders the same live HR scorebug a **video** does — a BPM
readout, a sweeping chart, and AVG/PEAK values. But a photo is a single instant, not a span of effort:
there's no playhead for the dot to track, and the AVG/PEAK are computed over a *synthetic* 6-second
window (`FeedMedia.photoWindowSec`) the still never actually spanned. The overlay reads as
measured-over-time data the photo doesn't carry. Remove it: a photo should show its name tag only.

## Context the implementer needs

- The HR scorebug on every Clips surface is built by the ONE mapping
  `ClipHROverlay.make(clip:hrSeries:maxHR:restHR:tile:)`
  (`ios/App/Snappet/Features/Feed/ClipHROverlay.swift`). It returns `Payload?`; `nil` is already the
  "no HR → name tag only" path that **every** caller handles gracefully.
- There are exactly two callers, and both degrade on `nil` with no extra wiring:
  - `ClipsFeedView.swift` (the feed poster + inline player) — its `hrOverlay` is `if let payload { … }`.
  - `MediaBrowserView.swift` `MediaPage` (the fullscreen viewer) — its overlay is `if let overlay { … }`.
- The inline `ClipMediaSurface` is only mounted for `kind == "video"` in the feed, and in fullscreen it
  takes the payload only to drive the video playhead `fraction` (a photo has none) — so a `nil` payload
  for a photo is already safe everywhere.
- `MediaInput.kind` is `"photo" | "video"` (bridged from `SessionMedia.Kind`); the rest of the feed
  already branches on `kind == "video"` (ClipsFeedView mount/mute, ClipMediaSurface load).
- Out of scope: the small peak-BPM badge on the secondary "Media" grid thumbnails
  (`FeedMedia.clipHR` → `MediaBrowserView.tile` / `FeedMediaCarousel`) is a different, tiny metadata
  chip, not the prominent scorebug the user flagged — left unchanged.

## Approach

- Gate the SSOT, not the call sites: add `guard clip.kind == "video" else { return nil }` at the top of
  `ClipHROverlay.make`. One change removes the scorebug from photos in the feed AND the fullscreen viewer
  consistently (they can't drift), and no caller needs editing because `nil` is already handled.
- Keep it pure (Foundation) so it stays unit-tested in `SnappetTests`.

## Output

- `ios/App/Snappet/Features/Feed/ClipHROverlay.swift` — the photo guard in `make` (+ comment on why).
- `ios/App/SnappetTests/ClipHROverlayTests.swift` — `testMakeReturnsNilForPhotosEvenWithHR`: a photo with
  HR squarely in its window returns `nil`; the same window/HR on a video still builds a payload (proving
  it's the *kind*, not missing data, that suppresses it).
- `docs/knowledge-graph/data.js` — `clips-hr-overlay` node desc/tags note photos are excluded.
- `pdd/context/decisions.md`, `pdd/context/project.md` — record the choice + keep the Clips state true.

## Acceptance criteria

- [ ] A photo clip in the Clips feed shows the climb/exercise name tag but **no** HR scorebug.
- [ ] Opening that photo in the fullscreen viewer also shows no scorebug (consistent with the feed).
- [ ] A video clip is unchanged — live BPM + chart + AVG/PEAK still ride the playing clip.
- [ ] App type-checks against the iOS 18 SDK (Swift 6, 0 warnings); full `SnappetTests` green incl. the
      new `ClipHROverlayTests` case.
- [ ] No platform imports added to `HighlightEngine`; `decisions.md` updated.

## Constraints

- On-device only; no backend. Keep the change **pure** (Foundation) so it unit-tests without a sim.
- Don't special-case the feed vs the viewer — gate the one mapping so they can't disagree.

## Test plan

1. `xcodebuild test … -only-testing:SnappetTests` — 0-warning build, suite green incl.
   `testMakeReturnsNilForPhotosEvenWithHR`.
2. On a device/sim with a real session that has both photos and videos: confirm photos show name-only and
   videos keep the live HR overlay, in both the feed and the fullscreen viewer (device-owed — the sim has
   no Photos/HR).
