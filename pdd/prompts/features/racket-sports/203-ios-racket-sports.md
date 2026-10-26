# Prompt: Racket sports — matches & drills in Quick Session (prompt 203)

**File**: pdd/prompts/features/racket-sports/203-ios-racket-sports.md
**Created**: 2026-10-23
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: standalone; follows `workout-type-parity/PLAN.md` (the discipline axis) and prompt 109 (the pager)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Wireframe (user-approved first)**: `docs/ux-research/racket-sports/wireframes.html` (+ `.png`)

## Goal

The user plays table tennis tournaments and wears a Google Fitbit, not an Apple Watch. Snappet had no
racket sport: a match logged as "Other", game-by-game scores had nowhere to go, and a Fitbit user got no
heart rate on a tracked session. Give racket sports real support — specific sports, matches AND drill
practice, a score per game (or set), the tournament day as one session, and heart rate from any wearable.

User decisions (2026-10-23): a new Quick Session type (not a mini-app); be specific about the sports
(table tennis, badminton, tennis, padel, pickleball, squash); cover matches and drills; score per game;
heart rate back-filled from Apple Health; all six sports in v1, tennis/padel included.

## Approach

- **Model (additive Optionals only).** `WorkoutDiscipline.racket`; `SessionExercise.racketSportRaw /
  racketModeRaw / opponent / partner / racketBestOf (0 = open) / racketPointsTo / racketSuperTiebreak /
  racketEvent / racketRound / racketEndRaw / drillMeasureRaw`; `SetLog.scoreFor / scoreAgainst /
  tiebreakFor / tiebreakAgainst / superTiebreak / drillMade / drillTried / longestRally`. Racket entities are
  `.duration` kind. A match's ids are `adhoc-racket-match-<sport>` + "<Sport> match" (the activity is the
  sport); a drill's `adhoc-racket-drill-<sport>` + its name.
- **Pure engine** `RacketSports.swift` (rules, formats, derived match state, rounds, drill catalog) and
  `RacketStats.swift` (records, H2H, summary, titles, Library headline, per-unit windows + HR).
- **Pager.** Racket card on the add page + "Racket sport" in the add menu → `RacketSetupSheet`; the page hero
  routes to `RacketMatchHero` / `RacketDrillHero`; score via `RacketScoreSheet`; Record = film the game and
  enter its score; Next match keeps sport/format/event/partner and advances the round. Match-decided
  banner (+ burst on a win). Rail chip = opponent + result; no plan row and no rest timer for matches.
- **Everywhere else.** Summary / recap / session detail (`RacketRecapCards`, score editing in Edit sets),
  Library + Activity dashboard (win rate / accuracy / longest rally), Clips (Racket chip, match post title,
  "Game N" labels), Health import labels, `WorkoutActivityMapping` per sport (padel → tennis).
- **Heart rate from Apple Health.** `WorkoutHRBackfill` (pure) + `AppModel.backfillWorkoutHR` on launch /
  foreground / HK wake and on session-detail open.

## Acceptance criteria

- [x] A table tennis best of 5 is scored game by game, decides at 3, shows the result, Next match → QF.
- [x] Tennis/padel sets with 7–6 tiebreaks and an optional super-tiebreak decider; bad scores warn, still save.
- [x] Drills log made/tried (accuracy vs last time), longest rally, or time.
- [x] The day reads as one tournament: overview ribbon, summary, session detail, Clips post per match.
- [x] A session with no live HR picks up Health's HR once the wearable syncs; per-game HR in the recap.
- [x] Unit tests: `RacketScoringTests`, `RacketStatsTests`, `WorkoutHRBackfillTests`; UI: `RacketSportsUITests`.
- [x] Follow-up (2026-10-26, user asked): an empty Quick Session whose first entry is a match retypes the
      Apple Watch workout (`LiveWorkoutMessage.retype`; the watch discards the empty workout and restarts the
      right type from the same start time). Pure rule `WorkoutActivityMapping.retypeTarget`, tested.
- [ ] Device legs (owed): a real tournament with Fitbit HR sync; filmed games; Apple Watch: start an empty
      Quick Session, add a match → the watch shows Table Tennis, Health has ONE table tennis workout (no stray
      strength one) covering the whole session.

## Out of scope (v1)

Point-by-point scoring, a live scoreboard mode, opponent profiles beyond name + H2H, racket blocks in
routines, changing the watch's workout type once something is logged, Android.
