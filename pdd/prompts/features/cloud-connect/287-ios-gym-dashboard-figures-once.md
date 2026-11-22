# Prompt: The Gym dashboard works its figures out once per redraw

**File**: pdd/prompts/features/cloud-connect/287-ios-gym-dashboard-figures-once.md
**Created**: 2026-11-22
**Project type**: iOS
**Chain**: follow-up to prompt 279 (small redraw pauses left there)

## Problem

One redraw of `WorkoutDashboardSection` built `WorkoutDashboardStats` about eight times and the
weekly volume three times, and each record row walked the whole history again to count sessions.

## Change

- A `Figures` holder per value of the view: stats, weekly volume and session counts are each made
  at most once. The parent makes a new value when its data changes, so nothing is kept past a
  change.
- `WorkoutMath.sessionCounts(history:)`: every exercise's session count in one pass.

## Tests

`WorkoutMathTests.testSessionCountsInOnePassMatchesSessionCountPerExercise`.

## Not measured

The pauses were not re-measured on a phone after this change.
