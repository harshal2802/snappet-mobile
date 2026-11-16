# Prompt: Racket recording core — per-match / per-drill recording, record everything, interruptions (prompt 244)

**File**: pdd/prompts/features/racket-sports/244-ios-racket-recording-core.md
**Created**: 2026-11-06
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: GitHub issue [#438](https://github.com/harshal2802/snappet-mobile/issues/438) → step 1 of 6 ("Recording core"); follows prompt 203 (`203-ios-racket-sports.md`)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Wireframes (user-approved, five review rounds)**: canvas A (TT / badminton / tennis) and B (pickleball / padel / squash),
linked from #438. Boards for this step: `TtSetupFirst` / `PracticeSetup`, `TtStorage`, `TtRecordAll`, `DrillCountdown`
(`BlockStart`), `TtBlockAll`, `TtRestEverything`, `DrillRest*`, `TtInterrupted`, `TtInterruptedStop`, `StillPlaying`,
`*Settings` ("Recording defaults"). Fifth UX review fixes applied here: H1, M1, M3, M4 (M2 partly — see Output).

## Goal

A player wants useful video back from a match or a drill. Prompt 203 films one game at a time ("Record = film the
game"). Step 1 lays the recording core everything later builds on: choose per match / per drill how it's filmed,
check storage before recording everything, record a whole match or a whole drill (rests included) as one recording
saved to Photos, mark drill blocks and rests from the timers as time ranges on that recording, survive interruptions,
and stop a forgotten recording with "Still playing?". Splitting, the players, Watch and models are later steps.

Product decisions (settled in #438, do not reopen): the recording choice is per match / drill, never on the session
hub; recordings live in the Photos library; splitting is non-destructive (time ranges on the original); auto-start,
rest and Still-playing timers are configurable in Settings; one accent (#8EA2FF), green / amber / red only for
meaning, timer phase in word and ring (work accent, rest grey, done green), light numerals, sentence case, Stop as a
red outline, no truncation.

## Context the implementer needs

- Racket entities are `SessionExercise`s with the `.racket` discipline (`RacketSports.swift`); the pager host
  `FreeformPlayerView` owns every sheet / cover and mutation; `RacketViews.swift` holds the setup sheet and heroes.
- The in-app camera (`CameraController` / `SnappetCameraView`) films one clip and saves it with
  `MediaLibraryService.saveRecording`; clips attach to an exercise via `attachRecordedClips` and a newly logged set
  claims pending clips (`claimFilmedClips`).
- `SessionDetailView` also builds `RacketSetupSheet` (edit match); any closure-signature change must follow there, or the
  type-checker reports a misleading "unable to type-check in reasonable time".

## Approach

- **Pure core** `Features/WorkoutTracker/RacketRecording.swift` (Foundation only): `RacketRecordingMode` with per-mode
  labels/helpers, `RacketRecordingDefaults` (tolerant JSON in `@AppStorage`), `RacketDrillPlan`, `RacketStorageCheck`,
  `RacketRecordingLog`, `RacketInterruption` (+ pure mapping of AVFoundation reason / error codes),
  `RacketRecordingRoutes` (End routing + labels, H1), `RacketStillPlaying` (copy with the configured minutes, M4),
  `RacketTimerDisplay`, and `RacketRecordingMachine` — every event takes `now` and returns effects
  (`startCapture`, `stopCapture`, `logBlock`, `askStillPlaying`, `ended(route)`, `continueWithoutVideo`).
- **Platform edge** `Services/RacketRecorder.swift`: AVCaptureSession + movie output with 10-minute parts saved to
  Photos as each closes; interruption / thermal / background signals reported, no decisions.
- **Screens** `Features/WorkoutTracker/RacketRecordingViews.swift`: recording choice rows, storage sheet, recording
  cover (RecordAll; BlockStart → BlockAll → RestEverything → review; Interrupted / InterruptedStop; Still playing?),
  timer ring, Settings → Racket recording.
- **Model (additive Optionals)**: `SessionExercise.racketRecordingRaw`, `drillBlockSec`, `drillAutoStart`,
  `drillCountdownSec`, `racketRecordingLog`. Block count reuses `plannedSets`, rest reuses `targetRestSeconds`.
- **Wiring**: match form gets a Recording section; picking a drill now goes to a plan step (blocks × length,
  recording, rest, auto-start, countdown); the exercise page swaps the record button for "Record everything" (or a
  "not filming" note) when the mode isn't by unit; Settings → Workout → Racket sports → Racket recording.

## Output

- New: `RacketRecording.swift`, `RacketRecordingViews.swift`, `Services/RacketRecorder.swift`,
  `SnappetTests/RacketRecordingTests.swift`, `SnappetUITests/RacketRecordingUITests.swift`.
- Changed: `RacketViews.swift` (setup: recording + drill plan step), `FreeformPlayerView.swift` (storage sheet,
  recording cover, part attach, log persist, timer-logged blocks, parts never claimed by one block),
  `WorkoutModels.swift`, `QuickSessionPager.swift` (no pager rest for a drill recording everything),
  `WorkoutSettingsView.swift`, `SessionDetailView.swift` (closure arity), `RacketSportsUITests.swift` (plan step).
- Docs: `docs/knowledge-graph/data.js`, `pdd/context/decisions.md`, `pdd/context/project.md`.
- Review fixes: H1 (End routed by mode; "Keep scoring without video" match-only; header by mode), M1 (drill option
  "Everything, rests included", no split copy for drills), M3 (block-1 countdown copy; Wait → back to the camera),
  M4 (Still playing? quotes the configured threshold everywhere). M2: the drill review says "1 recording · N block
  parts" and that a drill never offers to delete its original.

## Acceptance criteria

- [x] Recording mode chosen per match (match form) and per drill (plan step); defaults from Settings; the hub has none.
- [x] Settings → Racket recording: mode per match / drill, quality, rest, auto-start, countdown, Still playing? per mode.
- [x] Storage check before recording everything; Continue disabled when there's under 15 minutes of room.
- [x] Match: recording starts at once, marks (moment / new game), Stop and split → saved placeholder (split = step 3).
- [x] Drill: camera → countdown → block (ring) → rest (pause, +30 s, +1 min, skip, auto-start) → review; blocks are
      logged from the timers; block / rest marks are time ranges on one recording.
- [x] Interruptions: call / app left / camera busy → resume as a new part; storage full / too hot → stop; End by mode.
- [x] Still playing? after the configured minutes; Keep asks again after the same time; no answer stops in 2:00.
- [x] Pure logic unit-tested in `RacketRecordingTests` (no device); UI: `RacketRecordingUITests` with the fake camera.
- [x] No platform imports in `HighlightEngine`; AVFoundation / Photos only in `Services/RacketRecorder.swift`.
- [ ] Device legs (owed): a real 1 h+ match recorded at 1080p (parts land in Photos every 10 minutes, the gap between
      parts), a phone call mid-recording, app backgrounded, storage-full and thermal stops; 4K storage estimate vs reality.

## Follow-ups (2026-11-06, user answers + "the wireframes are the source of truth")

- [x] **Best storage estimate.** `RacketBitrate` derives bytes/s from the capture config the recorder actually set
      (resolution, fps, HEVC vs H.264 — Apple's per-minute sizes + AAC); a modest margin (500 MB or 2 % of free).
      While recording, `RacketWriteRateMeter` smooths the measured bytes written (`recordedFileSize` + finished parts)
      and "Space left" switches to it after 20 s. Pure, tested (`testBitrate…`, `testWriteRateMeter…`).
- [x] **One-tap drill start.** The plan step opens on the plan used last time for that drill (same sport + name,
      from history — "Same as last time"), else the Settings defaults ("Suggested plan"); the start button is at the
      top. Racket drills aren't routine rows (prompt 203), so "remembered in a routine" is remembered per drill from
      history instead — no new store. `RacketDrillPlanMemory`, tested.
- [x] **Scores after Stop and split.** The saved screen lists the recorded games (one per "New game starts" + 1,
      capped by the format; adjustable), each with Enter score or Later. Later (and Done with games left) logs the
      game as "Score unconfirmed": it counts for neither side and shows the same everywhere (chips, ledger, recap,
      session detail, game HR sheet — review5 M5); tapping it confirms. `SetLog.scoreUnconfirmed`, `RacketScoreState`.
- [x] **Aligned with the boards** (no user decision overrode them): setup with "everything" goes straight to the
      storage check (PracticeSetup / Warmup → Storage) and the drill button reads "Set up camera"; TtStorage copy
      ("for this match or drill", "A match starts recording now. A drill checks the camera first.", "· tracking still
      works" on 1080p); RecordAll header "Match, everything"; BlockAll has End block only (Finish drill is on the rest
      screen); DrillCountdown header "Starting soon" for every block and, before a later block, Wait returns to a
      paused rest timer; DrillRest auto-start-off copy; TtInterrupted resume copy; Settings "Still playing check" /
      "Game by game".

## Device feedback round 1 (2026-11-11, user testing on an iPhone)

**Problem.** Recording everything showed no camera view (the screen opened on a black numbers view), so the shot
couldn't be framed. **Changes** (decisions.md, "Racket device feedback round 1"):

- [x] The recording screen opens on **Camera**: the live `AVCaptureVideoPreviewLayer` from `RacketRecorder`'s own session
      (no second session), letterboxed and portrait, with compact numbers and controls under it (CameraView boards).
- [x] The boards' **Dim · Camera · Stats** row at the bottom (replaces the top Dim / Camera segmented control): Dim =
      TtRecordAll on black (no preview layer); Stats = LiveStatsOff (Your tags, game / session time, points played,
      how rallies ended, "From your tags, N of M", "Rally and shot stats appear after the match"). Drills: Stats adds
      Blocks done / Recorded under the timer.
- [x] TtRecordAll layout: top row "● Recording · Match, everything · Saved N min ago"; the big number is the current game's
      points from the Watch ("Score from Watch"), else the match so far ("Games"); Marks / Space left as centred stats;
      Mark this moment and New game starts side by side; switcher; Stop and split.
- [x] The drill camera step before block 1 always shows the preview (no switcher there).
- [x] Parts record level with the horizon (`RotationCoordinator`), so a phone propped in landscape records landscape.
- [x] Pure + tested: `RacketRecordingShow`, `RacketRecordStats` (`RacketVideoScrub.swift`, `RacketVideoScrubTests`);
      `RacketRecordingUITests` switch the three views on the stand-in camera ("Camera preview shows here on a device").
- Differences from the boards: opens on Camera (boards: Dim) by user request; "Games" caption until the Watch has a
  point; no Heart rate tile on Stats (no live HR source on this screen yet); Stop still asks "Stop recording?" first
  (audit L6, undecided); Pause during a block stays deferred.
- [ ] Device: frame a table in landscape on the preview, record > 10 min, check the Photos parts are upright.

## Out of scope (later steps of #438)

Watch surfaces and phone ↔ watch messages (step 2), the split flow / players / tagging / "Your videos" (step 3), AI round
trip (4), models and live tracking (5, 6), the camera check (`CameraCheck`), warmup and "who serves", live rally stats,
Pause during a block, "movement on camera or Watch" as Still-playing activity (only taps count for now).

## Test plan

1. `cd ios/App && xcodegen generate && xcodebuild test -scheme Snappet -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`.
2. `cd ios/HighlightEngine && swift test` (untouched, must stay green).
3. Device: record a drill everything (3 × 1:00, rest 0:30), take a call in block 2, resume, finish → Photos has the
   parts, the drill page says "1 recording · 3 block parts"; record a match everything for > 10 minutes and check two
   parts land in Photos.
