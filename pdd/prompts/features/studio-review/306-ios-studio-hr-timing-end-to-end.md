# Prompt: Heart-rate timing on a baked clip, checked end to end in the editor

**File**: pdd/prompts/features/studio-review/306-ios-studio-hr-timing-end-to-end.md
**Created**: 2026-11-26
**Project type**: iOS
**Chain**: follows prompt 305; part of P0's verification in `PLAN.md`. Built on `studio-v2`.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Problem

Prompt 305 made a baked clip keep its heart-rate timing (`SessionMedia.bakeTimeMapData`,
`BakedTimeMap`, `ClipCaptureClock`), added the "checking" phase before a save or an export, and a
stop message for a clip reverted in Photos. All of it was proven by unit tests with stand-ins: a
stand-in player, a stand-in render, a stand-in Photos probe. Nothing had opened a baked clip in
the running app, moved the playhead, read the tile and exported.

The simulator could not do it. Its sessions carry made-up Photos identifiers, so the Studio there
had no preview ("Preview renders on a device") and Export stayed off.

## Change

No behaviour of the app changes for a user. Everything added is DEBUG only and does nothing on a
launch without the new argument.

### A seed: `-uiTestSeedStudioHRTiming` (`StudioHRTimingSeed`)

It implies the fresh in-memory store, like the other seeds, and is wired in the same places
(`SnappetApp`, `UITestStore`, `TestStoreGuard`). It seeds one completed workout session:

- heart rate is the ramp `bpm = 60 + seconds / 2`, one sample a second for 300 s. A reading
  names the second it came from: 20 s too early is 10 bpm too low;
- three video rows that all play one generated 10 s video:

| Clip | Row | Capture time of rendition time `t` |
|---|---|---|
| A | never baked, offset 60 s | 60 + t |
| B | "Save to original" of a 30 s recording with its first 20 s trimmed off, offset 200 s | 200 + 20 + t |
| C | "Save to original" at 2× of a 20 s recording, offset 120 s | 120 + 2t |

The baked rows are made the way `StudioEditorViewModel.bake` makes them: the row of the recording
first, then `ClipBakePlan.timeMap` for the part the bake would have rendered (trim start 20; speed
2) and `ClipBakePlan.revertibleMediaUpdate` for the row's values. No hand-written JSON.

### A video the simulator can open

The seeded identifiers have the form `uitest-generated://studio-hr-timing/<clip>`.
`StudioComposer.avAsset` asks the seed first (DEBUG only); the seed answers only that form, with
the 1 s golden fixture of prompt 304 (`StudioGoldenSource.portraitA`, drawn in code) played ten
times. The file is written once, on first use, off the main thread. With it the Studio on the
simulator has a real preview player and a real export for these clips. (`StudioGoldenRenderer.looped`
is no longer private.)

### What the test reads (`StudioHRTimingDebug`, `StudioHRTimingDebugView`)

On a launch with the seed argument the Studio carries six invisible accessibility elements:

- `studioDebug.playhead`, `studioDebug.total`: the playhead and the timeline length, to the
  millisecond (the timecode on screen shows whole seconds);
- `studioDebug.previewBPM`: the bpm of the preview tile at the playhead, before rounding. It is
  computed from the same `previewTile` values and fraction the tile is drawn from;
- `studioDebug.phase`, `studioDebug.export`: the editor's phase and the export's state;
- `studioDebug.report`: JSON with the `PlacedClipHR` list the last export was given (recorded in
  `StudioComposer.assemble`, where the export makes it), every answer of the app's own Photos
  probe, and every finished check (rows asked about, answered or not, rows found reverted,
  seconds).

No identifier was added to the tile. Its texts already reach the test (they carry the preview's
identifier, `studioPreview`); the test takes the text before the "BPM" unit and requires it to
be `previewBPM` rounded.

## Tests

`StudioHRTimingUITests` (new, one test, one launch, about 3 minutes on the simulator). For each
clip it opens "Edit this clip" from the session's media, as the walkthrough does. In clip A's
editor it switches the heart-rate tile on through the HR tool (the session has one project, so
clips B and C then show the same tile). It reads at the start and after two timeline drags of
200 points (4 s each).

Read on the simulator, 2026-11-26 (tile number, exact bpm, expected):

| Clip | t = 0 s | t = 4 s | t = 8 s | Expected capture time |
|---|---|---|---|---|
| A | 90 / 90.00 / 90.00 | 92 / 92.00 / 92.00 | 94 / 94.00 / 94.00 | 60, 64, 68 s |
| B | 170 / 170.00 / 170.00 | 172 / 172.00 / 172.00 | 174 / 174.00 / 174.00 | 220, 224, 228 s |
| C | 120 / 120.00 / 120.00 | 124 / 124.00 / 124.00 | 128 / 128.00 / 128.00 | 120, 128, 136 s |

- B is asserted to be 10 bpm above "offset + t" at every reading, and C to be `t / 2` bpm above
  it at the last one. Tolerance 0.25 bpm (half a second).
- Clip B is then exported with "Export as new video" from the Export menu. The export reaches
  `exported` with no alert, and the share sheet is closed. The export was given one tile, slot
  0–10 s, 46 samples: first 167.5 bpm (second 215, the 5 s lead-in before the first frame), last
  190.0 bpm (second 260, the 30 s tail), 170 bpm at the first frame and 175 at the last. Through
  the offset alone each would be 10 bpm lower; that difference is asserted too.
- The check before the export: every check of the visit asked about the two baked rows, was
  answered, found nothing reverted and took under 4 s (measured: 0.004 s, 0.08 s, 0.023 s). After
  the export the editor is `ready` again and clip B still reads through its map.

`StudioHRTimingSeedTests` (new, unit): the seeded rows (A has no map; B is offset 200, length 10,
one segment rendition 0 ↔ source 20, revertible; C is one segment at speed 2), their capture
times, the ramp, that only a seeded identifier is answered with the generated video, and that
nothing is recorded without the seed argument. `UITestStoreTests` lists the new argument.

Gates run: `StudioHRTimingUITests` twice in a row, `LiveWorkoutStudioWalkthroughTests`, the full
unit suite.

## Found

1. **No fault in the app's heart-rate timing.** Preview and export agree with the ramp at the
   mapped capture time, to the hundredth of a bpm, for an unbaked clip, a start trim and 2×.
2. **What the real Photos probe does on the simulator.** For a seeded row
   `ClipBakeService.hasEditedRendition` and `currentDuration` both return `nil`: Photos does not
   know the asset, and the fetch puts up no permission dialog. A `nil` is "no answer about this
   row", so the check finds nothing reverted, clears no map, and ends in a few milliseconds. The
   export goes through the checking phase and starts. No stall, no wrong "reverted in Photos"
   message. This is the case prompt 305's unit tests stand in for with "an asset Photos does not
   know"; it is now seen with the real probe.
3. **Not a timing fault, not fixed here: where a scrub can start.** In the UI test a drag that
   starts on the selected clip's strip or in the ruler above it did not move the playhead; a
   drag that starts in the lane under the clip did, exactly (200 points = 4.000 s). Only seen
   with the simulator's synthetic drags. Owed: one look on a phone at whether a finger on the
   selected clip scrubs. The test drags in the lower lane.
4. **The tile's texts carry the preview's identifier.** `studioHRTile` is set inside
   `studioPreview`, and the outer identifier is the one XCUITest sees on each text. Nothing was
   changed; the test finds the bpm by its place before "BPM".

## Not done

- The Photos write of a bake cannot run on the simulator, so "Save to original" itself and a
  real "Revert to Original" stay on prompt 305's device list. This prompt shows that rows with
  the values a bake writes are read correctly by the running editor.
- The exported file's pixels are not read (the simulator cannot draw the Core Animation tile's
  text; `PLAN.md` P3 moves the tile into the compositor, where golden frames can see it).
- Joined parts and a second bake on top of a first are covered by prompt 305's unit tests only.
