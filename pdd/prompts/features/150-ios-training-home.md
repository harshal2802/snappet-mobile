# Prompt: Home, built around your buddy (training-first Home)

**File**: pdd/prompts/features/150-ios-training-home.md
**Created**: 2026-10-01
**Project type**: Native iOS feature (Swift / SwiftUI / RealityKit) — code lands in this repo.
**Chain**: session-progression — 148 P1 → 149 P2 → **150 Home** → P3 moments → P4 widgets
**Design**: `docs/ux-research/progression/home.html` (approved "as drawn": Q1–Q5; training only feeds XP)

## Goal

For people who train, Home leads with the buddy, then one clear thing to do today, the week in XP,
recent wins and what's coming up — with the other apps and the activity feed below. Everyone else keeps
the classic Home.

## Approach

- `HomeDashboardView`: once any session has earned XP → `TrainingHomeView`; otherwise flagship / feed as before.
- `BuddyHero`: live 3D buddy (tap to cheer; idle animation stops when scrolled off via
  `onScrollVisibilityChange`), date + streak/freeze chips, level, mood + Form, XP bar, next stage; taps
  through to `BuddyScreen`. States: hatch (egg first), paused (asleep, "back <date>"), training now
  (minutes, sets, "+N XP so far", "Level N in X XP", Resume → `pendingWorkoutResume`). Replaces the title.
- `TodayTrainingCard`: today's planned routine with "≈ +N XP" (average of its last three awards) and typical
  minutes, Start (`pendingRoutineStart`) / Skip today / Pause…; "Done for today ✓ · +N XP"; rest day with
  what's next; no schedule → pick a routine; paused → calm card + end pause.
- Notes: kind missed-day note (not when paused or already trained today); "a freeze covered last week".
- This week: XP per day with planned days outlined (planner's week). Recent wins (records, first sends,
  count milestones, last 14 days). Coming up: next growth, closest count milestone, next freeze.
- Other apps: the classic Today cards (minus workout) as a 2×2 grid. Activity feed at the bottom.
- The P1 Home card (`BuddyHomeCard`) is retired — the hero replaces it.

## Acceptance criteria

- [x] `TrainingHomeTests` (5): XP estimate, week XP, recent wins, next growth/milestone, missed note.
- [x] `ProgressionUITests.testTrainingHomeLeadsWithTheBuddy` (+ the P1/P2 tests updated); screenshots checked.
- [ ] Device leg: real data on MrRobot — Start from Home starts the planned routine; live hero mid-workout.
