# Prompt: Clips — tap-to-fullscreen player with transport (play/pause + scrubber)

**File**: pdd/prompts/features/94-ios-clips-fullscreen-transport.md
**Created**: 2026-06-22
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Clips playback-polish pass (4 of 4) → user-reported "tap to full screen … play/pause … control the timeline in full screen".
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## ⚠️ Risk note (READ FIRST)

Inline clip rendering carries the R12 "black box" risk (decisions.md). This prompt reuses the **proven**
single-active `ClipMediaSurface` + `PagedMediaViewer`; the only new playback wrinkle is **seeking** a
looping clip. Device-verify the scrub + HR sync before relying on it.

## Goal

Tapping a **playing** inline clip opens a **fullscreen** player with **play/pause** and a **scrubbable
timeline** (plus the audio toggle and close), with the HR overlay still tracking the (now scrubbable)
playhead. Inline stays a muted-by-default preview whose only control is the 🔊 toggle (prompt 93).

## Context the implementer needs

- A reusable fullscreen viewer already exists: `PagedMediaViewer` / `MediaPage` (MediaBrowserView.swift) —
  a `fullScreenCover` paged `TabView(.page)` that plays the real clip, is single-active, loops, and pins
  the `HRTileView` overlay via the shared `ClipHROverlay` SSOT. Its `card` field is already `FeedCard?`
  (drops Share when nil) and it already takes a Clips-specific `restHR`.
- What's missing is exactly the user's ask: **no play/pause button and no scrubber** — playback is
  auto-play-on-active + tap-to-toggle, and `ClipMediaSurface` keeps its `AVPlayer` private.
- Do **not** use `AVPlayerViewController` / `VideoPlayer`: the system transport can't composite the burned
  HR scorebug — which is why the app uses the controls-free `StudioPlayerLayerView` everywhere it overlays.
- The Studio's scrubber (`StudioEditorViewModel.seek` / `addPeriodicTimeObserver`) is the conceptual
  template but is composition/multi-clip — not directly reusable for one looping clip.
- Currently tapping a playing inline clip toggles play/pause; this prompt **reassigns** that tap to present
  fullscreen (the still-poster tap still starts inline play; inline pause is no longer needed — scrolling
  away stops it).

## Approach

- **Reach the viewer from Clips.** Add a Clips factory on `MediaBrowserView`, e.g.
  `static func clipsViewer(clips:startIndex:hrSeries:maxHR:restHR:nameFor:tile:) -> some View` building
  `PagedMediaViewer(card: nil, clipContext: nil, restHR:)`; pass the post's `hrTile` so fullscreen builds
  overlays via `ClipHROverlay.make(... tile:)` (same WYSIWYG tile as the poster).
- **Present from the feed.** In `ClipsFeedView`, tapping the **playing** inline `ClipPosterView` sets a
  `CarouselViewerBox?` (reuse the existing Identifiable index box) → `.fullScreenCover(item:)` scoped to
  `post.clips` at the current `page`, with the post's `hr.series/maxHR/restHR` + `hrTile`. Remove the
  inline play/pause-on-tap.
- **Transport.** Expose play/pause + seek + time from `ClipMediaSurface` to its caller via a small
  observable controller (e.g. `@Observable ClipPlaybackController { isPlaying; currentTime; duration;
  func togglePlay(); func seek(toFraction:) }`) the surface drives from an `addPeriodicTimeObserver` and
  the caller binds. Add a `MediaTransportBar` (play/pause button + `Slider` + `m:ss / m:ss` labels) to
  `PagedMediaViewer`'s chrome; wire an explicit play/pause button there too.
- **Clean seeking.** While fullscreen, the surface plays the clip with a **non-looping** `AVPlayer`
  (or pauses the `AVPlayerLooper` during a scrub) so the scrubber maps cleanly to `0…duration`; on reaching
  the end, hold (or restart) per a simple rule. Feed the scrubbed/observed time through the existing
  `ClipHROverlay.fraction(videoTime:clip:payload:)` so the HR dot/BPM follow the scrub for free.
- Keep one media engine + one HR SSOT; the inline carousel/Recap viewer behavior is unchanged except the
  inline tap target.

## Output

- `ios/App/Snappet/Features/Feed/MediaBrowserView.swift` — `clipsViewer` factory + `MediaTransportBar` +
  play/pause in `PagedMediaViewer` chrome; tile passthrough.
- `ios/App/Snappet/Features/Feed/ClipMediaSurface.swift` — expose the playback controller (isPlaying /
  currentTime / duration / togglePlay / seek); optional non-looping fullscreen mode for clean scrubbing.
- `ios/App/Snappet/Features/Feed/ClipsFeedView.swift` — tap playing inline → present fullscreen; drop the
  inline play/pause-by-tap.
- `ios/App/SnappetUITests/ClipsFeedUITests.swift` — a tap-playing-→-fullscreen-→-close flow (best-effort on
  the sim) + transport controls exist.
- `docs/knowledge-graph/data.js` (Clips → fullscreen viewer + transport edge), `pdd/context/decisions.md`.

## Acceptance criteria

- [ ] Tapping a playing inline clip opens fullscreen; the still-poster tap still starts inline play.
- [ ] Fullscreen has a working play/pause and a scrubbable timeline; dragging it seeks the video and the
      HR dot/BPM follow the scrub; close returns to the feed at the same post.
- [ ] Audio in fullscreen respects prompt 93's session + the in-view 🔊 toggle.
- [ ] Recap's existing `MediaBrowserView`/viewer is unchanged.
- [ ] App type-checks (Swift 6, 0 warnings); full `SnappetTests` + `ClipsFeedUITests` green.

## Constraints

- No `AVPlayerViewController` (can't composite the HR overlay). Preserve single-active discipline + the one
  HR SSOT. The inline render is the R12 risk → **device-verify scrub + HR sync** before relying on it.

## Test plan

1. `xcodebuild test … -only-testing:SnappetTests` + `-only-testing:SnappetUITests/ClipsFeedUITests` —
   0-warning build, suites green.
2. On a device: tap a playing clip → fullscreen; play/pause; drag the timeline → video seeks + HR dot
   follows; toggle audio; close → back at the post. **Watch for a black inline/fullscreen frame (R12).**
