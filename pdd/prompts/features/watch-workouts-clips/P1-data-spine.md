# Prompt: Apple Watch workouts → Clips — data spine (P1)

**File**: pdd/prompts/features/watch-workouts-clips/P1-data-spine.md
**Created**: 2026-07-10
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: watch-workouts-clips/PLAN.md → P1
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Give Apple Watch workouts a persisted home so the media shot during them reaches the Clips feed. The app
never controls these workouts; it reads completed `HKWorkout`s from HealthKit after the fact. This PR
mints a `WorkoutSession` anchor per media-bearing workout and auto-discovers its clips, so the existing
Clips composer — which already turns any `WorkoutSession` + `SessionMedia` into posts — surfaces them
with zero feed changes. On first install it scans all-time so the feed has content out of the box.

## Context the implementer needs

- The Clips feed is session-anchored: `ClipFeedComposer.posts()` builds posts from `WorkoutSession`s /
  `KilterSession`s that own `SessionMedia` rows (FK by `sessionID`, discovered by capture window ±90s).
- `HealthKitService.recentWorkouts` already reads `HKWorkout` → transient `WorkoutSummary`, but nothing
  persists it, so `SessionMedia` has nothing to FK against and the composer never sees it.
- Decisions #1/#4/#5/#6 (see PLAN): reuse `WorkoutSession` (empty `exercises`); media-only; unbounded
  first run; Kilter owns board climbing so only **gym** sessions suppress a watch mint.

## Approach

- **Model**: add `WorkoutSession.healthKitWorkoutUUID: UUID?` (additive optional → lightweight migration).
  Its presence is the "from Apple Watch" marker (`isFromAppleWatch`).
- **Pure** (`WatchWorkoutReconciler`, testable in `SnappetTests`): given plain-value workouts, existing
  anchors, discovered candidates, and gym-session intervals, decide `mint` / `attach` (late media) /
  skip (media-only, idempotent, gym-overlap by workout-midpoint ±pad). No HealthKit/Photos/SwiftData.
- **Service shell** (`WatchWorkoutImportService`, `@MainActor`): read workouts (all-time on first run,
  else since a watermark − 7d look-back), ONE Photos scan over the union window bucketed per workout in
  pure code (globally deduped so already-tagged assets aren't re-claimed), call the planner, apply mints
  (back-fill `hrSeries` from HealthKit, stamp `metricsSourceRaw = appleWatch`) + attaches, save, advance
  watermark.
- **Wiring**: fire the reconcile fire-and-forget from `RootShell` on load + on foreground (`scenePhase`
  `.active`). Idempotent, so repeat calls are safe. (True background delivery is P2.)
- **HealthKit reads**: `workoutsForImport(since:)` (measured energy/distance + fine activity label) and a
  `label(_:)` display-name map, added to `HealthKitService`; `rawAssets(in:)` bulk fetch on
  `SessionMediaService`.

## Output

- `Snappet/Features/WorkoutTracker/WatchWorkoutReconciler.swift` — the pure planner.
- `Snappet/Services/WatchWorkoutImportService.swift` — the device shell.
- `WorkoutModels.swift` — `healthKitWorkoutUUID` field + `isFromAppleWatch`.
- `HealthKitService.swift` — `workoutsForImport`, `label`, energy/distance on `WorkoutSummary`.
- `SessionMediaService.swift` — `rawAssets(in:)`.
- `RootShell.swift` — reconcile trigger.
- `SnappetTests/WatchWorkoutReconcilerTests.swift` — media-only / idempotency / late-media / gym-overlap /
  climbing-coexistence / ordering.

## Acceptance criteria

- [x] A completed watch workout with clips in its window produces a Clips post; one with none produces nothing.
- [x] Re-running import mints no duplicate anchors (idempotent on `HKWorkout.uuid`) and attaches only new media.
- [x] A watch workout overlapping a tracked gym session is suppressed; a watch climbing workout is not.
- [x] First run (no watermark) scans all-time; later runs scan since watermark − 7d.
- [x] App type-checks against the SDK (Swift 6); no `HighlightEngine` platform imports added.
- [x] `decisions.md` updated; knowledge graph node added.

## Constraints

- On-device only; no backend. Full Photos authorization required for the window scan (`.limited`/denied
  ⇒ watch workouts simply don't populate — documented degradation).
- Type-check ≠ device run: the HealthKit/Photos/SwiftData path needs a real device with watch workouts +
  a camera-roll to verify end to end.

## Test plan

1. `xcodebuild test -only-testing:SnappetTests/WatchWorkoutReconcilerTests` — the pure rules (9 tests).
2. Build-for-testing green; related suites (`ClipFeedComposerTests`, `SessionMediaAssignmentTests`) pass.
3. Device leg (owed): a real Apple Watch workout + clips → appears in Clips after foreground; no dupes on relaunch.
