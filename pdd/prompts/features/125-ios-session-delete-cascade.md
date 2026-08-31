# Prompt: Session deletes cascade — orphan sweeps, watch-import tombstones, one finish path

**File**: pdd/prompts/features/125-ios-session-delete-cascade.md
**Created**: 2026-08-30
**Project type**: Native iOS fix (Swift / SwiftUI) — code lands in this repo.
**Chain**: release-readiness review 2026-08-30 → session-lifecycle findings (P3 of 4 fix PRs)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Make deleting a session actually delete it. The suite links tables with plain UUID FKs (no
SwiftData relationships), so nothing cascades — and unlike Wardrobe (which sweeps
`WardrobePhoto` rows before an item delete), session deletes swept nothing. Three consequences:

1. **Orphan rows forever.** Gym `deleteSession`, the player's discard, the start-conflict
   "Discard it & start new", Kilter clear-all and the Kilter auto-start undo all left
   `SessionMedia`, `StudioProject`, `FestivalAttendance` and `FestivalClipTag` rows behind. The
   feeds filter orphans at read time, so nothing showed on screen — the store just grew garbage.
2. **Deleted watch workouts resurrect.** `WatchWorkoutImportService.reconcile` re-scans a 7-day
   look-back; a deleted anchor is simply missing from `anchoredSessionByUUID`, so a recently
   deleted watch workout was re-minted on the very next pass. Delete didn't stick.
3. **Two copies of "finish a session."** `FestivalScheduleView.endNight` duplicated the tracker's
   `finishWorkout` flush-HR / stamp-bounds / kcal / stop / feed-Recap block line for line — the
   textbook drift setup.

## Approach

- **`SessionCascade`** (new, Features/WorkoutTracker): `deleteWorkoutSession` sweeps
  media/studio/attendance/tags then deletes; `deleteKilterSession` sweeps media/studio. Callers
  save (clear-all batches many). `FeedActivity` is deliberately NOT swept — append-only by
  design, and the Recap feed derives cards from live sessions, so orphan rows are dormant.
- **`WatchImportTombstones`** (same file): deleted `healthKitWorkoutUUID`s in UserDefaults
  (device-local bookkeeping beside the existing reconcile watermark — not user data, so not
  SwiftData/backup). The cascade records; `reconcile` filters fetched workouts against it.
- **`WorkoutSessionFinisher`** (new): the one finish path; tracker + festival call it and add
  their own module logging after.
- Baked clips live in the Photos library (the user's media) — correctly untouched by any sweep.

## Output

New: `SessionCascade.swift`, `WorkoutSessionFinisher.swift`, `SessionCascadeTests.swift`.
Changed: `WorkoutTrackerModule.swift` (deleteSession, discard, replaceActiveAndStart, finish),
`FestivalScheduleView.swift` (endNight), `KilterHistoryView.swift` (clearAll),
`KilterBoardController.swift` (undoStart), `WatchWorkoutImportService.swift` (tombstone filter).

## Acceptance criteria

- [ ] Deleting a session removes its SessionMedia/StudioProject (+ festival rows for workout
      sessions); other sessions' rows untouched (unit-tested).
- [ ] Deleting a watch-imported workout records a tombstone; a tracked session records none
      (unit-tested). Reconcile filters tombstoned workouts.
- [ ] The finish refactor is behavior-preserving: same statements, same order, callers keep
      their own logging/navigation.
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).
- [ ] `decisions.md` updated.

## Constraints

- On-device only. No schema change (tombstones are UserDefaults, like the reconcile watermark).
- Never sweep Photos assets — SessionMedia stores identifiers into the user's library.

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'` — includes the new `SessionCascadeTests`.
2. UI slices for the touched screens (workout walkthrough + Kilter history) stay green.
3. Device leg (owed): delete a real watch-imported workout, force a reconcile (relaunch), and
   confirm it stays gone.
