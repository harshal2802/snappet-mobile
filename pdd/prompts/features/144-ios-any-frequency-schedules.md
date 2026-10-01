# Prompt: Any-frequency routine schedules

**File**: pdd/prompts/features/144-ios-any-frequency-schedules.md
**Created**: 2026-09-30
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: hangboard-protocols — 139 → 140 → 141 → 142 → 143 → **144 any-frequency** → 145 force sensor
**Design**: `docs/ux-research/hangboard-protocols/wireframes.html` frames 7–9 (approved; Habits "done after N", default 1)

## Goal

"User should be able to configure any frequency, even hourly or minute intervals."

## Approach

- `RoutineSchedule.daily: DailyRepeat?` — `.times([…])` or `.every(minutes, from, until)` (1 min … 12 h);
  nil = once a day (unchanged). `slotStarts`, `slots(from:through:)`, `SlotKey`, `skippedSlots`
  (Skip this one), `doneAfterSessions` (Habits). New Codable keys only; `t` = the first session so
  older builds / QR readers still get one time.
- Planner walks slots: a session counts for its **nearest** slot that day; per-slot ids (slot 0 keeps
  the old shape); heads-up only for the day's first; nudges off when sessions are < 60 min apart;
  "Remind me: every session / first of the day"; a routine stops planning once it alone fills the
  40-notification budget (an every-minute schedule stays cheap). The editor says plainly how far ahead
  reminders reach when the 64-pending cap bites.
- Up next: a slot > 15 min past is treated as missed; "· 2 OF 7"; Skip this one. Week strip "k/N".
  Habits ticks the day once N sessions are done.

## Acceptance criteria

- [x] Every N minutes/hours in a window, or set times; preview lists the times; summary + chip say so.
- [x] Reminders per session within budget; nudges suppressed under an hour; first-of-day option.
- [x] Up next / week / Habits count sessions; skip one session or the whole day.
- [x] Once-a-day schedules plan exactly as before (all prior schedule tests green).
- [x] `AnyFrequencyScheduleTests` (15) + `RoutineScheduleUITests.testEveryTwoHoursScheduleShowsSessionCount`.
