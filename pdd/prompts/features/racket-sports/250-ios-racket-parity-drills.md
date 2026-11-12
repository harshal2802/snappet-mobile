# Prompt: Racket parity — drills (block by block, pause, rest, review, setup, customize, trend) (prompt 250)

**File**: pdd/prompts/features/racket-sports/250-ios-racket-parity-drills.md
**Created**: 2026-11-11
**Project type**: Native iOS feature (Swift / SwiftUI) + watchOS — code lands in this repo.
**Chain**: GitHub issue [#438](https://github.com/harshal2802/snappet-mobile/issues/438) → wireframe parity audit
(`racket-wireframes/audit/fixlist.md`) batches **D1** (block-by-block drill screens) and **D2** (drill setup, customize,
trend), plus the deferrals on the same screens the user now wants built: Pause during a block (Paused / DrillPaused and
the Watch block Pause), RestPaused, BlockAll's Pause, RestEverything "More options"; and V2.1 (DrillVideos "Watch the
longest rally" opens Analyzed). Follows prompts 203, 244–249.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Boards (source of truth, all six sports)**: Drills / DrillLibrary (+ SqSolo), Customize / DrillCustomize, Setup /
PracticeSetup, SetupFirst, Camera (CameraCheck → NoModelCamera), BlockStart / DrillCountdown, Block / DrillLive (live
tracking: layout with the tracking row disabled), BlockOff / DrillLiveOff, BlockAll, Paused / DrillPaused, Rest /
DrillRest, RestOff / DrillRestOff, RestPaused / DrillRestPaused, RestEverything, Review / PracticeReview, DrillTrend,
DrillVideos (entry points + "Watch the longest rally"), WatchBlock / WatchRest / WatchDrill.

## Goal

The default drill mode, "Block by block", had none of the boards' drill screens: the page showed prompt 203's stepper
hero ("Log block N", "Time this block") and the generic camera. Build the boards' drill flow end to end — setup with its
summary rows and Customize, a first-time variant, the camera check, the countdown, the block screen with Pause, rest with
logging and feel, the review with progress and drill videos — for all three recording modes and all six sports, with
the Watch mirroring it.

## Context the implementer needs

- `RacketRecordingMachine` (`RacketRecording.swift`) already runs a drill's countdown → block → rest for "record
  everything"; prompt 249 taught it game by game for matches (`pauseCapture` / `resumeCapture`). Block by block reuses
  the same machine: each block is its own run, so its own Photos part.
- `RacketRecordingCover` hosts record everything (match and drill); `RacketGameCover` (prompt 249) hosts game by game and
  owns the reusable pieces: `RacketShowSwitcher`, `RacketTrackingOffRow`, `RacketInterruptionPanel`,
  `RacketStillPlayingPanel`, the warm panel, `RacketWideButton`, `RacketStopButton`, `RacketChips`, `RacketBox`.
- Live tracking during play is not built (step 6). Boards that show it (Block "Shots now / Longest / Rallies", Rest
  "Suggested from video / Watch that rally", BlockAll "Shots now / Rallies") render as their tracking-off boards with the
  "Live tracking off · Turn on" row disabled.
- Shot tags are deferred (Shots), so "Tag shot types" on Review and the "Shot mix" chip on DrillTrend are hidden.

## Approach

- **Pure** `Features/WorkoutTracker/RacketDrillFlow.swift`: `RacketDrillDetails` (practising, focus hand + stroke,
  pattern, from / to zones, goal) with per-sport choices from the boards; `RacketDrillLibrary` (category chips, the
  catalog per sport in board order with categories, "Video helps" / "Timer"); `RacketDrillCopy` (block / paused / rest /
  countdown lines per mode and sport); `RacketDrillFeel` (Easy / About right / Hard); `RacketDrillReview` (headline,
  new best, per-block bars, rally-length buckets, setup tags); `RacketDrillTrend` (last 5 sessions, best, average,
  sessions, how it felt); `RacketDrillHistory` (first time, last time's best).
- **Machine** (additive): block-by-block drills record (`beginRun` on each block, the run closes when the block ends),
  Pause during a block (`.blockPaused`: the block timer stops, recording pauses in every mode, End block / Stop drill),
  `startingBlock` (absolute block indices), `setAutoStart` / `setRestSec` / `endAfterNextBlock` / `addBlock` (More
  options), `continueLog` for a block-by-block drill reopened mid-way.
- **Screens** `RacketDrillViews.swift`: `RacketDrillCover` for every drill mode (Camera check → BlockStart → Block /
  BlockOff / BlockAll ⇄ Paused → Rest / RestOff / RestEverything ⇄ RestPaused → … → Review), `RacketDrillReviewScreen`
  (also from the drill page), `RacketDrillTrendScreen` (Swift Charts bar chart, the repo's grow-on-appear BarMark
  pattern). The camera check view is shared with `RacketGameCover`.
- **Setup** (`RacketViews.swift`): the drill library on the board (title "<Sport> drill", + New, search, category chips,
  Recent / All drills, measure + New + Video helps / Timer), PracticeSetup (summary rows → Customize, Change all,
  recording chips, live tracking switch disabled, rest / countdown chips + Custom), SetupFirst (Choose › rows, the gate),
  SqSolo, and DrillCustomize (Cancel · Drill details · Save).
- **Model (additive Optionals)**: `SessionExercise.drillPractising`, `drillHand`, `drillStroke`, `drillPattern`,
  `drillFromZone`, `drillToZone`, `drillGoal`; `SetLog.drillFeelRaw`. Shared: `RacketWatchState.Block.pausedRemainingSec`.
- **Watch**: the block board gets Pause (→ Paused on the wrist with Resume); `pauseTimer` / `resumeTimer` pause and resume
  a block as well as a rest.
- **Videos**: `RacketVideosStart.drillVideos(id)` (Review → Drill videos); "Watch the longest rally" opens Analyzed.

## Output

- New: `RacketDrillFlow.swift`, `RacketDrillViews.swift`, `SnappetTests/RacketDrillFlowTests.swift`,
  `SnappetUITests/RacketDrillUITests.swift`.
- Changed: `RacketRecording.swift`, `RacketViews.swift`, `RacketMatchViews.swift` (shared camera check),
  `RacketRecordingViews.swift` (drills leave the record-everything cover), `RacketVideoViews.swift`,
  `RacketWatchBridge.swift`, `RacketSports.swift` (catalog), `WorkoutModels.swift`, `FreeformPlayerView.swift`,
  `Shared/RacketWatchMessage.swift`, `SnappetWatch/RacketWatchViews.swift`, existing racket UI / unit tests.
- Docs: `docs/knowledge-graph/data.js`, `pdd/context/decisions.md`.

## Acceptance criteria

- [x] Drill library: "<Sport> drill", + New, search, All / Recent / sport categories, Recent and All drills rows with the
      measure, "New" and "Video helps" / "Timer"; Squash "Solo rally" opens SqSolo.
- [x] Setup: Same as last time / Suggested plan + Change all; Practising › Focus › Pattern › Plan › Measure › Goal rows
      open Customize; recording chips; live tracking switch (off, disabled); rest and countdown chips + Custom; the start
      button at the top (user decision) reads "Set up camera" (or "Start drill" without video).
- [x] SetupFirst: "First time with this drill" copy; Choose › rows; start disabled with "Choose what you're practising and
      your focus first." until both are set.
- [x] Customize: practising, focus hand + stroke chips per sport, pattern + court diagram with From / To, Blocks / Each
      block steppers, measure chips, goal; Save writes the details back to the setup.
- [x] Set up camera → camera check → BlockStart → Block; Wait before block 1 returns to the camera, later Wait → paused rest.
- [x] Block by block: ● Recording · Block N of M · Phone OK; ring; recording line; goal panel; tracking row; switcher;
      Pause / End block. Each block is its own Photos part; nothing records during rest.
- [x] Paused (all modes): Ⅱ Recording paused; grey 0.55 ring "Paused · Block timer stopped"; Resume; Watch line; End block
      / Stop drill. Nothing is recorded or counted while paused.
- [x] Rest / RestOff: ring with "Block N starts by itself after this"; Pause rest / +30 s / +1 min; Skip rest; longest rally
      (or made / tried) stepper "You enter this"; Find rallies after the drill; Easy / About right / Hard; Auto-start;
      More options; Finish drill. RestPaused and RestEverything (+ More options) match their boards.
- [x] Review (every mode, and from the page): tags, longest rally headline with New best and last time, per-block bars,
      rallies panel, Done for now, See progress → DrillTrend, Drill videos → DrillVideos.
- [x] DrillTrend: last 5 sessions as a bar chart, best / average / sessions, how it felt, metric chips.
- [x] Watch: block Pause → paused block with Resume; rest and countdown unchanged.
- [x] Pure logic in `RacketDrillFlowTests` (+ machine cases in `RacketRecordingTests`); UI in `RacketDrillUITests`.

- [ ] Device: parts recorded with the phone turned between them play and export upright (needs a person to turn the
      phone; the maths is unit-tested).

Also in this prompt (device feedback rounds 2–3, same branch): one persistent preview per cover, the spurious-disappear
guard (frozen preview), the court guide fitted to the letterboxed picture, a never-rising "Space left", and per-part
orientation in the split player and exports.

## Constraints

- On-device only. `HighlightEngine` untouched. Model fields additive optionals only.
- Live tracking, court check, shot tags stay out (step 6 / other batches).

## Test plan

1. `cd ios/App && xcodegen generate`; build Snappet and SnappetWatch.
2. `SnappetTests` alone, serial; every racket UI suite separately; `cd ios/HighlightEngine && swift test`.
3. Device build + install; a TT drill block by block: two blocks, pause in block 1, rest logging, review → progress.
