# Prompt: Android — streamline the workout loop (set prefill, one-tap start, analytics)

**File**: pdd/prompts/features/59-android-workout-loop.md
**Created**: 2026-06-15
**Project type**: Native Android feature (Kotlin / Jetpack Compose / Room) — code lands in this repo.
**Chain**: 2026-06-09 product review → Android Wave 2 (second of three; stacks on #87 authoring).
**Source**: GitHub issue [#95](https://github.com/harshal2802/Snappet/issues/95)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

The daily gym loop was needlessly expensive: the weight field reset to the (empty) target on every
set, discarding what the user typed 30 seconds ago; starting a workout opened on the read-only
Exercises catalog with Start buried at the bottom of a detail screen; and consistent loggers saw no
progression (a 3-tile strip vs iOS's volume chart + PRs + per-exercise progress), with session
detail showing only "N/M sets" though per-set weights/reps were persisted. This pays the loop off on
both ends using data already in Room.

## Context the implementer needs

- `WorkoutPlayerScreen.kt` re-prefilled reps/weight from the (null) routine target on each set. With
  #87 landing target weights and authoring, the fix is to carry set N's actuals into set N+1, then
  fall back to the routine target, then the last finished session's value.
- Per-set actuals (`actualReps`/`actualWeight`/`completedAt`) were persisted in the session JSON but
  never displayed; `WorkoutDao.sessionsFlow` was never consulted for prefill or analytics.
- `org.json` is unavailable in JVM tests, so analytics must run on a decoded value-type view, not by
  re-decoding `WorkoutSession.exercises` (which uses `org.json`).

## Approach

- `WorkoutAnalytics` (pure): weekly volume (kg, lb-normalised), PRs, per-exercise progress, last
  session / last set. Public functions take `WorkoutSession`; the math runs on a JSON-free
  `SessionView` so it's unit-tested directly.
- Player: prefill set N+1 from set N's actuals (then target, then last-time); show a "Last time:
  60 kg × 8" hint. Root: default section = Routines; inline Start icon per routine row + a "Repeat
  <last>" card. Dashboard: 8-week volume bars + a PR strip. Exercise detail: a progress chart.
  Session detail: per-set reps/weight in the chosen unit.

## Output

- `WorkoutAnalytics.kt` + `WorkoutAnalyticsTest.kt`; edits to `WorkoutRoot.kt` and
  `WorkoutPlayerScreen.kt`. Knowledge-graph node for the analytics model.

## Acceptance criteria

- [ ] Set N+1 prefills from set N; last-session hint visible during a set.
- [ ] Routine start reachable in one tap from the module root; repeat-last card present with history.
- [ ] Dashboard shows volume trend + PRs; exercise detail shows progress over time.
- [ ] Session detail lists actual reps/weight per set in the chosen unit.
- [ ] Aggregations unit-tested without a device.

## Constraints

- On-device only; aggregations read existing Room data, no new persistence.
- Keep aggregation/formatting pure (out of the Compose layer) for `:app:testDebugUnitTest`.

## Test plan

1. `:app:testDebugUnitTest` (`WorkoutAnalyticsTest`) + `:app:assembleDebug`.
2. Device-pending: run two sessions on the emulator and confirm prefill + charts + last-time hint.
