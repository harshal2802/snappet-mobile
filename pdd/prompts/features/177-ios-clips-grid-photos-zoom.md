# Prompt: Clips grid — smooth scrolling and a Photos-style zoom (All · Months · Year)

**File**: pdd/prompts/features/177-ios-clips-grid-photos-zoom.md
**Created**: 2026-10-10
**Project type**: Native iOS feature (SwiftUI + UIKit) — code lands in this repo.
**Chain**: follows 176 (grid scrubber + pinch). Wireframe: `docs/ux-research/clips-grid/zoom-levels.png`
(user picked **A · Year mosaic** and the **Year · Months · All** segmented control).
**Context**: `pdd/context/decisions.md`

## Device feedback that started this

1. "grid view is super laggy. can you find out a robust way to render it well"
2. "the transitions looks jerky … can we also have yearly level view … make sure all the transitions are optimized
   and smooth just the way photos app has"

## Approach

Measure on the phone first, every time (temporary display-link probe → `Documents/clips-perf.log`, never merged).

**Scrolling (commits ddb968b, 0f2be62).** 4–8 fps → 50–60 fps:
- The scroll position lived in the grid's `@State`, so the WHOLE grid re-ran its body every frame. It now lives in
  `ClipGridScrubState`, which only the scrubber reads (the prompt-97 lesson again).
- Months and cover models are computed once when the posts change, not on every body pass.
- Covers use the cheap Photos thumbnail, not an exact frame-0 decode.
- `PHAsset` lookups run off the main thread with a cache (`AssetPosterLoader.assets`).
- An off-main decode attempt (34c77fa) gave no measured gain and was reverted.

**Zoom (this change).** The SwiftUI `LazyVGrid` re-laid out the whole grid on main whenever the column count
changed, a 370–620 ms freeze measured on device, so no animation could hide it. The new grid runs on UIKit:
- `ClipGridZoom.swift` (pure, unit-tested):
  - `ClipGridLevel` defines the levels: All 3 · Months 5 · Year 9, and their pinch order.
  - `ClipGridGeometry` gives every header and cover frame at a level by arithmetic: pinned headers, visible-range
    queries, and the cover nearest a point.
  - `progress(scale:)` maps the pinch on a log scale.
  - `settles(progress:towardVelocity:)` decides finish or spring-back on release.
  - `anchoredOffset` gives the scroll offset that keeps the pinched cover under the fingers.
- `ClipGridCollectionView.swift`:
  - `ClipGridZoomLayout` (a custom `UICollectionViewLayout`) draws from one geometry when settled. During a zoom it
    interpolates each cover's frame between two geometries, while the coordinator moves the scroll offset by the
    same amount.
  - The pinch tracks the fingers. One pinch can continue All → Months → Year, and can reverse direction.
  - The segmented control and a tap in Year run the same zoom on a display link.
  - Covers are plain UIKit views, cheap to resize every frame. The month header stays SwiftUI (hosted).
- Year mosaic (wireframe A): 9 per row, a "2026 · N clips · N sessions" title, and small month labels
  (`ClipGridModel.years`, `shortMonth`). Tapping a cover zooms back into its month.
- The long-press menu became `UIMenu` actions with the same identifiers. The month "Make reel" is a Button that sets
  `reelRoute`, because a NavigationLink inside a UIKit-hosted header can't see the stack.

**The last stutters, found with per-frame counters:**
- Every pinch that landed re-ran the FEED's body behind the sheet (about 120 ms). Saving the level to
  `@AppStorage` mid-pinch changed UserDefaults, and the feed's own `@AppStorage` reacts to that. The level is now
  grid `@State`, saved on close.
- All of the target level's covers were created on the zoom's first frame. Now only covers inside the visible rect
  get attributes, so they're created a few per frame.
- Zooming out of Year built 6 hosted month headers in one frame. They now stay alive, invisible, in Year.
- Thumbnails are decoded with `byPreparingForDisplay()` before they're shown.

## Acceptance criteria

- [x] Device: grid scrolling at 50–60 fps (was 4–8). Grid body evaluations per visit 200 → 5.
- [x] Device: every zoom drops 0 frames: 20/20 transitions (pinch All ⇄ Months ⇄ Year, spring-back, segments).
      Before: 22–36 dropped frames (370–620 ms) per switch.
- [x] Pinch tracks the fingers, and the pinched cover stays under them (`anchoredOffset`, unit-tested).
- [x] Year · Months · All control; the level is remembered under the prompt-176 key (`clips.grid.columns`).
- [x] Unit: `ClipGridZoomTests` (geometry, pinned headers, visible ranges, progress, settle, anchor, years).
- [x] UI: `testGridZoomLevels` replaces `testGridColumnToggle`; long-press, select, and month-header tests are green on
      the UIKit grid.
- [ ] Device: the user's feel check of the final build.
