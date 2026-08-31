# Prompt: Watch import gates on WHO recorded — a Quick Session never ghosts into "From Apple Watch"

**File**: pdd/prompts/features/127-ios-watch-import-source-gate.md
**Created**: 2026-08-31
**Project type**: Native iOS fix (Swift / SwiftUI) — code lands in this repo.
**Chain**: on-device verification of the release-fix batch → user report: "even my general quick
session mapped with from apple watch"
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

A session the user tracked in the app must never reappear as a "From Apple Watch" import. Today
it can: when a Quick Session (or any tracked session) runs with the watch streaming, Snappet's
watch companion records a real `HKWorkout` — and `workoutsForImport` fetches **every** HealthKit
workout with no source filter. The only guard is FR10, a *timing* heuristic (workout midpoint
inside a tracked gym interval ±90 s), which misses when windows drift and never covered Kilter
(decision Q2 excluded it deliberately, reasoning about *foreign* watch climbs — not the app's own
recording). Reported from the device: a Gym Tracker Quick Session ghosted into the section.

## Approach

Gate on **identity, before any timing logic** — a new pure
`WatchWorkoutReconciler.shouldImport(sourceBundleID:sourceProductType:)`:

1. Any `com.snappet*` source is rejected: the app's own companion recording is already
   represented by the tracked session (gym, Kilter, festival — all of them, including sessions
   later discarded).
2. Only workouts whose recording device is a real Watch (`productType` "Watch…") import — the
   section is *called* "From Apple Watch"; an iPhone-app-written workout (Google Fit et al) is
   neither recorded on a watch nor missing from its own app, so importing it mislabels
   provenance. `nil` fails closed.

`WorkoutSummary` gains `sourceBundleID`/`sourceProductType` (filled from `HKSourceRevision` at
the HealthKit edge, defaulted so the list path is untouched); the import service filters beside
the prompt-125 tombstone check. FR10 stays — it still suppresses an *Apple Workout app* recording
the user double-tracked during an in-app gym session.

## Acceptance criteria

- [ ] Own-companion / own-bundle sources never import, regardless of timing (unit-tested).
- [ ] Foreign watch recordings still import; iPhone-written and unknown-device workouts don't
      (unit-tested).
- [ ] FR10 behavior unchanged (existing reconciler tests stay green).
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).
- [ ] `decisions.md` + knowledge graph updated.

## Constraints

- Pure decision in the reconciler; HealthKit types stay at the service edge (repo layering).
- Existing wrongly-minted anchors are NOT retro-swept: the user deletes them from History, and
  the prompt-125 tombstone + this gate each independently prevent re-minting.

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'` — new `shouldImport` cases + existing suite.
2. Device leg: on MrRobot, delete the ghost row, run a fresh Quick Session with the watch
   streaming + film a clip, relaunch — no new "From Apple Watch" row appears.
