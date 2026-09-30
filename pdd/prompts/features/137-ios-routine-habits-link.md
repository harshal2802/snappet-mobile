# Prompt: Link a scheduled routine to Habits

**File**: pdd/prompts/features/137-ios-routine-habits-link.md
**Created**: 2026-09-29
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: routine-schedule — 136 schedule + reminders → **137 Habits link** → 138 QR schedule + scan/photo import
**Design**: `docs/ux-research/routine-schedule/wireframes.html` frames 3, 6, 7 (user approved: habit per
routine by default, attach-to-existing allowed; streak counts scheduled days only; skip = excused by
default, per-habit choice)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

"Schedule the routine which can get linked with habits app as well." A scheduled routine shows up in
Habits, finishing it ticks the habit off, and the habit's streak respects the routine's rest days.

## Context the implementer needs

- `Habit` was every-day only; `HabitMilestones.streak` counted consecutive calendar days, so a
  Mon/Wed/Fri habit could never exceed 1.
- `HabitCompletion` is read by Home (`TodayDigest`), the Today widget (snapshot + check-off
  reconciler) and backup — all assume "a row means done".

## Approach

- Link lives on the routine (`Routine.linkedHabitID`) so several routines can feed one habit and
  unlinking never touches habit history. Device-local; never in a QR code.
- `Habit` gains optional `weekdays`, `skippedDayKeys`, `skipsBreakStreak`. Skips are NOT fake
  completions, so no completion reader changes meaning.
- Pure `HabitSchedule` (linked routines' schedules › own weekdays › every day) drives
  `HabitMilestones.streak/completionRate` (every-day = the old rule), the week strip, Home's
  "habits left" and the widget's list (`dueIDs`).
- `HabitRoutineLink`: apply editor choice, `markDone` on session finish (idempotent, un-skips),
  `recordSkip` from Skip today, `unlinkAll` on unlink / habit delete.
- UI: Schedule editor Habits section; Habits row shows schedule line, dashed rest days, skip glyph,
  "Linked routine · today 7:00 AM ▶ Start"; habit editor Days (every day / specific days, read-only
  when linked) + skip policy + Unlink.

## Acceptance criteria

- [x] Scheduling a routine (Track in Habits on) creates a linked habit; finishing the routine ticks it.
- [x] Streak / 30-day rate count due days only; excused skips keep the streak, "Missed" policy breaks it.
- [x] Home + widget don't count a habit on its day off as "left".
- [x] Start from the habit row opens the routine in the player.
- [x] `HabitScheduleTests` (12), `HabitRoutineLinkTests` (5), `RoutineScheduleUITests.testScheduledRoutineShowsAsLinkedHabitWithStart`; full unit suite green.

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'`; `-only-testing:SnappetUITests/RoutineScheduleUITests -only-testing:SnappetUITests/HabitUITests`.
2. Device (owed): schedule M/W/F with Track in Habits → finish Wednesday's session → habit ticked,
   streak holds through Thursday; Skip Friday from the notification → streak survives (Excused).
