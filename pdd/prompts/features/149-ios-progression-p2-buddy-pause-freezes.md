# Prompt: Progression P2 — buddy screen, pause mode, streak freezes, style

**File**: pdd/prompts/features/149-ios-progression-p2-buddy-pause-freezes.md
**Created**: 2026-10-01
**Project type**: Native iOS feature (Swift / SwiftUI / RealityKit) — code lands in this repo.
**Chain**: session-progression — 148 P1 → **149 P2** → 150 Home redesign (`docs/ux-research/progression/home.html`) → P3 moments → P4 widgets
**Design**: `docs/ux-research/progression/wireframes.html` frames 4–7 (approved "as drawn")

## Goal

Give the buddy its own screen and make the system forgiving: pause mode for injury / travel / illness /
rest, and streak freezes earned by consistency — so missing life events never feels like punishment.

## Approach

- **Pauses** are the only stored state: a small JSON list in `BuddyDefaults` (`PauseStore`; scratch suite
  under UI tests). Reason, start, planned end (or until back), actual end, quiet reminders.
- **Freezes** are derived: walking week by week, every 4th streak week earns one (hold ≤ 2); a missed
  week spends one (or resets the streak); a week overlapping a pause is held; this week can't break it.
  The XP streak bonus and the overall streak both use this walk.
- **Form** while paused is held at its value when the pause began; afterwards paused days are neutral
  (not planned; excluded from the recent-vs-usual window). "Skip today" is neutral too (P1 fix).
- Quiet reminders: `RoutineScheduleSync.replan` drops notifications a quiet pause covers.
- `BuddyScreen` (from Home card): live 3D buddy, level + next growth, Form tile → `FormSheet`, week
  streak + freezes, pause row → `PauseSheet` / "I'm back — end pause", How XP works → `XPRulesSheet`
  (generated from `Progression.Rules`), Style → `BuddyStyleSheet` (Creature; others locked), recent XP.
- Home card: tapping the words opens the screen; it shows freezes, a "freeze kept your streak" line and
  the sleeping buddy when paused. Finish screen: "You're paused — this still counts · End pause".

## Acceptance criteria

- [x] `ProgressionPauseTests` (9): freeze earned + spent, reset without one, cap at 2, paused week held,
      streak XP uses freezes, Form held while paused, paused days neutral after, active pause, JSON.
- [x] `ProgressionUITests.testBuddyScreenFormPauseRulesAndStyle`: screen → Form → pause (Resting, held,
      end pause) → rules → style locked; screenshots checked.
- [ ] Device leg: pause with quiet reminders actually silences a scheduled routine's notification.
