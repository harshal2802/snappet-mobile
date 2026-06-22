# Prompt: Recap Feed R13 — post-F7 cleanup & conformance wave

**File**: pdd/prompts/features/feed/R13-cleanup-wave.md
**Created**: 2026-06-21
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: PLAN.md → F0–F7 + R1–R12 (shipped) → R13 (post-ship cleanup, stacks on R12)
**Source**: `/simplify` + `/code-review`-style cleanup pass over the F0–F7 Recap feed surfaces.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

A quality-only cleanup pass over the shipped Recap feed (F0–F7). It removes duplication, lifts pure
logic out of views, kills per-render/per-card waste, and **unifies the card→display mapping that had
drifted four ways**. With one exception it is behavior-preserving (the golden corpus + full
`SnappetTests` stay green and unchanged): the card *wording/accent/icon* is reconciled to one
canonical set (the four surfaces previously disagreed — audit D1–D25), and run **distance now honors
the user's km/mi preference** on every surface. Not a bug hunt; not a feature.

## Context the implementer needs

The feed had **four parallel `switch FeedCardPayload` mappings** (list `FeedCardView`, share
`ShareCardSpec`, story `StoryComposition.scene`, wall `WallTile.spec`) that drifted on wording, hero
field, accent, and icon (e.g. streak record sub said "go gentler" — the restNudge voice — on a
celebration; pyramid grade-count differed; PR kicker was "Grade PR" vs "New hardest ever"). The feed
also re-scanned `allMedia`/sessions per visible card every body eval, fetched reactions/saves twice
per card, re-sorted clip lists 6–8× per render, and copy-pasted the @Model→snapshot path, the PHAsset
poster loader, and the chromeless AVPlayer surface. Distance was hard-coded km, ignoring the user's
unit. The keystone (`FeedComposer` ordering/recency/lens) is correct and must NOT be touched.

## Approach

Reuse over rewrite; pure logic in the pure layer; platform I/O at the view/Service edge.

1. **`FeedCard.aggregate(...)`** (FeedCard.swift) — one factory carrying the H4 aggregate-card invariant
   (`contentId == ""`, one `aggregate` `ActivityRef`); adopted by FeedTrendCards/FeedInsightCards/
   FeedEffortInsights. Dedupe `dominantDiscipline` onto `FeedComposer`; drop redundant memberwise inits.
2. **`FeedMediaResolver` + `FeedMediaIndex`** — the single @Query'd-@Model→plain-value snapshot path,
   shared by FeedView + CardDetailView; reads a per-refresh O(1) index (`mediaBySession`/`kilterByID`/
   `workoutByID`/`logsBySession`) built ONCE per `feedSignature()` inside `FeedMemo` (so cards + index
   never drift). Snapshots to plain values → no @Model crosses into the engine/exporter.
3. **`FeedMedia.ordered/groupKey/tagName`** — one clip order/group/name-tag source across carousel +
   browser + pager. `FeedMediaCarousel` sorts once per body and computes `clipHR` once per page.
4. **`FeedCardDisplay`** (NEW pure file) — the ONE card→display mapping (kicker/hero/heroCaption/
   primaryLine/secondaryLines/icon/`FeedAccent` token), computed via `FeedCard.display(unit:)`. The four
   surfaces consume it and own only layout; `ShareCardSpec` becomes a thin adapter; `StoryComposition`
   and `WallTile` source from it (keeping wall density overrides). `FeedAccent.color` (SwiftUI bridge)
   lives in the view layer. `StoryAccent` becomes a `typealias FeedAccent`.
5. **Unit-aware distance** — `FeedFmt.distance`/run pace route through the pure `SetMeasure.formatDistance`/
   `formatPace`; the user's `DistanceUnit` is derived from `@AppStorage("workoutlog.preferredUnit")`
   (`WeightUnit`) via `SessionRecap.distanceUnit(_:)` and threaded into all four surfaces.
6. **Reaction batching** — hoist `FeedReaction`/`FeedSaveItem` to one `@Query` each at the host; pass
   `reacted`/`saved` membership into `FeedReactionStrip` (drop its local `@State` + per-card `.task`).
   Toggle writers mutate the @Model tables → host `@Query` auto-refresh re-renders the strip.
7. **Generic toggle** — `ActivityScoped` protocol + a generic `rows<M>`/`toggle<M>` over
   `FetchDescriptor<M>()` + in-memory filter (mirrors `SnappetBackup.all<M>`; avoids a non-translatable
   generic `#Predicate`).
8. **Player/thumbnail reuse** — parameterize `StudioPlayerLayerView` with `backgroundColor` (default
   `.clear`) and delete the feed's `ClipPlayerLayer`; extract one `AssetPosterLoader` and thin both
   `ClipThumbnail` (feed) and `HighlightThumbnail` (reel) onto it (keep each view's distinct chrome).

## Output

- **New**: `FeedCardDisplay.swift`, `FeedMediaResolver.swift` (+ `FeedMediaIndex`), `AssetPosterLoader.swift`,
  `SnappetTests/FeedCardDisplayTests.swift` (golden per kind — the wording guard + Kotlin-port parity vector).
- **Edited**: FeedCard, FeedComposer, FeedInsightCards, FeedTrendCards, FeedEffortInsights, FeedMedia,
  FeedMediaCarousel, FeedInteractions, FeedView, CardDetailView, FeedActivity, FeedCardView,
  ShareTemplates, FeedShareComposer, StoryComposition, RecapStoryView, WallView, MediaBrowserView,
  ReelView, StudioPlayerLayerView.
- **KG unchanged** — every change is an internal refactor; no new user-facing surface or data-flow edge.

## Acceptance criteria

- [ ] `FeedCardDisplay` is the SOLE card→display mapping; the four surfaces own layout only (density
      overrides like the wall lift set-count are allowed; re-deriving a string the descriptor provides is not).
- [ ] `FeedCard.aggregate` is the sole aggregate-card constructor; `FeedMediaResolver` the sole
      @Model→snapshot path; `FeedMedia.ordered/groupKey/tagName` the sole clip order/group/tag source.
- [ ] The media index rebuilds with (never after) the composed cards — one `feedSignature()`, no stale cache.
- [ ] Reaction toggles still reflect immediately; no double-toggle; `feed.react`/`feed.save` ids intact.
- [ ] Distance honors the user's km/mi unit on list + wall + story + share via the one `SetMeasure` funnel.
- [ ] Every `feed.card.<kind>` accessibilityIdentifier is byte-identical (derived from `kind.rawValue`).
- [ ] `FeedCardDisplay.swift` imports Foundation only (no SwiftUI/UIKit/Color).
- [ ] Keystone untouched: `FeedComposer` ordering/recency/lens unchanged; golden corpus byte-identical.
- [ ] App type-checks (Swift 6, 0 warnings); full `SnappetTests` green; `FeedCardDisplayTests` green.
- [ ] `decisions.md` updated with the non-obvious choices.

## Constraints

- Quality-only, behavior-preserving except the documented wording reconciliation + unit-aware distance.
- Reuse over rewrite; no new brand tokens; no new public API beyond the helpers above.
- No device-burn paths touched (the R4 AVFoundation/Photos export tail is unchanged).
- No changes to `HighlightEngine`; no platform imports in the pure feed files.

## Test plan

- `cd ios/App && xcodegen generate && xcodebuild build-for-testing -scheme Snappet …` (0 errors).
- Full `SnappetTests` unit suite green; new `FeedCardDisplayTests` golden green; golden corpus byte-identical.
- The card wording + distance change real displayed text, so run the Feed XCUITests (FeedView/HRCard/
  Wall/MediaCarousel/ShareComposer/RecapStory) to confirm identifier-stability — these are not logic-only.
