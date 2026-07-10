# Prompt: Apple Watch workouts → Clips — background delivery (P2)

**File**: pdd/prompts/features/watch-workouts-clips/P2-background-delivery.md
**Created**: 2026-07-10
**Chain**: watch-workouts-clips/PLAN.md → P2 (depends on P1 data spine)
**Context**: `pdd/context/{project,conventions,decisions}.md`

## Goal

Make watch workouts appear in Clips WITHOUT opening the app. P1 reconciles on launch + foreground; P2
adds HealthKit background delivery so the watch finishing a workout wakes Snappet to import it.

## Approach

- `HealthKitService.enableWorkoutBackgroundDelivery(onChange:)` — an `HKObserverQuery` on
  `workoutType()` (retained) + `enableBackgroundDelivery(for:frequency:.immediate)`. The observer
  handler MUST call its completion handler unconditionally, or HealthKit throttles/stops delivery.
- Centralize reconcile on `AppModel`: it gains `modelContainer` (handed in by `SnappetApp` after the
  container builds, since a background callback has no SwiftUI environment context), a
  `reconcileWatchWorkouts()` that runs `WatchWorkoutImportService` against `container.mainContext`, and
  `startWatchWorkoutObserver()` (idempotent) whose `onChange` hops to the main actor and reconciles.
- `RootShell` calls `app.startWatchWorkoutObserver()` once in the load task; foreground + launch both
  route through `app.reconcileWatchWorkouts()`.

## Output / touched

`HealthKitService.swift` (observer), `AppModel.swift` (container + reconcile + observer registration),
`RootShell.swift` (start observer, route reconcile), `SnappetApp.swift` (attach container).

## Acceptance criteria

- [x] Observer registers once; completion handler always called.
- [x] Entitlement present (`com.apple.developer.healthkit.background-delivery` — already in
      `Snappet.entitlements`).
- [x] App builds; full unit suite green.
- [ ] Device leg: finish a watch workout with the app backgrounded → it appears in Clips on next open
      (or sooner). Needs a real device + paired watch; the simulator can't deliver HealthKit background.

## Constraints

Background wake is best-effort + throttled by iOS; the foreground reconcile (P1) is the guaranteed path.
`.limited`/denied Photos ⇒ no import (documented).
