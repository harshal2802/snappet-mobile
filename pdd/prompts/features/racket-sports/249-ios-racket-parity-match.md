# Prompt: Racket parity — match recording and setup (game by game, score only, breaks) (prompt 249)

**File**: pdd/prompts/features/racket-sports/249-ios-racket-parity-match.md
**Created**: 2026-11-11
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: GitHub issue [#438](https://github.com/harshal2802/snappet-mobile/issues/438) → wireframe parity audit
(`racket-wireframes/audit/fixlist.md`) batches **R1** (game-by-game match recording screens) and **R2** (match setup and
start), plus the deferrals on the same screens the user now wants built; follows prompts 203 and 244–248.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Boards (source of truth, all six sports)**: Match / XxMatch, Warmup, Camera (CameraCheck), NoModelCamera,
Countdown (GameCountdown), DimOff (PlayingNoTrack), CameraViewOff, StatsOff (LiveStatsOff), Dim / CameraView / Stats
(live tracking: layout with the tracking row disabled), Warm (PhoneWarm), Paused (break / interval paused), Still
(StillPlaying), Interrupted / InterruptedStop, Score (SaveGame), Break (GameBreak), ScoreOnly, BdInterval, TnTiebreak,
PdDeuce, SessionHub, SessionRecap, Storage, RecordAll.

## Goal

The user tested the racket build on a phone and found the default mode, "Game by game", had none of the boards' match
screens: it filmed through the generic camera, with no score, no Still playing?, no interruption handling, no break
or countdown, and the match form had one "Start match" instead of the boards' "Set up camera" / "Play without video".
Build the boards' match flow end to end so every element, its order, copy and arrow match, for all six sports.

## Context the implementer needs

- `RacketRecordingMachine` (`RacketRecording.swift`) records only `.everything`; it owns runs, parts, interruptions and
  Still playing?. `RacketRecordingCover` is the record-everything screen (Dim · Camera · Stats landed in device round 1).
- The match page (`FreeformPlayerView`) showed `RecordClipButton` for game by game; `RacketWatchMatch` drives the Watch
  for a game-by-game match on the page.
- `RacketLiveScore` (Shared) is the Watch's tally; the phone and the Watch must share it.
- Prompt 203 put "point-by-point scoring" out of v1 scope. The ScoreOnly board supersedes that (user, this batch).
- Live tracking during play is not built (step 6); where a board shows it, the "Live tracking off · Turn on" row stays
  with the board's copy and Turn on disabled.

## Approach

- **Pure** `Features/WorkoutTracker/RacketMatchFlow.swift`: `RacketGameFlow` (warmup → playing → interval → scoring →
  break / paused / done → countdown → playing … → ended) returning effects (`resumeCapture`, `pauseCapture`, `openScore`,
  `matchOver`); `RacketServe` (who serves, per sport); `RacketThermalLevel`; `RacketGameCopy` (per-sport board copy);
  `RacketGameByGameSplit` (the applied split Your videos reads); `RacketMatchFormChoices`; `RacketRecapLine`.
- **Machine** (additive): `recording: .byUnit` records a match (each game its own run → its own Photos part);
  `pauseCapture` / `resumeCapture` (between games, not an interruption), `openGame` / `closeGame` and
  `openInterval` / `closeInterval` ranges (`MarkKind.game`, `.interval`), `continueLog` (a later game adds to the same
  log), `RacketRecordingLog.modeRaw`.
- **Screens** `RacketMatchViews.swift`: `RacketGameCover` (Camera check → Warmup → game screen; ScoreOnly), the
  `RacketSaveGameSheet`, and shared panels (interruption, Still playing?, StatsOff, switcher, tracking row) that the
  record-everything screen now uses too.
- **Setup**: the match form rebuilt on the board (live header, format chips, players, film, Apple Watch ready, Set up
  camera / Play without video, What works); padel gets the PdDeuce step (At 40–40, Final set, Players) first.
- **Shared / model (additive Optionals)**: `RacketLiveRules.goldenPoint`, `RacketWatchState.Countdown.title`,
  `SessionExercise.racketGoldenPoint`, `racketFirstServerRaw`, `RacketFormat.goldenPoint` + `cap` (badminton 15 → 21).
- **Edge**: `RacketRecorder.onThermal` (serious ⇒ warm, back to fair ⇒ ok; critical still stops).

## Output

- New: `RacketMatchFlow.swift`, `RacketMatchViews.swift`, `SnappetTests/RacketMatchFlowTests.swift`,
  `SnappetUITests/RacketMatchUITests.swift`.
- Changed: `RacketRecording.swift`, `RacketRecordingViews.swift` (Warm, no Stop confirm on RecordAll, storage bar +
  Back, shared panels, Stats heart rate), `RacketViews.swift` (match form, PdDeuce step, recap reel + time line),
  `RacketSports.swift` (cap, golden point, Games to 15), `RacketWatchBridge.swift` (`gameCoverState`, `gameAction`),
  `RacketModelViews.swift` (Capabilities without the preview from the form), `FreeformPlayerView.swift` (the cover,
  page controls in every mode, hub Your videos + footnote), `SessionRecap.swift`, `FreeformDoneSummaryView.swift`,
  `WorkoutModels.swift`, `Services/RacketRecorder.swift`, `Services/RacketWatchRelay.swift` (token detach),
  `Shared/RacketLiveScore.swift`, `Shared/RacketWatchMessage.swift`, `RacketSportsUITests` / `RacketRecordingUITests`.
- Docs: `docs/knowledge-graph/data.js`, `pdd/context/decisions.md`.

## Acceptance criteria

- [x] Match form: live header, format chips per sport (tennis Sets + Options), players chips + opponent, Film this match,
      Apple Watch ready (when paired), Set up camera / Play without video (Save when editing), What works for <sport>.
- [x] Padel: Match setup (At 40–40 Advantage / Golden point, Final set, Players) → Match; golden point decides a 40–40
      game in the tally.
- [x] Set up camera → Camera check (NoModelCamera) → Warmup (choice, tracking off, who serves, during play show, Start
      recording); "Everything, split later" → Storage (Back) → RecordAll.
- [x] Game screen: ● Recording · Game N · Phone OK / ▲ Warm; DimOff / CameraViewOff / StatsOff; tracking row disabled;
      Next game / Stop (red outline) → Score; Still playing? at the game-by-game threshold; interruptions resume as a
      new part, InterruptedStop → Keep scoring without video → ScoreOnly.
- [x] Score: Cancel · Game N · Later; per-sport subtitle; auto-start, break chips (TT 0:30), pause recording;
      Save, start break / Save, match over; "Auto-start stops once the score decides the match."
- [x] Break (pause / +30 s / +1 min / skip / auto-start / End match) → Countdown (Wait → paused break, +30 s) → next game.
- [x] BdInterval at 11 (8 to 15) with "Pause recording during intervals"; TnTiebreak banner (tennis and padel).
- [x] ScoreOnly: You +1 / Alex +1 / Undo / End game / Start recording instead (keeps the tally); the Watch shares it.
- [x] Match over with video → Your videos (the games are already split); hub Your videos + footnote; recap time line
      and Make a reel; RecordAll Stop goes straight to the split prompt.
- [x] Pure logic in `RacketMatchFlowTests`; UI in `RacketMatchUITests` (fake camera).
- [ ] Device: a real game-by-game match (parts per game in Photos, break paused / recorded), a serious-heat Warm.

## Constraints

- On-device only. `HighlightEngine` untouched. Model fields additive optionals only.
- Live tracking, court check, side-out scoring, no-ad and serve tracking stay out (other batches / steps).

## Test plan

1. `cd ios/App && xcodegen generate`; build Snappet and SnappetWatch.
2. `SnappetTests` alone, serial; every racket UI suite separately; `cd ios/HighlightEngine && swift test`.
3. Device build + install; record a TT match game by game: two games, a recorded break, Stop → Your videos.
