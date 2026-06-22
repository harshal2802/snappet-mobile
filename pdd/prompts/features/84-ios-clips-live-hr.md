# Prompt: Clips — one HR/video overlay source of truth + live HR in the fullscreen viewer

**File**: pdd/prompts/features/84-ios-clips-live-hr.md
**Created**: 2026-06-22
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: prompt 83 (Clips tap-to-play) → Phase 0 of the inline-render plan (decisions 2026-06-22)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Two things, both prerequisites for inline playback (prompt 85):

1. **One source of truth** for mapping a single clip → its HR + video overlay data. Today the still
   poster (`ClipPosterView`) and the fullscreen viewer (`PagedMediaViewer`) each rebuild the
   window → values → scorebug chain by hand, and each surface that wants a live playhead would invent
   its own `fraction`. Centralize it so the poster, the inline player, and the viewer **cannot drift**.
2. **Live HR in the fullscreen viewer** — make its scorebug track the playing video (animated BPM +
   chart playhead), the way the clip editor does, instead of the static `fraction = 1.0`. This is the
   cheap, low-risk way to validate the live-HR feel on device before inline playback.

## Context the implementer needs

- The editor already drives a live HR chart from video time: `StudioEditorViewModel.attachTransport`
  (`addPeriodicTimeObserver` → `currentTime`) → `previewElementFraction` (= `currentTime/totalDuration`)
  → `HRTileView(fraction:)`. `HRTileView`'s `fraction` already animates the live metrics + the
  `PremiumHRCurve` playhead dot; the `.scorebug` template's `.bpm`/`.zone` default to `live` so a
  changing fraction makes them track.
- The fullscreen `MediaPage` owns the `AVQueuePlayer` + `AVPlayerLooper` and renders via
  `StudioPlayerLayerView`. Its HR tile is currently static (`fraction: 1.0`).
- The window slice is `FeedMedia.clipHRWindow` (rebased to clip-local `[0, duration]`), so a clip's
  video time maps **directly** to its HR position — but ONLY if both use the same duration denominator.

## Approach

- New pure `Features/Feed/ClipHROverlay.swift` (Foundation-only; unit-tested in `SnappetTests`):
  - `make(clip:hrSeries:maxHR:restHR:) -> Payload?` — `window → HROverlayValues → .feedClipScorebug`
    (`nil` when the window has no HR).
  - `windowDuration(_:)` — the one denominator both the values' chart AND the playhead fraction measure.
  - `fraction(videoTime:clip:) -> Double` — video time → playhead `0…1` over the window (loop-relative,
    guarded). The single definition of "video time → HR position".
- Refactor `ClipPosterView` (poster, static `1.0`) and `PagedMediaViewer.overlay(for:)` to call
  `ClipHROverlay.make` (delete the private `ClipOverlay` struct).
- `MediaPage`: drive the HR tile with a live `playbackFraction` — a `Timer.publish` ticker reads
  `player.currentTime()` while playing and computes `ClipHROverlay.fraction` (cleaner under Swift-6 than
  capturing the struct in an `addPeriodicTimeObserver` closure). Paused / photo / off-center pages no-op.

## Output

- `ios/App/Snappet/Features/Feed/ClipHROverlay.swift` (the SSOT) + `SnappetTests/ClipHROverlayTests.swift`.
- `ios/App/Snappet/Features/Feed/ClipsFeedView.swift`, `…/MediaBrowserView.swift` — use the SSOT; viewer goes live.
- `docs/knowledge-graph/data.js`, `pdd/context/decisions.md`, `pdd/context/project.md`.

## Acceptance criteria

- [ ] One mapping (`ClipHROverlay`) feeds the poster, the viewer, and (next) the inline player; the
      private `ClipOverlay` duplicate is gone.
- [ ] In the fullscreen viewer, a playing clip's scorebug BPM + chart dot track the video; a paused clip
      / photo shows the window aggregate.
- [ ] `ClipHROverlay` is pure + covered by `ClipHROverlayTests` (make / windowDuration / fraction).
- [ ] App type-checks (Swift 6, 0 warnings); full `SnappetTests` green; Recap viewer + export unregressed.

## Constraints

- No new player; reuse `MediaPage`'s. Single-active discipline unchanged.
- The live-HR animation only renders with real Photos + a captured HR series on a physical iPhone — the
  sim verification is build + tests + the pure SSOT; the visual is owed on-device.

## Test plan

1. `xcodegen generate && xcodebuild test … -only-testing:SnappetTests` — `ClipHROverlayTests` + the whole
   suite green; 0 warnings. Run `FeedMediaCarouselUITests` + `RecapClipExportUITests` (viewer regression).
2. On a device: open a clip with HR fullscreen → the BPM + chart dot sweep with playback; pause → aggregate.
