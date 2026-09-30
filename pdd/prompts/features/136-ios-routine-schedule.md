# Prompt: Schedule a routine, with reminders

**File**: pdd/prompts/features/136-ios-routine-schedule.md
**Created**: 2026-09-29
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: routine-schedule — 136 schedule + reminders → 137 Habits link → 138 QR schedule + scan/photo import
**Design**: `docs/ux-research/routine-schedule/wireframes.html` (frames 1–5; user approved "A now, B later")
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

"Provide option to schedule the routine … and notify users to follow the routine with detailed option
to configure schedule and notification settings." A routine can be put on a schedule, Snappet reminds
you before it, nudges you if you haven't started, and the Routines list shows what's up next this week.

## Context the implementer needs

- No notification delegate existed; only one-shot rest-complete / Pomodoro / festival alerts.
- iOS caps pending local notifications at 64 per app, shared with those features.
- Starting a workout already has one funnel (`WorkoutHomeView.startWorkout(from:)`) with the
  resume/replace conflict dialog — a notification's Start must go through it.

## Approach

- Pure `RoutineSchedule` (weekly on weekdays every 1–4 weeks / every N days / once; one time or
  per-weekday; start; end never/on-day/after-N-sessions; reminder lead · nudge · night-before heads-up
  · sound · Time Sensitive; skipped days). Days are time-zone-free `DayKey`s. Terse, defaults-tolerant
  Codable stored as `Routine.scheduleData` (optional → lightweight migration; backup row carries it).
- Pure `RoutineReminderPlanner`: 14-day rolling plan within a 40-notification budget, Up next, week
  strip. "Starting cancels the nudge" = a started day plans nothing, applied by re-planning.
- `Services/RoutineReminders`: category + actions (Start now · Snooze 15 · Skip today), apply plan,
  delegate (routine category only). `RoutineScheduleSync` re-plans on edit, session start/finish,
  skip, and each foreground; no-op under UI-test launches.
- UI: detail Schedule card → `RoutineScheduleEditor`; `RoutineUpNextCard` + `ScheduleChip` on the list.
  Router one-shots `pendingRoutineStart` / `pendingShowRoutines`.

## Acceptance criteria

- [x] Schedule a routine with any repeat pattern / times / end; the card and list chip summarize it.
- [x] Reminder, nudge and heads-up are planned for the next 14 days; starting or skipping a day removes them.
- [x] Start now opens the player through the normal start path; Skip today records a skip; Snooze re-fires in 15 min.
- [x] Up next shows today's plan until done/skipped, then the next one; week strip shows done/planned/missed/skipped.
- [x] `RoutineScheduleTests` (22: DST, every-2-weeks phase, end rules, codec defaults, planner, up next, week) + `RoutineScheduleUITests` (schedule → card → Up next → skip) green.

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'`; `-only-testing:SnappetUITests/RoutineScheduleUITests`.
2. Device (owed): schedule 2 min ahead with 0-min lead → reminder arrives; long-press → Start now opens
   the player; Snooze re-fires; Skip today moves Up next; start the routine → no nudge arrives.
