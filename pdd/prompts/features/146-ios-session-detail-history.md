# Prompt: Session detail — routine history, records, streaks, milestones

**File**: pdd/prompts/features/146-ios-session-detail-history.md
**Created**: 2026-09-30
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: session-progression — **146 session detail history** → (next) progression / character (XP, level, Form)
**Design**: `docs/ux-research/session-detail/wireframes.html` (approved plan: no XP yet; header leaves room for it)

## Goal

A finished session's detail answered "what did I do" but never "how did that compare". Make it show
where the session sits in its routine's history, for every workout type: change since last time, records
and firsts, streaks, the next milestone and the trend — and fix the bugs a review of the page found.

## Approach

- Pure `SessionInsights` (no SwiftUI): comparable series (same routine; for quick sessions, same name +
  same workout type), ordinal, week streak, on-plan vs the routine's schedule, `Kind` (strength /
  hangboard / timed / climb / run / other), per-type headline stats + `Change` vs last time, `Badge`s,
  count milestones, `Progress` series, strength `ExerciseCompare` (est. 1RM, per-set change, "held for 3
  sessions — try +2.5 kg" nudge), hangboard `ForceGrid` + fatigue, climbing `PyramidRow` vs 30 days.
- `SessionInsightsViews`: header (subtitle "date · min · 8th Push Day", streak / on-plan / avg-HR chips,
  hero stats with change, badge strip, Swift Charts progress with best-ever rule, next-milestone bar),
  exercise compare / force grid / pyramid cards. Detail title = routine name.
- Heart rate collapses to one row ("Heart rate & effort · avg · max", tap to expand). Empty media is
  one compact row (Find / Add) instead of half a screen.
- Finish screen shows the same "This session earned" strip (`SessionEarnedStrip`).
- Bug fixes: "−−12 bpm rec." (double minus) and "0 bpm rec."; bodyweight strength "0 kg" volume → reps;
  "Median time on climb 0:00" hidden; set tiles rounded 67.5 → "68 kg" and hang load 11.25 → "11.3"
  (typed values now shown exactly).
- `-uiTestSeedRoutineHistory` seeds Push Day ×8, Finger day ×6 (force reps), Bouldering ×5, Easy run ×4.

## Acceptance criteria

- [x] `SessionInsightsTests` (12) on the seed fixture; `SetMeasureDisplaySummaryTests` exact weights.
- [x] `SessionInsightsUITests`: each type shows ordinal, badges, progress, milestone and its type card;
      screenshots checked for all four types.
- [x] No XP / level / character — left for the progression initiative.
- [ ] Device leg: real history on MrRobot reads right (routine with a schedule → "On plan").
