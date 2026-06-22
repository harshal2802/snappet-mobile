# Prompt: Clips — tap a poster to play INLINE (not a fullscreen pop-up)

**File**: pdd/prompts/features/85-ios-clips-inline-play.md
**Created**: 2026-06-22
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: prompt 84 (SSOT + live HR in viewer) → Phase 1 of the inline-render plan (decisions 2026-06-22)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Tapping a Clips poster should play the clip **in place, inside the carousel** — replacing the fullscreen
pop-up player (prompt 83) — with the HR scorebug going **live** (BPM + chart dot track the video). One
player engine, reused; no autoplay-on-scroll (that inline hero was dropped in R12 for rendering a black
box — see decisions 2026-06-22).

## Context the implementer needs

- The fullscreen `MediaPage` (prompt 84) already owns the player engine: `AVQueuePlayer` + `AVPlayerLooper`,
  async PHAsset load, single-active `isActive` play/pause, `.onDisappear` teardown, the `Timer.publish`
  live-HR ticker → `ClipHROverlay.fraction` → `HRTileView(fraction:)`, and `StudioPlayerLayerView`.
- The HR overlay mapping is the `ClipHROverlay` SSOT (prompt 84). Reuse it verbatim.
- The black box that killed the R12 inline hero came from the autoplay **scroll-center coordinator**
  assigning players to recycled rows — NOT the player layer. Tap-to-play on the visible card is the
  stable, fullscreen-equivalent scenario, so it is the safe shape.

## Approach

- **Extract `ClipMediaSurface`** (new `Features/Feed/ClipMediaSurface.swift`): the ONE media engine —
  owns the player/looper/photo-image + the live-HR ticker, loads from the clip's `localIdentifier`, plays
  only while `isActive`, tears down on disappear, and drives a `@Binding fraction` (via
  `ClipHROverlay.fraction`). Renders the media layer (player / image / loading / placeholder) + tap-to-
  pause. Both surfaces use it, so there's a single `AVPlayerLayer` lifecycle.
- **Rewire `MediaPage`** to compose `ClipMediaSurface` (it keeps its scrim + HR tile + chrome). Recap's
  viewer behaviour is unchanged.
- **Inline in the poster**: `ClipPosterView` shows the still `ClipThumbnail` until tapped; tapping makes it
  the feed's single active clip → it renders `ClipMediaSurface` in place (framed in the carousel page) and
  its HR tile goes live off the same `fraction`. Single-active across the feed is **tap-driven**
  ("last tapped wins") — a `playingClip` ref (postID + page) on `ClipsFeedView`, NOT scroll geometry.
  Swiping the carousel or tapping another clip stops the previous. Remove the prompt-83 fullscreen-cover
  tap + the now-unused `clipsViewer` factory.

## Output

- `ios/App/Snappet/Features/Feed/ClipMediaSurface.swift` (the shared engine).
- `ios/App/Snappet/Features/Feed/MediaBrowserView.swift` (MediaPage → uses the surface; drop `clipsViewer`).
- `ios/App/Snappet/Features/Feed/ClipsFeedView.swift` (inline tap-to-play + `playingClip` single-active).
- `docs/knowledge-graph/data.js`, `pdd/context/decisions.md`, `pdd/context/project.md`.

## Acceptance criteria

- [ ] Tapping a video poster plays it INLINE in the carousel (no fullscreen pop-up); the HR scorebug goes
      live (BPM + dot track the video). Tapping a photo stays a still.
- [ ] Only ONE clip plays across the whole feed (tap another / swipe the carousel stops the previous).
- [ ] One player engine (`ClipMediaSurface`) backs both the inline poster and the fullscreen viewer; no
      duplicated AVPlayer lifecycle.
- [ ] Recap's fullscreen viewer + export are unregressed (FeedMediaCarousel + RecapClipExport UITests).
- [ ] App type-checks (Swift 6, 0 warnings); full `SnappetTests` green.

## Constraints

- No autoplay-on-scroll, no scroll-center coordinator (R12). One live player at a time; neighbor pages
  stay still posters (no eager players).
- Inline AVPlayerLayer rendering is the R12 risk — **must be device-verified** (the sim has no Photos and
  never reproduced the black box). The fullscreen viewer remains the proven fallback.

## Test plan

1. `xcodegen generate && xcodebuild test … -only-testing:SnappetTests` + FeedMediaCarousel + RecapClipExport
   — build 0-warning, suite green, viewer unregressed.
2. On a device with clips: tap a video poster → it plays inline + the HR sweeps; swipe → stops; tap another
   → the first stops; tap a photo → stays still. Watch specifically for a black inline frame (the R12 mode).
