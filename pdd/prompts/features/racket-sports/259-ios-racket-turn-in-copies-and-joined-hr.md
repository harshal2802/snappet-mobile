# Prompt: Racket — the turn reaches shared and saved copies; a joined game's heart rate (prompt 259)

**File**: pdd/prompts/features/racket-sports/259-ios-racket-turn-in-copies-and-joined-hr.md
**Created**: 2026-11-15
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: follow-ups left open by prompt 257 (Rotate is playback only) and prompt 258 (a joined game's heart-rate window
includes its timeout). Stacked on `claude/racket-split-timeout`.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md` (no new fields; `quarterTurns` is now relative to the videos the recording
plays from)

## Goal

Two fixes. (1) Prompt 257's Rotate (`RacketRecordingLog.quarterTurns`) turns the picture on screen only, so a recording
stored sideways still comes out sideways when shared, when "Delete the long original" / "Keep rallies only" make new
Photos videos, when a clip or frames go to another AI app, and in thumbnails. Every copy must be upright in any player,
with the look and labels upright on the turned picture, and a derived video must not be turned a second time.
(2) A game joined across timeouts (prompt 258) has its heart-rate window as `completedAt − played time … completedAt`,
which starts about one timeout late and takes the timeout in. Use the game's real stretches, show the timeout shaded,
and leave it out of the numbers.

## Context the implementer needs

- `RacketVideoLibrary.assemble` builds every playback / export composition (one track per orientation; a video
  composition fits mixed orientations). `export` passes through on the simulator and re-encodes on a device (look /
  labels Core Image composition, Analyzed captions via the properties composition, or a plain re-encode).
- Callers: `RacketShareSheet` (share variants), `RacketPlayerViews` Analyzed share / save, `RacketAIViews` (clip or JPEG
  frames), `RacketDeleteOriginalSheet` / `RacketKeepRalliesSheet` (derived videos), filmstrips (`thumbnails`) in the Watch
  player, Edit and the split review, Edit's look presets, the camera's thumbnail (`poster`).
- `RacketStats.unitWindows` feeds per-game HR, the game sheet, HRV per set and set efforts. The split's parts are seconds
  on the recording; `log.startedAt` gives wall-clock time.

## Approach

1. **Pure maths beside `RacketVideoTurn`**: `transform(natural:preferred:turns:)` = stored transform, moved to the
   origin, then N clockwise quarter turns (`quarter(height:)`); `renderSize`; `point` (where an upright point lands).
   0 turns returns the stored transform unchanged.
2. **One mechanism for every export route**: `assemble(…, turns:)` gives each composition track the turned
   `preferredTransform`. Passthrough (simulator) and a plain re-encode keep it as the output track's transform (no
   re-render); the Core Image look / labels composition takes its render size and upright frames from it (labels are
   drawn on the turned picture); the captions composition gets the turned upright render size; mixed orientations fit
   each turned part into the turned render size. Nothing to turn ⇒ the exact old route (no re-encode added).
3. **Callers** pass `log.copyTurns`: share, Analyzed share / save, the AI clip, the AI frames (pixels redrawn turned: an
   app may ignore EXIF), derived videos. Thumbnails take the playback's turn (`RacketVideoLibrary.turned` redraws).
4. **Turned once**: derived videos are saved turned; when they replace the originals the log's turn is cleared in the
   same update (`RacketRecordingLog.playFromDerived()`), so the turn is always relative to the videos it plays from. An
   older recording (derived before this, turn kept) still turns — its derived videos weren't turned.
5. **Joined game's HR**: `RacketStats.joinedStretches(log, sessionStart)` — for each game group with a timeout in the
   applied split, first half's start → last half's end on the session timeline, timeouts as `UnitWindow.gaps`.
   `unitWindows` uses it; `unitHR` / `games` / `HRVReads.perSet` leave gaps out (readings and zone time).
   `GameHR.timeouts` / `playedSec`; the sheet shades each timeout labelled "Timeout" and shows played time with
   "1 timeout left out". No applied split / no timeout ⇒ today's window.

## Output

- `RacketVideoOrientation.swift` (maths, `copyTurns`, `playFromDerived`), `RacketVideoLibrary.swift` (turns through
  assemble / export / saveToPhotos / frames / thumbnails / poster; `turned`, `displayedSize`), callers listed above,
  `RacketStats.swift`, `HRVReads.swift`, `RacketGameHRSheet.swift`; seed `-uiTestRacketTurns N`.
- Tests: `RacketTurnCopyTests`, `RacketJoinedGameHRTests`; UI `RacketEditUITests.testShareTurnedRecording`.

## Acceptance criteria

- [x] Maths unit-tested for 0–3 turns on landscape, camera-portrait (landscape pixels + quarter turn) and upright-portrait
      sources; stills turn their pixels.
- [x] Export test on the bundled synthetic clips: for 0–3 turns the copy's displayed size and two markers (the table, the
      orange ball near a corner) land where upright says; 0 turns keeps the source transform; turn → derive → share is
      turned exactly once.
- [x] UI: a recording seeded with one turn shares "This rally" and "Whole game" at 960×540 from the 540×960 clip.
- [x] Joined game: window from the first half's start to the last half's end; averages, peak, zone time, HRV exclude the
      timeout; fallback for recordings without the split's times.
- [x] `decisions.md`, `project.md`, schema note, knowledge graph updated.

## Constraints

- No real footage (the bundled synthetic clips only); vision-only rally detection unchanged.
- The simulator only passes through: the re-encoded routes (look, labels, captions, Analyzed) compile only for a device
  and are verified there by the device build and the user's phone run.

## Test plan

1. `SnappetTests` on the simulator (new suites above).
2. UI suites alone with the app uninstalled first: RacketEdit, RacketVideos, RacketRallyVideo, RacketSplitTimeout,
   RacketPlayer, RacketGameHR.
3. `xcodebuild build-for-testing … -destination 'generic/platform=iOS'` (the device-only export branches).
4. On the phone (user): share a turned recording with the Warm look and labels; Delete the long original on it, then play
   and share again — upright once.
