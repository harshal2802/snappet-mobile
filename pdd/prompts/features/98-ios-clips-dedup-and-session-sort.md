# Prompt: Clips — no duplicate media→set matching + session-time feed order

**File**: pdd/prompts/features/98-ios-clips-dedup-and-session-sort.md
**Created**: 2026-06-22
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Live Workout Studio → Clips feed (prompts 82–97) → correctness follow-up
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

A deep review of how a photo/video is matched to a **set/climb** turned up three ways the same
physical asset could appear twice, plus a feed-ordering mismatch. Fix them so: (R2) one physical
video maps to one set, never duplicated; (R3) reassigning a clip to a different set removes it from
the previous one with no residual duplicate; (R4) the Clips feed never shows the same video twice;
(R5) all feed posts are ordered by their **session's** start and end time (not the clip's capture
offset). The matching itself was reviewed and is correct (gym interval-ownership + Kilter
window-containment); the gaps were all in duplicate **rows** and the feed sort key.

## Context the implementer needs

`SessionMedia` is one row per discovered/picked asset, keyed to a session by `sessionID` and to a
set by a SINGLE pointer (`assignedExerciseID`+`assignedSetIndex`, or `assignedClimbUUID`). The
PHAsset `localIdentifier` is the physical-asset identity — two rows sharing it are the same video.
Reassignment overwrites the single pointer, so it is already exclusive at the model level; the only
way a *feed* duplicate arises is duplicate **rows**, from:

1. `SetMediaStrip.attach` deduped against the **one set** its `@Query` is scoped to (so re-attaching
   an asset already on another set/General in the same session inserted a 2nd row).
2. Auto-discovery (`SessionDetailView`, `FreeformPlayerView.discoverClips`,
   `KilterBoardController.discoverMedia`) deduped **per-session**, so an asset in the ±90 s pad
   overlap (`SessionMediaService.padSec`) of two adjacent sessions was tagged into both.
3. `ClipFeedComposer.posts` had **no** dedup by `localIdentifier`, so any duplicate row rendered
   twice; and it sorted by `captureAt` (= session start + first clip offset), not session time.

## Approach

Layered — prevent at the source AND guarantee at the read surface (the pure composer is the durable
net, since legacy duplicate rows can already exist):

- **Pure (`ClipFeedComposer`)** — `dedupedByAsset(_:)` collapses duplicate `localIdentifier`s across
  the whole feed before grouping. Survivor rule: an **assigned** clip beats a General one, then the
  **more-recent session** (later `startedAt`), then the smaller media id (stable). Add `endedAt` to
  `ClipFeedSessionMeta` and `sessionStartedAt`/`sessionEndedAt` to `ClipFeedPost`; replace the sort
  with `postOrder` = session start ↓, session end ↓, capture ↓, id ↑. `captureAt` stays for the
  "N clips · <when>" meta line only.
- **Store edge (`ClipsFeedView.composedPosts`)** — feed `endedAt` from `KilterSession.endedAt` /
  `WorkoutSession.completedAt` (already queried).
- **Insert sites** — `SetMediaStrip.attach` dedups against the whole **session**; the three
  auto-discovery paths dedup **globally** (any session) so the overlap asset is stored once. Manual
  picks stay session-scoped (a hand-add to two sessions is deliberate).

## Output

- `ios/App/Snappet/Features/Feed/ClipFeedComposer.swift` — meta/post fields, `dedupedByAsset`,
  `postOrder`, dedup helpers.
- `ios/App/Snappet/Features/Feed/ClipsFeedView.swift` — pass `endedAt` at the edge.
- `ios/App/Snappet/Features/WorkoutTracker/SetMediaStrip.swift` — session-scoped attach dedup.
- `ios/App/Snappet/Features/WorkoutTracker/SessionDetailView.swift`,
  `ios/App/Snappet/Features/WorkoutTracker/FreeformPlayerView.swift`,
  `ios/App/Snappet/Features/Kilter/KilterBoardController.swift` — global auto-discovery dedup.
- `ios/App/SnappetTests/ClipFeedComposerTests.swift` — dedup (within-session, across-sets, across
  sessions) + session-start/end sort tests; `video(asset:)` helper.

## Acceptance criteria

- [ ] A video on two sets / in two sessions appears in exactly one feed post (verified by unit test).
- [ ] Reassigning a clip leaves it in exactly one post (single-pointer overwrite + feed dedup).
- [ ] Feed posts order by session start then end, NOT clip capture offset (unit test with a
      later-started session whose first clip has an earlier capture time).
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).
- [ ] No platform imports added to `HighlightEngine` (untouched).
- [ ] `decisions.md` + knowledge graph updated.

## Constraints

- On-device only. Dedup lives in the PURE composer (one read surface) so it can't be bypassed and is
  unit-tested without a device. The set-matching algorithms (`SessionMediaAssignment`,
  `KilterMediaAssignment`) are unchanged — only duplicate rows + the feed sort key are addressed.
