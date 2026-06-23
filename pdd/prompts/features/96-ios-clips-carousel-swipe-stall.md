# Prompt: Clips — kill the ~250ms main-thread stall on a carousel swipe

**File**: pdd/prompts/features/96-ios-clips-carousel-swipe-stall.md
**Created**: 2026-06-22
**Project type**: Native iOS perf fix (Swift / SwiftUI) — code lands in this repo.
**Chain**: Clips carousel-flicker loop, round 6 → user: "it is not smooth when video is playing or live play
is on. flicker still exists." (Follow-up to 95's frame-0 posters + the round-5.x `layerReady` latch.)
**Context**: `pdd/context/project.md`, `pdd/context/decisions.md`

## Goal

Make the per-post carousel swipe smooth WHEN VIDEO IS PLAYING / autoplay is on. Remove the ~200–317ms freeze
that lands on each swipe.

## Investigation (already done — don't redo)

- 60fps on-device frame analysis: NO discrete flicker frame (no black/poster/white flash — the round-5.x
  latch already removed the AVPlayerLooper loop-seam poster flash). The defect is TEMPORAL: each swipe FREEZES
  ~200–317ms then JUMPS to the new clip — the paged-slide animation never renders.
- **Measurement caveat:** iOS screen recordings are VFR and emit a ≤50ms frame when the screen is static, so a
  stall reads as REPEATED frames, not a PTS gap. Measure freeze duration by resampling to CFR 60fps and
  counting near-identical runs that end in a content jump.
- A 5-agent trace workflow localized the root: the incoming page's `AVQueuePlayer`+`AVPlayerLooper` is built
  COLD on the MainActor **on the swipe-snap frame**, because the warm-ahead timer (`ClipsFeedView`
  `onChange(of:page)`) was **400ms — longer than the ~250ms swipe cadence** — so a fast swipe always reaches an
  un-warmed page and the heavy looper build (+ a 2nd decoder spinning up while the old clip plays) blocks main
  across the snap. Both adversarial reviewers REJECTED pre-warm-all-clips (R12), pause-during-scroll (TabView
  has no horizontal scroll-phase signal), the `.simultaneousGesture` (scroll/hit-test contention), and an
  off-main player pool (R12 black-box). It is a TIMING bug.

## Approach (3 low-risk changes)

1. **Warm-ahead 400ms → 80ms.** In `ClipsFeedView` `ClipPostCard.onChange(of: page)`, shorten the
   `Task.sleep` that advances `warmPage` so the page you're about to reach is pre-built BEFORE the next snap.
   Keep the `if page == newPage` guard (skips pages you fling past) and the ±1 warm bound (R12).
2. **`await Task.yield()` before the player build.** In `ClipMediaSurface.load()` inline/looping branch, yield
   one runloop turn before constructing `AVQueuePlayer`+`AVPlayerLooper`, so even a cold mount defers the heavy
   build off the snap frame's critical section and the slide renders. `isActive`/`muted`/`state` are read live
   after the hop (no off-center autoplay regression).
3. **Off-main force-decode of the frame-0 poster.** In `AssetPosterLoader` add a `nonisolated decoded(_:)`
   that bakes the `CGImage` into a bitmap via `CGContext` (off-main) so round-5's `AVAssetImageGenerator`
   poster doesn't decode/upload on the snap commit. Keep `maximumSize` at 3× (matches the layer so the
   `layerReady` crossfade stays seamless).

(Also keep the round-5.x latch: `onReadyForDisplayChange` only ever sets `layerReady = true`; reset only on
teardown — kills the loop-seam poster flash.)

## Output

- `ios/App/Snappet/Features/Feed/ClipsFeedView.swift` — 80ms warm defer.
- `ios/App/Snappet/Features/Feed/ClipMediaSurface.swift` — `Task.yield()` + the latch.
- `ios/App/Snappet/Features/Feed/AssetPosterLoader.swift` — off-main `decoded(_:)`.
- `pdd/context/decisions.md` (round 6), `docs/knowledge-graph/data.js`.

## Acceptance criteria

- [ ] On device, autoplay ON, fast-swiping a multi-clip video post: the per-swipe freeze is gone and the
      slide renders (CFR-60 frame analysis: swipe-stall freezes → ~0, time-frozen-while-swiping → ~0%).
- [ ] No regression to single-active playback, tap-to-fullscreen, the mute toggle, or the HR scorebug.
- [ ] Peak concurrent inline players stays bounded (±1, R12); no memory/decoder blow-up under sustained
      flinging.
- [ ] App type-checks (Swift 6, 0 warnings); sim + device builds green; no crash opening Clips.

## Constraints

- iOS Swift/SwiftUI, iOS 18+. Keep `TabView(.page)` (no carousel rewrite). Keep single-active discipline
  (R12 = recycled vertical rows, not a bounded per-post carousel). Device-burn only (sim has no Photos).

## Test plan (achieved)

- Measured before/after on the swipe windows of two on-device 60fps recordings: swipe-stall freezes **10 → 0**,
  longest **317ms → 0ms**, time-frozen-while-swiping **15% → 0%**; the slide renders frame-by-frame.
