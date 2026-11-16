# Prompt: The live session never loses work silently (prompt 263)

**File**: pdd/prompts/features/racket-sports/263-ios-workout-live-session-safety.md
**Created**: 2026-11-16
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: the Workout Tracker state-machine review (findings F1, F2, F3, F4, F5, F14), after prompt 260.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md` (no new field, no new raw value)

## Goal

A read-only review of the workout tracker's state machines found six ways the LIVE session loses or corrupts the
user's work without asking. The user's decisions are final; this prompt fixes all six in one PR, each as a pure,
unit-tested rule with a thin view on top:

- **F5** "Remove match / drill / exercise / climb" in the live player removes at once (no undo).
- **F2** Finish with no completed set discards the session, its media rows, studio project and racket recording log.
  The Finish intent / `snappet://finish` link does the same.
- **F4** The Finish intent / link while a recording, drill or game cover is open tears the cover down without ending
  the recording.
- **F3** Deleting a racket game from the history drawer leaves `baseSetIndex`, split part indexes and game marks stale.
- **F1** "Record everything again" (and switching a game-by-game match to everything, and "Continue drill" on a
  record-everything drill) replaces the existing recording log, losing its split, rallies, tags and scans.
- **F14** After an app kill a record-everything match page shows an ever-growing recorded time.

## Context the implementer needs

- `FreeformPlayerView` hosts every cover (`RacketRecordingCover`, `RacketDrillCover`, `RacketGameCover`) and the history
  drawer; `WorkoutHomeView` (`WorkoutTrackerModule.swift`) owns `finishWorkout` and `consumeFinishSession`.
- `RacketMatchEditor` (prompt 260) is the one place that renumbers a match's games consistently (`commit` writes
  `baseSetIndex`, applied split `setIndex`, `game` mark `index`; `remap` moves media).
- A record-everything recording saves Photos parts asynchronously; the cover's Stop routes to the split prompt (match),
  the review (drill) or the score sheet (game by game), each a user step.

## Approach

One pure file `LiveSessionSafety.swift` (no SwiftUI / UIKit / Photos):

| Rule | Function | Used by |
|---|---|---|
| Remove confirmation (F5) | `LiveRemoval.prompt(for:name:mediaCount:)` → nil (no sets, media or recording: remove at once) or title / button / message | player ⋯ menus |
| Finish (F2) | `LiveFinish.decide(exercises:completedSets:mediaCount:)` → summary / discard (nothing worth keeping) / ask(lost line) | Finish, intent / link |
| Intent / link (F2) | `LiveFinish.intentSaves` — never deletes something worth keeping; saves instead (no dialog from an intent) | `consumeFinishSession` |
| Finish while a cover is open (F4) | `LiveFinish.refusal(openCover:)` — refuse and keep the cover; the cover shows why | `consumeFinishSession`, `RacketLiveCovers` |
| Drawer delete (F3) | `RacketLiveDrawer.deleteBlock` (reason or nil) / `remove` (through `RacketMatchEditor` for matches; drills shift block / rest marks) | history drawer |
| Second recording (F1) | `RacketRecordingGuard` — `recordEverythingBlock`, `drillStart` (fresh / continue / blocked), `mayReplace` | match page, game cover, drill page + cover, `saveRacketRecordingLog` |
| Crash recovery (F14) | `RacketRecordingRecovery.recovered(_:)` — close open runs at the last saved part's end; record-everything logs get `endedAt` | player appear, skipping covers that are open |

`RacketRecordingMachine.continueLog` also continues a record-everything drill's log (same mode only).
`RacketLiveCovers` (MainActor, observable) records which racket cover is open, so the finish path can refuse and the
covers can show the reason.

### F4: refuse, not end from outside

Ending a recording from outside its cover would have to drive three different end flows (the split prompt, the drill
review, the game's score sheet, each a user step) and wait for the asynchronous Photos part saves, then finish while
the cover is gone. That can't be proved with a test on the simulator (the fake camera saves no parts). Refusing is:
the cover stays, the recording keeps going, an alert says what to do, and nothing is finished.

## Output

- `ios/App/Snappet/Features/WorkoutTracker/LiveSessionSafety.swift` (pure) and `RacketLiveCovers.swift` (the registry
  and the cover alert).
- Changes in `FreeformPlayerView.swift`, `WorkoutTrackerModule.swift`, `QuickSessionPagerViews.swift`,
  `RacketRecording.swift`, `RacketRecordingViews.swift`, `RacketDrillViews.swift`, `RacketMatchViews.swift`,
  `RacketVideoSeed.swift` (new launch arguments only).
- Unit: `SnappetTests/LiveSessionSafetyTests.swift`. UI: `SnappetUITests/LiveSessionSafetyUITests.swift`.

## Acceptance criteria

- [ ] Remove match / drill / exercise / climb asks (session detail's wording; a recorded match or drill says its split,
      rallies and tags go and its video stays in Photos); an empty exercise goes at once.
- [ ] Finish discards silently only with nothing worth keeping; otherwise Save session / Discard / Cancel with the
      lost line. The intent / link saves instead of deleting.
- [ ] The finish intent / link while a racket cover is open finishes nothing; the cover stays and says why.
- [ ] Drawer delete on a racket match keeps base, split links and game marks right (before and inside the recording);
      a game with video can't be swiped away and says why; drills shift their marks or keep blocks with video.
- [ ] A second recording on an entry with one is blocked with a reason (page, game cover); a record-everything drill
      continues its log (earlier block marks survive); `saveRacketRecordingLog` never replaces a recorded log.
- [ ] An open recording after a crash shows its saved time, not a growing one; a live recording is never touched.
- [ ] `decisions.md`, `project.md`, schema note, `docs/knowledge-graph/data.js` updated.

## Constraints

Simulator only; no real footage; wording plain, no em dashes in UI strings; existing ids and tests keep working.

## Test plan

1. `SnappetTests` (all), including `LiveSessionSafetyTests`.
2. `LiveSessionSafetyUITests` (`-uiTestRacketLive`, `-uiTestRacketLiveCrash` over the racket video seed; fresh store +
   fake camera for the finish link), plus the existing racket and Finish suites.
