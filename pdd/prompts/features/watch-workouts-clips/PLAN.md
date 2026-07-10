# PLAN — Apple Watch workouts → Clips feed

**Created**: 2026-07-10
**Project type**: Native iOS feature (Swift / SwiftUI).
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Why

The app has no control over Apple Watch workouts — the user starts/stops them on the watch in the native
Workout app. Today Snappet only reads those workouts post-hoc into a transient `WorkoutSummary` for the
Reel / Workout-list; they never reach the Clips feed. This initiative closes that gap: after any watch
workout finishes and syncs, Snappet mints a persisted anchor, auto-discovers the photos/videos shot
during it, and posts them to Clips — populating the feed from workouts the app never touched.

## Locked product decisions (from requirements discovery, 2026-07-10)

1. **Anchor = a persisted `WorkoutSession`** (gym kind), minted per `HKWorkout`, `exercises` empty.
2. **All `HKWorkoutActivityType`s** are eligible, including climbing.
3. **Background delivery** via `HKObserverQuery` — workouts appear without a foreground launch.
4. **Media-only** — a workout with zero clips in its window produces no post.
5. **Unbounded first run** — first install scans all-time so the feed has out-of-box content.
6. **Kilter owns board climbing** — watch `.climbing` is a *distinct* type that coexists (never merged
   with, never suppressed against, Kilter). Gym-overlap suppression is gym-only.
7. **Separate list section** — watch-origin sessions live under a "From Apple Watch" section in the
   Workout-list, segregated from tracked history.

## Stack (one PR each — one prompt = one job)

- **P1 — data spine** ✅ built + unit-tested: `WorkoutSession.healthKitWorkoutUUID` anchor + the pure
  `WatchWorkoutReconciler` (media-only / idempotency / late-media / gym-overlap) + `WatchWorkoutImportService`
  shell (HealthKit read, one Photos scan, mint/attach) + foreground reconcile wiring. Feed renders watch
  posts automatically (they're `WorkoutSession`s the composer already handles). Unbounded first run.
- **P2 — background delivery** ✅ built (device leg owed): `HKObserverQuery` + `enableBackgroundDelivery`
  (entitlement already present) + observer lifecycle centralized on `AppModel` so workouts import without
  opening the app.
- **P3 — surfaces** ✅ built (device leg owed): the "From Apple Watch" History section (in the Workout
  app), the exercise-less session-detail rendering + note + distance/energy, and the ⌚ source pill on the
  Clips poster.

All three built on branch `feat/watch-workouts-clips-spine`; full unit suite green (1628). Device legs
owed (user will run): real watch workout + camera-roll media → Clips post + section + detail; background
wake; no dupes on relaunch.

## Non-goals

Empty (media-less) watch workouts as posts; editing a watch session as a tracked workout; Android
(mirror later); reacting to Photos deletions.
