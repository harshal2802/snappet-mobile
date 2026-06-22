# Prompt: Clips — fix the carousel-swipe freeze at its root (re-render cascade + main-thread player build)

**File**: pdd/prompts/features/97-ios-clips-swipe-render-cascade.md
**Created**: 2026-06-22
**Project type**: Native iOS perf fix (Swift / SwiftUI) — code lands in this repo.
**Chain**: Clips carousel-flicker loop, round 7 → user: "the issue still stays … fix it properly. this is
such a general feature." (Rounds 1–6 = prompts 91–96 + latches; none touched the two causes below.)
**Context**: `pdd/context/project.md`, `pdd/context/decisions.md`

## Goal

Eliminate the ~250–600ms FREEZE on a Clips carousel swipe (autoplay on / video playing), at its architectural
root — not another timing tweak.

## Investigation (already done — don't redo)

- Frame analysis (right-edge crop of an on-device recording) proved that during a swipe the carousel does NOT
  slide AND the playing video is frozen → a true MAIN-THREAD BLOCK, then a jump. Not a flash, not a poster pop.
- **Measurement caveat:** iOS screen recordings are VFR + emit a frame every ~50ms when static, so a stall
  reads as REPEATED frames, not a PTS gap. Resample to CFR 60fps and look for frozen runs that end in a content
  jump.
- Two code-visible causes, neither addressed in rounds 1–6:
  1. **Re-render cascade.** `playingClip`/`isScrolling` were plain `@State` on `ClipsFeedView`; a `@State` write
     unconditionally re-runs the whole `body`, re-evaluating the entire feed `ForEach` of post cards (each a
     `TabView(.page)` of AVPlayer pages). The prompt-92 caches cached the DATA; the VIEW TREE still re-evaluated.
  2. **Residual player build.** The synchronous `AVQueuePlayer`+`AVPlayerLooper` build can still land on the
     swipe-snap frame on an un-warmed page; the prompt-96 `Task.yield`/80ms-warm are a race, not a guarantee
     (autoplay-ON only — the user's repro).

## Approach

1. **Lift high-frequency state into `@Observable` (the cascade fix).** Add
   `@MainActor @Observable final class ClipFeedPlayback { var playing: PlayingClipRef? { didSet { audio } }; var isScrolling }`.
   `ClipsFeedView` holds it as `@State` and passes the OBJECT down by reference (a `let` — establishes no
   SwiftUI dependency). Read `playback.playing` ONLY in the leaf `ClipPosterView` (its `playing`/`live`/`muted`
   computeds). `ClipPostCard.body` reads only `playback.isScrolling` (never flipped by a horizontal swipe);
   `liveFor`→`warmLive` uses card `@State` only. Move the audio-session reaction to the model's `playing`
   `didSet` (guarded `!= oldValue`) so the feed body never re-reads `playing`. Result: a swipe re-renders ONLY
   the two affected leaf pages — not the feed body, not sibling cards.
2. **Build the player OFF the main thread (the residual fix).** In `ClipMediaSurface.load()` inline branch,
   construct `AVQueuePlayer`+`AVPlayerLooper` on `DispatchQueue.global(qos:.userInitiated)` inside a
   `withCheckedContinuation` (snapshot `muted`; box the non-Sendable `AVPlayerItem`), then assign the boxed
   `(AVQueuePlayer, AVPlayerLooper)` to `@State` back on main. The player is only USED on main, after.

## Output

- `ios/App/Snappet/Features/Feed/ClipsFeedView.swift` — `ClipFeedPlayback` + the `@Observable` migration.
- `ios/App/Snappet/Features/Feed/ClipMediaSurface.swift` — off-main player construction.
- `pdd/context/decisions.md` (round 7), `docs/knowledge-graph/data.js`.

## Acceptance criteria

- [ ] On device, autoplay ON, fast-swiping a multi-clip video post: the slide renders frame-by-frame; the
      per-swipe frozen run drops to ~0 (CFR-60 frame analysis).
- [ ] A swipe does NOT re-run `ClipsFeedView.body` or sibling cards (only the affected leaf pages).
- [ ] No regression: tap-to-play, mute toggle, single-active discipline, fullscreen + audio re-assert,
      autoplay start/stop, HR scorebug tracking.
- [ ] Off-main `AVPlayerLooper` construction is crash-free on device.
- [ ] App type-checks (Swift 6, 0 warnings); sim + device builds green.

## Constraints

- iOS Swift/SwiftUI, iOS 18+. Keep `TabView(.page)` (no carousel rewrite). Keep single-active discipline
  (R12 = recycled vertical rows, not a bounded per-post carousel). Device-burn only (sim has no Photos).

## Verification done

- 3-reviewer adversarial workflow on the `@Observable` refactor: correct-ships, no regressions, no retain
  cycle, no must-fix; flagged the residual player-build (autoplay-ON), which the off-main build addresses.
- Built sim + device green; off-main looper construction confirmed crash-free on MrRobot (systemCrashLogs).
- Pending: user device recording (CFR-60 frame check) to confirm the freeze is gone.
