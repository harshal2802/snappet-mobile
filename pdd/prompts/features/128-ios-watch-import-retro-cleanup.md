# Prompt: Retroactive ghost cleanup — existing "From Apple Watch" impostors delete themselves

**File**: pdd/prompts/features/128-ios-watch-import-retro-cleanup.md
**Created**: 2026-08-31
**Project type**: Native iOS fix (Swift / SwiftUI) — code lands in this repo.
**Chain**: prompt 127 follow-up — device screenshot showed ~7 pre-existing ghost rows (some
duplicated); telling the user to hand-delete them was the wrong answer.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Prompt 127's source gate stops NEW ghosts, but anchors minted before it exist on real phones:
the user's History showed a "From Apple Watch" section full of their own tracked Quick Sessions —
several twice (duplicate anchors of one `HKWorkout`, a historical FR3 breach, likely two
reconciles racing before either saved). The app created these rows; the app removes them.

## Approach

A cleanup pass at the top of `reconcile` (which runs at launch — `RootShell`), BEFORE the
Photos-authorization gate so it works even without auto-discovery:

- `HealthKitService.workoutSources(for:)` — targeted `HKQuery.predicateForObjects(with:)` lookup
  of each anchor's recording source (anchors can be far older than the reconcile watermark, so a
  date-window query can't judge them).
- Pure `WatchWorkoutReconciler.staleAnchors(anchors:sources:)` decides deletions:
  1. duplicates of one workout collapse to the most-media anchor (ties on sessionID, stable);
  2. any anchor whose source fails `shouldImport` goes entirely (own-companion ghosts,
     phone-written workouts);
  3. a workout with NO source entry (since deleted from HealthKit) is kept — can't judge, don't
     touch (its duplicates still collapse).
- Deletion runs through `SessionCascade` — media/studio rows swept, and the prompt-125 tombstone
  doubles as a second guard against re-minting. Idempotent; no writes once clean.

## Acceptance criteria

- [ ] Own-companion ghost groups are fully deleted; duplicate legitimate anchors collapse to
      one; single legitimate and unjudgeable anchors survive (all unit-tested, pure).
- [ ] Cleanup runs even when Photos access is denied/limited.
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).
- [ ] `decisions.md` + knowledge graph updated.

## Constraints

- Conservative by construction: no source record ⇒ keep. Never touches tracked sessions
  (`healthKitWorkoutUUID == nil`) or Photos assets.

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'` — new `staleAnchors` cases + existing suite.
2. Device leg: relaunch on MrRobot → the History screenshot's ghost/duplicate rows are gone
   without any manual deletion; genuine watch workouts remain.
