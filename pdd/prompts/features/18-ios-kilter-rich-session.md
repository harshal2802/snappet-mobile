# Prompt: Kilter rich climbing session — HR, per-climb timing, media + highlight reel, Live Activity

**File**: pdd/prompts/features/18-ios-kilter-rich-session.md
**Created**: 2026-06-05
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: standalone feature on top of the Kilter Board mini-app (#35) + Live Workout Studio toolkit.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Make a Kilter board session as feature-rich as a tracked workout. Today a `KilterSession` only groups
logged ascents (start/end, angle, source). Bring the four capabilities the WorkoutTracker already has —
**live heart rate** (Apple Watch *or* a BLE chest strap), **per-climb timing & attempts**, **video/photo
capture + an auto highlight reel**, and a **Live Activity + rich post-session summary** — to a climbing
session, by **reusing the existing toolkit** (`LiveMetricsCoordinator`, `SessionMediaService`,
`HeartRateZone`, `WorkoutHRStats`, the pure `HighlightEngine`, `ReelExporter`) rather than rebuilding it.

## Context the implementer needs

- The metrics sources (`AppleWatchMetricsSource`, `BLEHeartRateMetricsSource`) only read two things from
  a `WorkoutSession`: its `startedAt` (to rebase `HRSample.t`) and an `HKWorkoutActivityType` (watch
  only). That coupling is shallow — lift it into a `LiveMetricsContext` so a non-workout surface can drive
  HR without being a `WorkoutSession`.
- `WorkoutActivityAttributes.ContentState` is exercise/set-shaped — wrong for climbing. Add a separate
  `KilterActivityAttributes` rather than overloading it.
- `SessionMedia` is already session-keyed on a bare `UUID` (`sessionID`) and otherwise workout-agnostic;
  reuse it for Kilter by keying `sessionID = KilterSession.id` and adding one optional `assignedClimbUUID`.
- All new data-model fields must be additive + defaulted (SwiftData lightweight migration). No new
  `@Model` types — inline `hrSeries: [HRPoint]` on `KilterSession`, reuse `SessionMedia`.

## Approach

- **Decouple metrics** (`Services/MetricsSource.swift`): add `LiveMetricsContext { startedAt,
  activityType }`; change `start(for:)` → `start(_:)`; keep a `start(for:sport:category:)` convenience
  overload on `LiveMetricsCoordinator` so the two workout call sites don't churn.
- **Enrich models** (`KilterModels.swift`): `KilterSession.{hrSeries,maxHR,restHR,metricsSourceRaw}`;
  `KilterLogEntry.{startedAt,endedAt,attemptTimestamps}`; `SessionMedia.assignedClimbUUID`.
- **Drive the session** (`KilterSessionManager` in `KilterBoardController.swift`): bind the app's
  `liveWorkout` / `kilterLiveActivity` / `sessionMedia`; on `start` begin HR + the Live Activity; on `end`
  flush `hrSeries`, stop HR, end the activity, and run media discovery + clip→climb auto-assign; track the
  active climb (`beginClimb`/`closeActiveClimb`) for timing + the HUD.
- **Pure helpers**: `KilterSessionStats` (timing/rest/pyramid/sends-per-hour), `KilterWorkoutBuilder`
  (+ `KilterMediaAssignment`) → `HighlightEngine.Workout(.climbing)`, `KilterLiveSnapshot` (throttle).
- **Live Activity**: `Shared/KilterActivityAttributes.swift`, `Services/KilterLiveActivityController.swift`,
  `SnappetWidgets/KilterLiveActivity.swift` (register in the bundle); `AppModel.kilterLiveActivity`.
- **UI**: root banner gets an HR pill + current climb + a tap-through to the summary;
  `KilterClimbDetailView` stamps per-climb timing/attempts + shows an HR pill; new
  `KilterSessionDetailView` (summary + reel); History session rows navigate to it.

## Output

The files named in Approach (new + modified), plus unit tests `KilterSessionStatsTests`,
`KilterWorkoutBuilderTests`, `KilterLiveSnapshotTests`, and a `LiveMetricsContext` rebase test in
`MetricsSourceTests`. Update `decisions.md`, `project.md`, `snappet-core-schema.md`, and the knowledge
graph `docs/knowledge-graph/data.js`.

## Acceptance criteria

- [x] A Kilter session captures live HR (watch or BLE band) and stores it on the session.
- [x] Per-climb time-on-climb, rest, and attempt counts are recorded and shown in a summary.
- [x] Photos/videos shot during the session auto-tag to the session + the climb they fall within.
- [x] A one-tap highlight reel is built from the session via `HighlightEngine` + `ReelExporter`.
- [x] A Lock Screen / Dynamic Island Live Activity shows the timer, HR, and current climb.
- [x] App + widget + watch type-check against the iOS 18 SDK (Swift 6); `xcodebuild test` green (266 tests).
- [x] No platform imports added to `HighlightEngine`.
- [x] `decisions.md` updated.

## Constraints

- On-device only; no backend/network/accounts. Keep the selector pluggable (no HR-only hardwiring).
- State verification honestly: type-check ≠ device run for HealthKit/Photos/AVFoundation/ActivityKit and
  the Kilter board itself.

## Test plan

1. `cd ios/App && xcodebuild test -scheme Snappet -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
   — the pure helpers (stats, builder, assignment, snapshot, context rebase) run with no device.
2. `cd ios/HighlightEngine && swift test` — engine unchanged, must stay green.
3. Device-only (deferred to a real board + watch/HR band + photos): live HR stream, the Live Activity
   rendering, board connect auto-session-open, Photos auto-discovery + reel export quality.
