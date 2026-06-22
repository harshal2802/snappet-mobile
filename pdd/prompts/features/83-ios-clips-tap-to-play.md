# Prompt: Clips — tap a poster to play (fullscreen viewer)

**File**: pdd/prompts/features/83-ios-clips-tap-to-play.md
**Created**: 2026-06-21
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: prompt 82 (Clips feed, PR #241) → its #1 deferred follow-up (inline/fullscreen playback)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Make a Clips-feed poster **tap-to-play**. Today the feed is still posters only (prompt 82 deferred
playback). Tapping a clip should open the **existing** Recap fullscreen paged viewer
(`MediaBrowserView` → `PagedMediaViewer`) at that clip — real on-device AVPlayer playback under the
SAME HR scorebug + name overlay — keeping the in-feed posters as stills (the single-active-player
discipline already lives in that viewer; we reuse it, we don't build a new player).

## Context the implementer needs

- The viewer already exists and is the single playback surface: `MediaBrowserView.viewer(clips:
  startIndex:hrSeries:maxHR:nameFor:card:clipContext:)` → `PagedMediaViewer` (a full-bleed
  `TabView(.page)`; only the centered page plays; off-center pages pause; teardown on `.onDisappear`).
- It is coupled to Recap only through **Share/Animate**: `card: FeedCard` + `clipContext` feed
  `ShareComposerView`, and `clipContext?.restHR` feeds the HR overlay. The Clips feed has no `FeedCard`
  and Share/Animate is out of the Clips slice (prompt 82) — so the reuse needs the Share affordance to
  be **optional**, not a fake `FeedCard`.
- The Clips feed (`ClipsFeedView` / `ClipPostCard` / `ClipPosterView`) already snapshots each session's
  HR (`ClipFeedHR`: `series` / `maxHR` / `restHR`) and orders a post's clips by offset. One post = one
  climb/exercise, so a single name covers all its clips.
- `CarouselViewerBox` + `Binding<Int?>.asItem` (FeedMediaCarousel.swift) already adapt an `Int?` start
  index to `.fullScreenCover(item:)` — reuse them.

## Approach

1. **Decouple the viewer from `FeedCard` (surgical).** In `PagedMediaViewer`: make `card: FeedCard?`
   optional, add `restHR: Double?`, build the overlay from `restHR` (not `clipContext?.restHR`), and
   show the Share/Animate button + sheet only when `card != nil`. The existing
   `viewer(...)` factory keeps its signature and passes `restHR: clipContext?.restHR` (Recap behaviour
   unchanged — both existing call sites stay byte-for-byte the same). Add a sibling factory
   `clipsViewer(clips:startIndex:hrSeries:maxHR:restHR:nameFor:)` that passes `card: nil`,
   `clipContext: nil`.
2. **Tap-to-play in the feed.** In `ClipPostCard`: a `@State var viewerStart: Int?`; each carousel
   `ClipPosterView` gets `.contentShape(Rectangle()).onTapGesture { viewerStart = idx }`; a
   `.fullScreenCover(item: $viewerStart.asItem)` presents
   `MediaBrowserView.clipsViewer(clips: post.clips.map(\.media), startIndex: box.value, hrSeries:
   hr.series, maxHR: hr.maxHR, restHR: hr.restHR, nameFor: { _ in post.title })`. The poster stays a
   still; the ⋯ menu + carousel paging are unaffected.

## Output

- `ios/App/Snappet/Features/Feed/MediaBrowserView.swift` — optional `card` + `restHR` + `clipsViewer`.
- `ios/App/Snappet/Features/Feed/ClipsFeedView.swift` — tap + fullScreenCover.
- `docs/knowledge-graph/data.js` — a `clips-feed → feed-media-viewer` (tap-to-play) edge.
- `pdd/context/decisions.md`, `pdd/context/project.md` — the decision + state.

## Acceptance criteria

- [ ] Tapping a Clips poster opens the fullscreen viewer at that clip; a video plays, a photo shows.
- [ ] The viewer's HR scorebug + name overlay match the poster's (same session HR window).
- [ ] The viewer presented from Clips shows **no** Share/Animate button (out of slice); Recap's viewer
      is unchanged (still has it).
- [ ] Both existing `MediaBrowserView.viewer` call sites (Recap carousel + browser) compile + behave
      unchanged.
- [ ] App type-checks (Swift 6, 0 warnings); full `SnappetTests` suite still green.

## Constraints

- No new player — reuse `PagedMediaViewer` (single-active-player discipline stays in one place).
- Share / reactions / grid stay deferred. Posters stay stills.
- Real playback + the HR overlay only fully render with Photos assets + a captured HR series on a
  physical iPhone — owed on-device (a fresh-store sim has no media to tap).

## Test plan

1. `cd ios/App && xcodegen generate && xcodebuild test -scheme Snappet -destination 'platform=iOS
   Simulator,name=iPhone 17 Pro'` — build 0-warning, full suite green (the viewer refactor must not
   regress Recap).
2. On a device with clips: tap a video poster → it plays fullscreen with the HR scorebug; swipe pages;
   close returns to the feed; no Share button. Tap a photo → shows fullscreen.
