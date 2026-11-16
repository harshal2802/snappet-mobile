# Prompt: Racket screens reachable on any finished session; removing the last exercise (prompt 262)

**File**: pdd/prompts/features/racket-sports/262-ios-racket-finished-session-reach.md
**Created**: 2026-11-16
**Project type**: Native iOS fix (Swift / SwiftUI) — code lands in this repo.
**Chain**: state-machine review of the workout tracker (findings F9, F16 and the knowledge-graph section). Follows prompt 260.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md` (no new field, no new raw value)

## Goal

Two fixes on a finished session, plus the knowledge graph.

1. **F9.** On a finished session, "Your videos", "Edit match", "Keep rallies only…" and a game's heart rate are only
   offered by `RacketRecapCards`. `SessionRecapCards` renders that card only when `FreeformSummary.dominant == .racket`
   (most completed sets), and `SessionDetailView` renders `SessionRecapCards` (and passes `onOpenVideos` /
   `onEditMatch`) only for `SessionInsights.Kind` `.timed / .run / .other` (most exercises). A session with one match
   and two lifts is `.strength`: no racket card, so the match's videos and its editor can't be reached at all.
2. **F16.** Removing the last exercise of a finished session leaves an empty session in History.

## Context the implementer needs

- `SessionRecapCards` callers: `SessionDetailView.typeDetail` (hangboard / climb / timed-run-other branches) and
  `FreeformDoneSummaryView` (the Finish summary). The strength branch of `typeDetail` renders `ExerciseCompareCard`s
  only. No other caller (grep `SessionRecapCards(` and `RacketRecapCards(`).
- A racket entity is `discipline == .racket` (`racketMode` defaults to `.match`, so that is "a match or a drill");
  `RacketStats.summary` uses the same test, and `RacketRecapCards` renders only when it is non-nil.
- `RacketRecapCards` presents its own sheets when the host passes `nil` closures; the session detail passes host
  closures because the card sits inside a lazy `List` whose re-render can drop a sheet owned by the row.
- Edit match is finished-session only (`RacketMatchEditAvailability`); the Finish summary's session is still active,
  so Edit match stays hidden there (unchanged).
- `SessionCascade.deleteWorkoutSession` deletes the session row and its `SessionMedia` / `StudioProject` / festival
  rows; it never calls Photos, so photos and videos in the Photos library stay (a racket recording's parts too).

## Approach

- Pure `RacketRecapReach` (new, `Features/WorkoutTracker/RacketRecapReach.swift`, Foundation only):
  `hasRacketEntity(_:)`, `addsRacketCard(dominant:exercises:)` (the racket card after the dominant discipline's own
  cards; never when racket is dominant, which already renders it) and `detailAddsRacketCard(kind:exercises:)` (the
  detail's strength branch renders no `SessionRecapCards`, so it adds the racket card itself).
- `SessionRecapCards`: after the dominant switch, the racket card when `addsRacketCard`. One builder for the card, so
  both places pass the same closures.
- `SessionDetailView.typeDetail`: every branch passes `onOpenGame` / `onOpenVideos` / `onEditMatch` (host-presented);
  the strength branch adds `RacketRecapCards` when `detailAddsRacketCard`.
- F16: pure `SessionSetEditing.isLastExercise(_:in:)`. The removal confirmation, for the only exercise, asks to delete
  the session instead: "Delete this session?", "Delete session" (destructive) / Cancel, message saying the session and
  its sets are deleted and its photos and videos stay in Photos. Delete pops the detail and runs
  `SessionCascade.deleteWorkoutSession` + save once the detail has gone (so nothing renders a deleted model).
- Test seed: `-uiTestRacketMixedSession strength|timed` with `-uiTestSeedRacketVideos` — the seed's recorded match
  (no drill) plus two strength exercises (strength dominant, Kind `.strength`) or two timed holds (timed dominant, Kind
  `.timed`, through `SessionRecapCards`). Existing seeds unchanged.
- Knowledge graph: recap / detail → Your videos / Edit match edges say "whenever the session has a racket entity";
  `wt-stopwatch-timing` wired to its callers; `wt-live-banner` typed `component`; nodes for `WorkoutSessionFinisher`
  and `QuickSessionPagerViews`.

## Output

- `RacketRecapReach.swift` (new), `SessionRecap.swift`, `SessionDetailView.swift`, `SessionSetEditing.swift`,
  `RacketVideoSeed.swift`.
- `SnappetTests/RacketRecapReachTests.swift` (new).
- `SnappetUITests/RacketMixedSessionUITests.swift` (new).
- `docs/knowledge-graph/data.js`, `pdd/context/decisions.md`, `pdd/context/project.md`.

## Acceptance criteria

- [ ] A finished session with a match and strength (or timed) work shows the racket card on the detail; Your videos,
      Keep rallies (when the plan allows) and Edit match open; the game heart-rate sheet opens from the card when the
      session has HR.
- [ ] Racket dominant: one racket card, as before. No racket entity: no racket card.
- [ ] The Finish summary shows the racket card after the dominant cards on a mixed session.
- [ ] Removing the only exercise offers "Delete session" / Cancel; Delete removes the session from History through
      `SessionCascade` and leaves the detail; Cancel keeps it. Removing one of several is unchanged.
- [ ] Existing accessibility ids and UI tests unchanged; SnappetTests 0 failures.
- [ ] App changes type-check against the iOS 18 SDK (Swift 6). No `HighlightEngine` change.

## Constraints

- Don't replace the dominant discipline's cards; don't show the racket card twice.
- Don't change existing seeds' behaviour; generated test data only, no footage.

## Test plan

1. `RacketRecapReachTests` (pure): dominant × racket presence, Kind × racket presence, `isLastExercise`.
2. UI: `RacketMixedSessionUITests` — strength and timed mixed sessions open Your videos and Edit match from the detail;
   removing the last exercise deletes the session (and Cancel keeps it).
3. Existing: `RacketEditMatchUITests`, `RacketVideosUITests`, `RacketGameHRUITests`, `RacketSportsUITests`,
   `SessionInsightsUITests`, and other detail / recap suites.
