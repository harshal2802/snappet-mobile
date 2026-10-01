# Prompt: Progression P1 — XP, levels, Form, history backfill, finish-screen XP, Home buddy

**File**: pdd/prompts/features/148-ios-progression-p1-xp-level-form.md
**Created**: 2026-10-01
**Project type**: Native iOS feature (Swift / SwiftUI / RealityKit) — code lands in this repo.
**Chain**: session-progression — 146 history → 147 3D buddy → **148 P1 engine + finish + Home** → 149 P2 buddy screen, pause, freezes → 150 P3 level-up moments + detail slot → 151 P4 widgets
**Design**: `docs/ux-research/progression/wireframes.html` frames 1, 8, 9 + the rules tables (approved "as drawn": Q1–Q6)

## Goal

Every session earns XP; XP raises a permanent level; the level grows the 3D buddy (Egg → Legend).
Form (recent consistency) is mood only. Past sessions count from day one.

## Approach

- Pure `Progression` (one rules table): XP lines per session (+50 finish ≥ 5 min with completed work,
  +1/min ≤ 60, +20 on plan, +25 per record ≤ 3 from `SessionInsights` badges, +50 count milestone,
  +10 × weeks streak once a week ≤ 100, Health import +25), a ledger over all history oldest-first with a
  300 XP/day cap, level n→n+1 = 100 + 50·n, stages 1 / 2–4 / 5–9 / 10–19 / 20+, Form = planned done ÷
  planned over 28 days (a day with a skipped slot is neutral; today only once done) or, without enough
  plan, recent vs usual week (12 weeks before; 2/week for newcomers), overall week streak.
- Derived, never stored → backfill is automatic and edits re-judge. Each session's lines are cached by
  a fingerprint of it + everything before it, so finishing a session costs one session's work
  (450 sessions: cold 1.7 s debug once per launch, warm 8 ms, finishing 18 ms).
- `SessionXPCard` on the finish screen: cheering buddy, "+N XP", lines, daily-cap line, level bar with
  today's gain, "Level up!" / "grew up" line. Under 5 minutes → a one-line explanation.
- `BuddyHomeCard` at the top of Home (feed and first-run hero) once any session has earned XP: first an
  egg — "Your N so far count — it hatches at Level L" → Hatch grows through each stage to the earned one;
  then a still buddy with level, mood, streak and XP to next. Tap = cheer. `BuddyDefaults` scratch suite
  under UI tests.
- `BuddyCreatureView` gains `animated` (stills in lists) and `interactive` (no drag inside scroll views).

## Acceptance criteria

- [x] `ProgressionTests` (13): levels/stages, XP lines, minute cap, too-short/empty, on plan, streak once
      a week, Health import, backfilled ledger, daily cap, the unsaved current session, cache speed +
      edit invalidation, Form by plan (skips neutral) and by usual week, overall streak.
- [x] `ProgressionUITests`: finish screen XP → Home egg; seeded history hatches to Level 10 · Adult.
- [ ] Device leg: real history on MrRobot — hatch level feels right; finish-screen XP after a real session.
