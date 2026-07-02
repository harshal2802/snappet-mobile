# Prompt: Clips feed performance — off-main composition + clip-heavy session scale

**File**: pdd/prompts/features/106-ios-clips-feed-performance.md
**Created**: 2026-07-02
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Clips feed line (82 → 98); follows the prompt-97 render-cascade fix.
**Source**: User report — "Clips tab is laggy; a session with a large number of videos freezes the app."
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Make the Clips tab smooth on real libraries and make it survive a session with many (50+) tagged
videos. The prompt-97 work fixed the swipe render cascade; what's left is the *feed generation*
path (a synchronous main-thread rebuild that re-slices every clip's HR window on every data tick)
and the *clip-heavy post* path (an eager `TabView(.page)` carousel that mounts every page and
kicks off an exact-frame video decode per clip into an unbounded ~10 MB-per-entry poster cache).

## Context the implementer needs

Five verified defects, ranked:

1. **`ClipsFeedView.rebuildFeed()` runs entirely on the MainActor** — `composedPosts()` plus a
   per-clip `ClipHROverlay.make` loop over the whole feed, triggered by `.task` and every
   `feedKey` change. All inputs are already plain `Sendable` values by design (the composer and
   slicer are pure), so the work can hop off-main.
2. **Aspect-backfill storm**: each `ClipPostCard.backfillAspect()` saves one `SessionMedia`,
   which flips `feedKey.aspects`, which re-runs the full rebuild — M unresolved posts ⇒ M
   complete main-thread rebuilds during the first scroll.
3. **`HRWindowSlicer.slice` sorts the entire session HR series per call** (plus two O(n) linear
   scans in `value(at:)`). A 2 h ~1 Hz session is ~7 200 points; 50 clips ⇒ 50 sorts of it per
   rebuild. Live capture appends in time order, so the sort is nearly always wasted.
4. **`TabView(.page)` is not lazy**: a 50-clip post mounts 50 `ClipPosterView`s at once, each
   firing `ClipThumbnail` → `AssetPosterLoader.videoFrameZero` — an `AVAssetImageGenerator`
   zero-tolerance frame-0 decode at 3× tile size (~10 MB baked bitmap) — 50 concurrent decodes.
5. **`AssetPosterLoader.frameZeroCache` is an unbounded `[String: UIImage]`** of those baked
   bitmaps: 50 videos ≈ 500 MB retained forever → memory-pressure/jetsam risk. Also
   `cachedHRContext` copies (and blob-decodes) `hrSeries` for **every** session, media or not,
   and the page-dot row draws one dot per clip (50 dots overflow the card).

## Approach

One PR, five moves — no behavior change beyond smoothness:

- **P1 — off-main rebuild with coalescing.** Split `rebuildFeed()` into: a MainActor snapshot of
  the `@Query` models into a `Sendable` value (bundles, climb meta, exercise names, HR context,
  tiles), a `nonisolated static` async compose (posts + per-clip payloads — nonisolated async
  runs off the caller's actor), and a MainActor assign. Keep a `rebuildTask` handle:
  cancel-and-restart with a short debounce on `feedKey` changes (coalesces the backfill storm,
  fixing 2 without touching the backfill itself); the first build stays immediate.
- **P2 — slicer fast-path.** `HRWindowSlicer.slice`: use the input as-is when already
  time-sorted (O(n) check, no allocation), binary-search the interior window bounds and the
  `value(at:)` bracketing pair. Contract byte-identical — existing `HRWindowSlicerTests` must
  pass unchanged; add an unsorted-input parity test.
- **P3 — carousel work-windowing (round 2).** In `ClipPostCard.carousel`, every page keeps its
  `ClipPosterView` mounted with **stable identity**; only the poster-bitmap load is windowed
  (`loadPoster`, ±3 of `page`, threaded to `ClipThumbnail.enabled`). Round 1 windowed the *view*
  (an `if/else` swapping poster ↔ placeholder), but a branch change is an identity change — every
  snap commit destroyed two pages and mounted two fresh ones on the settle frame, which read as
  carousel jitter on device. Warm/live player bounds (±1) unchanged. Hide the dot row when
  `clipCount > 8` (the "n/N" counter overlay already covers it).
- **P4 — bounded poster cache.** `frameZeroCache` becomes an `NSCache` (cost = bitmap bytes,
  `totalCostLimit` ≈ 150 MB) so memory pressure evicts old posters instead of jetsamming the app.
- **P5 — trims.** Build the HR context/payloads only for sessions that actually have media;
  delete the dead `hrContext(for:)`.

## Output

- `ios/App/Snappet/Features/Feed/ClipsFeedView.swift` — snapshot/compose/assign split, rebuild
  coalescing, carousel windowing, dot-row cap, trims.
- `ios/App/Snappet/Features/WorkoutTracker/HRWindowSlicer.swift` — sorted fast-path +
  binary-search bounds.
- `ios/App/Snappet/Features/Feed/AssetPosterLoader.swift` — NSCache-bounded frame-zero cache.
- `ios/App/SnappetTests/HRWindowSlicerTests.swift` — unsorted-input parity coverage.
- `pdd/context/decisions.md` — the non-obvious choices (windowing over a custom pager, debounce
  as the backfill fix, NSCache bound).

## Acceptance criteria

- [ ] Feed composition + HR slicing no longer run on the main thread; rapid `feedKey` changes
      coalesce into one rebuild.
- [ ] `HRWindowSlicer` returns identical output for sorted and unsorted input; all existing
      slicer tests pass unchanged.
- [ ] A 50-clip post requests ≤ 7 poster bitmaps (±3 window); posters beyond the window load only
      when the window reaches them. Page identity is stable across swipes (no snap-frame mounts).
- [ ] The frame-zero poster cache is cost-bounded (~150 MB) and evicts under pressure.
- [ ] `cachedHRContext` holds only media-bearing sessions.
- [ ] App changes type-check against the iOS SDK (0 new warnings); unit suite green.
- [ ] `decisions.md` updated.

## Constraints

- On-device only; no backend. `HighlightEngine` untouched. Pure logic stays pure (the slicer and
  composer keep zero platform imports) so it unit-tests without a simulator.
- No UX redesign: same posts, same order, same overlays — this prompt is throughput only. The
  deferred custom UIScrollView pager (snap feel, decisions round 7b) stays deferred; windowing
  inside the stock `TabView` must not preempt it.

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'` — full unit suite (composer + slicer + overlay).
2. `make ios-build SIMULATOR='iPhone 17 Pro'` (or the test build) — 0 new warnings.
3. Clips XCUITest (`ClipsFeedUITests`) — the feed still renders, pages swipe, grid opens.
4. Device burn (MrRobot, deferred): scroll a clip-heavy feed; watch memory stay bounded.
