# Prompt: Racket Watch scoring — start, score, mark, timers with rings, Still playing? on the wrist (prompt 245)

**File**: pdd/prompts/features/racket-sports/245-watchos-racket-watch-scoring.md
**Created**: 2026-11-06
**Project type**: Native watchOS + iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: GitHub issue [#438](https://github.com/harshal2802/snappet-mobile/issues/438) → step 2 of 6 ("Watch scoring");
builds on prompt 244 (step 1, recording core) and prompt 203 (racket sports)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Wireframes (user-approved, five review rounds)**: canvas A / B linked from #438. Boards for this step: `XxWatchStart`,
`Watch` / `XxWatch` (game-by-game scoring), `WatchBreak` / `XxWatchBreak`, `XxWatchMark`, `XxWatchBlock`,
`WatchDrill` / `XxWatchRest`, `WatchStillPlaying` / `XxWatchStill`; the phone's `TtInterrupted` / `TtInterruptedStop`
("Your Watch tells you it stopped"). Fifth-review items: "Watch timers have no ring" (Low) and M4 (the configured
Still-playing threshold everywhere, the Watch included).

## Goal

A player with a propped-up phone shouldn't have to walk over to it. Step 2 puts the match and the drill on the
Apple Watch: start from the wrist, tap who won each point (and undo), see the game / set state, mark a moment, a new
game or a break, run the drill's block and rest timers and the match's break timer with rings, answer "Still
playing?", and learn on the wrist when recording stopped (storage full, too hot, no answer). The phone stays the one
place the match lives: the Watch sends taps, the phone applies them and mirrors its state back.

Product decisions (settled in #438, do not reopen): one accent (#8EA2FF), green / amber / red only for meaning;
timer phase in the word and the ring (Work accent, Rest / Break / Interval grey, Paused grey at 0.55, Done green);
light numerals; sentence case; Stop as a red outline; no truncation. "Still playing?" counts taps only (step 1) —
Watch taps now count too.

## Context the implementer needs

- The phone is the only `WCSessionDelegate` (`AppleWatchMetricsSource`, created by `AppModel` at launch); the Watch's
  is `WatchConnectivityLink`. Messages are property-list dictionaries discriminated by a key (`LiveWorkoutMessage`
  uses `kind`, household uses `householdKind`). Household already owns `updateApplicationContext` (one dictionary per
  app), so racket state must not use application context.
- Step 1's `RacketRecordingMachine` lives in `RacketRecordingCover` (record everything only). Game-by-game matches
  (prompt 203) live on the pager's match page: `racketTimers[ex.id]` times the unit and `RacketScoreSheet` logs it.
- `RacketTimerTone` / `RacketTimerDisplay` / `RacketClock` are pure; the Watch needs them too.
- The Watch target has no unit-test target: anything to test goes in `Shared/` and is pinned in `SnappetTests`.

## Approach

- **Shared, pure (`ios/App/Shared/`)**:
  - `RacketTimerDisplay.swift`: `RacketTimerTone`, `RacketTimerDisplay`, `RacketClock` moved here from
    `RacketRecording.swift` (one source for phone and wrist rings).
  - `RacketLiveScore.swift`: point-by-point tally from a point history (undo = pop): rally games (to N, win by 2,
    badminton's cap) and tennis / padel sets (15–30–40–Ad games, a 7-point tiebreak at N–N, a super tiebreak to 10).
    Display, header, unit result.
  - `RacketWatchMessage.swift`: `RacketWatchState` (phone → Watch snapshot with a revision: sport, side labels,
    surface — start · scoring · marks · countdown · block · rest · break · ended — plus Still playing? and a stopped
    notice), `RacketWatchCommand` (Watch → phone), the envelope (`racketKind` key + JSON data), the ring mapping per
    surface, the Watch's optimistic score apply, and the haptic cue between two states.
- **Phone**: `Services/RacketWatchRelay.swift` (send with `sendMessage`, else `transferUserInfo`; a revision; one
  attached session; command de-dupe), fed by `AppleWatchMetricsSource`. Pure mappers in
  `Features/WorkoutTracker/RacketWatchBridge.swift`: cover state → `RacketWatchState`, Watch command → machine events,
  and `RacketWatchMatch` (game-by-game: ready → scoring → break → next game; End game logs the unit "from Watch").
  `RacketRecordingCover` publishes and handles commands (every Watch tap is activity); `FreeformPlayerView` hosts the
  game-by-game Watch match on the current match page.
- **Model (additive Optionals)**: `SetLog.scoreFromWatch` (a unit tallied on the Watch, not yet confirmed — counts,
  reads "from Watch"); `RacketScoreState.fromWatch`; recording mark `breakStart`.
- **Watch**: `SnappetWatch/RacketWatchModel.swift` (state, optimistic taps, haptics) and `RacketWatchViews.swift`
  (Start, Score, Marks, Block, Rest, Break, Still playing?, Stopped); `WatchWorkoutView` shows them first.

## Output

- New: `Shared/RacketTimerDisplay.swift`, `Shared/RacketLiveScore.swift`, `Shared/RacketWatchMessage.swift`,
  `Snappet/Services/RacketWatchRelay.swift`, `Snappet/Features/WorkoutTracker/RacketWatchBridge.swift`,
  `SnappetWatch/RacketWatchModel.swift`, `SnappetWatch/RacketWatchViews.swift`, `SnappetTests/RacketWatchTests.swift`.
- Changed: `RacketRecording.swift` (moved types, `breakStart` mark, still-playing timeout flag), `RacketRecordingViews.swift`
  (publish + commands, Watch score line, "from Watch" rows), `FreeformPlayerView.swift` (game-by-game Watch match),
  `RacketSports.swift` / `RacketViews.swift` / `WorkoutModels.swift` (from-Watch state), `AppleWatchMetricsSource.swift`,
  `WatchConnectivityLink.swift`, `WorkoutWatchManager.swift`, `WatchWorkoutView.swift`.
- Docs: `docs/knowledge-graph/data.js`, `pdd/context/decisions.md`, `pdd/context/project.md`.

## Acceptance criteria

- [x] Watch start: a drill waiting on the camera shows "Start block 1?" (Start / Not yet); a game-by-game match shows
      "Start game N?" / "Start set N?".
- [x] Game by game: +1 per side, Undo, the game / set state ("Set 1 · Games 4–3", "40 – 30"), End game logs the unit
      as "from Watch" (counts, confirm later), then a break ring (Pause, +30 s, Skip break); Hold to end match.
- [x] Record everything, match: Mark, New game, Break starts, +1 per side (a finished game logs "from Watch" and marks a
      new game), Stop and split.
- [x] Drill: countdown, block ring (End block, Stop drill), rest ring (Pause / Resume, +30 s, +1 min, Skip rest,
      Finish), auto-start shown.
- [x] Rings: Work accent, Rest / Break grey, Paused grey 0.55, Done green; light numerals.
- [x] Still playing? on the wrist with the configured threshold (M4) and the 2:00 answer window; Keep / Stop.
- [x] Stopped notice for storage full, too hot and the Still-playing timeout (and resumable stops say "Resume on the phone").
- [x] Watch taps count as activity for Still playing?.
- [x] Shared value types compile into every target; pure logic tested in `RacketWatchTests` (encode / decode, scoring,
      undo, ring phases, command mapping, optimistic apply, cues).
- [x] No platform imports in `HighlightEngine`; Watch build green; `SnappetTests` + UI tests green.
- [ ] Device legs (owed): a real iPhone + Apple Watch session (below).

## Where this differs from the boards (no user decision overrode them; recorded in decisions.md)

- Pickleball scores every rally ("+1"), not side-out with a server number ("4–2–1", "We won / They won").
- The block board has no Pause (pause during a block is still deferred from step 1).
- The marks board adds Undo once there's a point (a mis-tap needs a fix; the boards only have Undo on scoring).
- "Still playing?" on the wrist says "No taps or marks for N min", not "No movement" (movement isn't sensed yet).
- Game-by-game "Start game N?" doesn't say "Camera ready": the per-game camera can't be started from the wrist, so it
  starts the game clock and scoring; "Camera ready" shows for a drill waiting on the recording screen's camera.
- The table tennis note reads "Tap who won each point." (the board's "also tags the winner of the last rally" needs
  rally tagging, step 3+); serve indicators ("You're serving") aren't shown.
- A break ending goes straight into the next game's scoring (no separate Watch countdown board).

## Out of scope (later steps of #438, or noted in decisions)

Pause during a drill block (step 1 deferred it; the Watch's Pause on a block is left out), pickleball side-out scoring and
serve tracking, tennis no-ad, rally tagging from a score tap, a phone break screen (`GameBreak`) and the phone-side
countdown before the next game, movement as Still-playing activity, the split flow (step 3).

## Test plan

1. `cd ios/App && xcodegen generate`; build `SnappetWatch` for the watchOS simulator.
2. `xcodebuild test -scheme Snappet -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:SnappetTests
   -parallel-testing-enabled NO`, then the UI bundle separately.
3. `cd ios/HighlightEngine && swift test` (untouched).
4. Device: pair a Watch; game-by-game TT match: Start on the wrist, score to 11–9, Undo once, End game → break ring →
   next game; phone shows "G1 11–9 from Watch". Record a drill everything: start block 1 from the wrist, end block,
   +30 s and skip rest from the wrist. Record a match everything with Still playing? at 30: stay idle → the wrist asks;
   no answer → the wrist says it stopped.
