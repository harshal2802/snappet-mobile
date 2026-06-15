# Prompt: Android — routine & custom-exercise authoring + full bundled exercise catalog

**File**: pdd/prompts/features/58-android-workout-authoring.md
**Created**: 2026-06-15
**Project type**: Native Android feature (Kotlin / Jetpack Compose / Room) — code lands in this repo.
**Chain**: 2026-06-09 product review → Android Wave 2 (first of three; #95 stacks on this).
**Source**: GitHub issue [#87](https://github.com/harshal2802/Snappet/issues/87)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Android's Workout Tracker could log workouts but never represent the user's actual program: no
routine editor, no custom-exercise editor, no exercise picker, and only a 20-entry curated catalog.
The data layer was fully built and unused — `insertRoutine`'s only caller was the first-open seed,
and `updateRoutine`/`deleteRoutine`/`insertCustomExercise`/`deleteCustomExercise` had zero callers.
This ships the authoring UI over that existing DAO, plus the full 873-exercise public-domain Free
Exercise DB the iOS app already bundles, so the module finally retains users past week one.

## Context the implementer needs

- `feature/workout/WorkoutModels.kt` already has `WorkoutRoutineExercise` (with an optional
  `weight`), `WorkoutCustomExercise`, and the JSON column encode/decode helpers (`WorkoutJson`). No
  schema change is needed — routines and custom exercises are existing entities, and a routine's
  exercise prescriptions live in a JSON `String` column. **The DB stays at version 4.**
- `WorkoutCatalog` was a hardcoded Kotlin `object` of 20 exercises. The starter routines reference
  ids (`Bodyweight_Squat`, etc.) that all exist in the full Free Exercise DB, so the curated list
  can become an offline fallback while the bundled asset becomes the live catalog.
- `org.json` is stubbed-to-throw in JVM unit tests, so the catalog parser must use
  `kotlinx.serialization` (already a dependency) to stay unit-testable without a device.

## Approach

- Bundle `assets/workout/exercises.json` (copied from the iOS resource). Add `WorkoutExerciseParser`
  (pure, `kotlinx.serialization`) to parse + search it; `WorkoutCatalog.load(context)` reads the
  asset once at module open and swaps the curated subset for the full list.
- Add `WorkoutAuthoring.kt`: `RoutineEditorScreen` (name + sets/reps/rest/weight lines, add/remove),
  `ExercisePickerScreen` (search the full catalog), `ExerciseEditorScreen` (custom exercise:
  name/category/level/equipment). Wire them into `WorkoutRoot`'s local screen enum with a draft held
  across the picker round-trip. Routine detail gains Edit / Duplicate / Delete; the Exercises section
  gains search + create/delete custom.

## Output

- `assets/workout/exercises.json`, `WorkoutExerciseParser.kt`, `WorkoutAuthoring.kt`; edits to
  `WorkoutCatalog.kt` and `WorkoutRoot.kt`. Knowledge-graph nodes for the new Android screens.

## Acceptance criteria

- [ ] Create, edit, duplicate, and delete a routine; the picker searches the full catalog.
- [ ] Create and delete a custom exercise; it appears in the catalog and picker.
- [ ] Catalog search returns from the 800+ bundled exercises.
- [ ] Starter seed and existing sessions unaffected; no destructive schema change.
- [ ] Parser + search unit-tested without a device.
- [ ] Knowledge graph updated in the same change.

## Constraints

- On-device only; the catalog is a bundled asset, no network.
- Pure parse/search logic stays out of the Compose layer so it runs in `:app:testDebugUnitTest`.

## Test plan

1. `:app:testDebugUnitTest` (`WorkoutExerciseParserTest`) + `:app:assembleDebug`.
2. Device-pending: scroll/search the 873-row catalog and author a routine on the emulator.
