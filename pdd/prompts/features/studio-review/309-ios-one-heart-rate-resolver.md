# Prompt: One heart-rate resolver for the feed, share, Studio and reels

**File**: pdd/prompts/features/studio-review/309-ios-one-heart-rate-resolver.md
**Created**: 2026-11-26
**Project type**: iOS
**Chain**: P4 of `PLAN.md`; follows prompts 305 (one timing rule) and 306. Built on `studio-v2`.
Prompts 307 and 308 (overlays and the HR tile drawn by the compositor) are not on the branch yet;
this prompt does not depend on them.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Problem

Prompt 305 gave every heart-rate reader one rule for WHEN a frame was filmed (`ClipCaptureClock`).
Everything after that was still decided per surface: the window around the footage, how a reading
between two samples is made, what the peak and the average are taken over, and what happens when
no sample is near. So one clip over one series could show different numbers in two places.

## Inventory (from the code on `studio-v2` at `009e59ca`, before this change)

| # | Surface (entry point) | Window | Samples in the window, gaps | Reading at a moment | Peak / average | Rounding | Zone, max HR | No data |
|---|---|---|---|---|---|---|---|---|
| 1 | Feed overlay and its viewers: Clips feed poster, inline player, full screen, Recap viewer, activity viewer, festival set viewer (`ClipHROverlay.make`, `.fraction`) | Kept footage (the Studio trim in `MediaInput.edit`, against the stored length) through the clock; lead-in and tail from the edit, else 5 s and 30 s; the lead-in clamped at the session's start | `HRWindowSlicer`: recorded samples inside, plus one reading at each edge on the straight line between the samples around it. Outside the recording but within 90 s: the nearest sample held flat. Further: none | Straight line in the display series (0.5 s grid, 2 s smoothing), at the chart position of the video's progress | Highest reading and plain mean of the window's readings; with the "Clip only" scope, of the footage's readings | Nearest whole beat | `HeartRateZone.forBpm` against the session's max, 190 without one | No overlay; the name tag only |
| 2 | "Share with heart rate" (`ClipSharePlan.plan`) | Takes the feed's payload | same | same, cut into 60 steps of text | same | same | same | Raw share |
| 3 | Poster chip: Recap carousel, media browser (`FeedMedia.clipHR`) | The WHOLE video through the clock. **No trim, no lead-in, no tail.** Photo: 6 s forward from its moment | `HRWindowSlicer`, as 1 | none shown | Highest and plain mean of the **footage's** readings | Nearest whole beat | Zone of the peak against the session's max | Empty chip |
| 4 | Activity pages' and Kilter library's average (`ActivityMediaIndex.averageBPM`) | The whole video through the clock, at least 1 s. Photo: 10 s either side | **Recorded samples with `start ≤ t ≤ end` only**: no edge readings, no hold | none shown | Plain mean of those samples | Nearest whole beat | none | No number when no sample is inside |
| 5 | Studio preview tile (`previewHR`, `previewTile`) | The clip's trims against the video's real length, through the clock; the HR-window sliders' lead-in and tail (5 s and 30 s unless set) | `HRWindowSlicer`, as 1 | as 1 | as 1, plus calories and HRV from the profile | as 1 | as 1 | The tile's values over no samples (it draws nothing). A clip whose row is not found: the whole session, no window |
| 6 | Studio HR-window sliders (`hrWindowInfo`) | The same window builder as 5 | not sampled; the effective tail ends at the last recorded sample | — | — | — | — | — |
| 7 | Studio export and bake (`clipHRContent` → `StudioHRPlacement.sampleExtended` → `StudioComposer.placedHR`) | as 5 | as 5 | as 2 | as 5 | as 1 | as 1 | The clip gets no tile |
| 8 | Reel scorebug: reel editor preview, exported reel, the feed's Animate (`ReelViewModel.previewHRTile`, `ReelExporter.export(hrOverlay:)`, `ClipExportCoordinator.animate`) | **None per clip.** The whole session's series (a weekly reel: the stitched week) stretched over the reel's length | The whole series | The session at the same FRACTION of its length as the reel is of its own | Whole session | as 1 | The session's max (weekly: the week's highest) | No scorebug when the series is empty |
| 9 | Reel planner's scoring (`HighlightEngine`: `MediaItem`, `HeartRateSeries`) | A clip is a start and a length | 1 s grid, nearest grid point | not shown | not shown | — | — | — |
| 10 | Tile decoration colour (`HRTileView.chromeZoneHex`, `StudioOverlays.averageBPM`) | The tile's samples | all with bpm > 0 | — | Zone of the plain mean of the whole window, whatever the scope | — | as 1 | A fixed colour |

Rows 1, 2, 5, 6 and 7 already agreed: prompts 115 and 116 gave them one window builder and one
slicer, and the feed's value builder was a copy of the Studio's. Row 10 is the same in the preview
and the export, and is a colour, not a number. Row 9 picks clips; it prints nothing.

"Hold the last sample" against "straight line" was not a disagreement between surfaces: every
per-clip surface reads a straight line between samples, and the nearest sample is held only
OUTSIDE the recording (within 90 s of it). Row 4 did neither.

## The disagreements (same clip, same series, different numbers)

The series is prompt 306's ramp, `bpm = 60 + seconds / 2`, recorded 0…300 s, unless said.

1. **Poster chip against the overlay it opens** (rows 3 and 1). A clip filmed 60…70 s. Recap
   poster chip: peak 95, avg 93 (the footage). Tap it: the viewer's tile says PEAK 110, AVG 99 (the
   window 55…100 s). The chip also ignored a Studio trim.
2. **Activity average against the viewer it opens** (rows 4 and 1). The same clip: "♥ 93" in the
   list, AVG 99 in the viewer. Sparse samples (100 at 0 s, 118 at 48 s, 151 at 61 s, 140 at 75 s,
   122 at 110 s; clip 55…67 s): list "♥ 151" (the one sample inside), viewer AVG 136, chip avg 144.
3. **A photo** (rows 3 and 4). Taken at 60 s: chip peak 93 / avg 92 (60…66 s), activity page 90
   (50…70 s).
4. **A reel against everything else** (row 8). A reel of only that 60…70 s clip, session 300 s
   long: the scorebug's BPM ran from 60 to 210 while the clip played, AVG 135, PEAK 210. The feed
   over the same clip: 90 to 95, peak 95.
5. **A clip edited in the Studio, outside the Clips feed** (found in review). Only the Clips feed
   passed a clip's Studio edit (trim, HR window, "Clip only" scope) to its tile. Recap, the
   activity pages, the Kilter library and the festival set screen built the clip without it. One
   clip of the prompt 304 series, trimmed 1.2…6.1 s, window 3 s / 4 s, "Clip only": Clips feed
   AVG 151 / PEAK 159; the same clip's viewer in Recap and on an activity page AVG 145 / PEAK 172.
6. **Outside the recording, the limit depended on the surface and on the side** (review). After
   the last sample a video's reading was held up to 95 s away (the 90 s limit was measured from
   the window's start, 5 s before the footage); before the first sample there was no limit at
   all: a clip filmed ten minutes before the session showed the first sample ("60").
7. **A sample at the edge of the recording was counted twice in the average** (review). Where a
   window reaches past the first or the last recorded sample, the reading at the window's edge is
   that sample again. All of feed, share and Studio did this alike, so it was not a disagreement
   between them; it made the average wrong on all three. The prompt 304 clip with defaults
   (recording ends inside the tail): AVG 145 with the last sample twice, 146 with it once.

## Change

### `ClipHeartRate` (new, pure: `Features/WorkoutTracker/ClipHeartRate.swift`)

```
ClipHeartRate.resolve(series:, clock:, renditionStart:, renditionEnd:, options:) -> ClipHRResult
ClipHeartRate.summary(…same…) -> ClipHRSummary?        peak and average only, no chart built
ClipHeartRate.window(clock:, renditionStart:, renditionEnd:, leadSec:, tailSec:)
```

- `series`: the session's heart rate. `clock`: the clip's `ClipCaptureClock` (prompt 305).
  `renditionStart … renditionEnd`: the stretch of the video the asset plays now.
- `ClipHROptions`: `leadSec`, `tailSec`, `scope` (whole window or footage), `maxHR`, `restHR`,
  `energyProfile` (calories; the Studio only), `includesHRV` (the Studio only), `clampTolerance`.
  Named sets: `.footageOnly` (a reel's clips), `.clip(edit:…)` (the feed and everything next to
  it), `.studio(clip:…)`, `.photo` (10 s either side).
- `ClipHRResult` is `.data(ClipHR)` or `.noData(ClipHRGap)`.
- `ClipHR`: `captureStartSec` and `window` (the capture window), `samples` (window time),
  `renditionSamples` and `renditionChartSamples` (seconds of the video), `isHeld`, and `values`:
  the `HROverlayValues` every tile is drawn from. The bpm at a moment, the peak, the average and
  the zone are read from `values` by every surface (`bpm(atFraction:)`, `live`, `staticValue`),
  so the resolver has no second copy of them.

The rules, each in one place (the type's doc lists them):

- the window: the footage's capture window, widened by the lead-in (clamped at the session's
  start) and the tail;
- the samples: `HRWindowSlicer` (recorded samples plus one straight-line reading at each edge);
- **outside the recording**: footage more than 90 s before the first recorded sample or after
  the last one, measured from the footage's nearest edge, has no heart rate, on either side; the
  lead-in and the tail do not move the limit. Nearer than that, a window that reaches no
  recorded sample shows the nearest one, held (`isHeld`), drawn dashed as before;
- a reading between samples: a straight line in the display series, never "hold the last";
- **peak and average**: the highest reading and the plain mean of the readings in the scope,
  each recorded sample counted once;
- rounding to the nearest whole beat; zones against the session's maximum, 190 without one.

### Every surface calls it

| Surface | Now |
|---|---|
| Feed overlay and viewers | `ClipHROverlay.make` → `ClipHROverlay.resolve` → `ClipHeartRate.resolve` with `.clip(edit:)` |
| "Share with heart rate" | unchanged: burns the payload's values |
| Poster chip | `FeedMedia.clipHR(for:hrSeries:maxHR:)` → `ClipHROverlay.summary` → `ClipHeartRate.summary`, asked exactly as the overlay asks (`ClipHROverlay.request`) |
| Activity average | `ActivityMediaIndex.averageBPM` → `ClipHROverlay.summary` over the clip as its viewer gets it |
| Studio preview, sliders, export, bake | `StudioEditorViewModel.clipHeartRate(of:sourceDuration:)` → `ClipHeartRate.resolve` with `.studio(clip:)`. `scopedOverlayValues` is gone. `PreviewHR` carries the resolved values |
| Reel scorebug | `ReelHeartRate.track` → `ClipHeartRate.resolve` per segment with `.footageOnly` (below) |

Removed: `FeedMedia.clipHR(offsetSec:…)`, `FeedMedia.clipHRWindow`, `ActivityMediaIndex.photoHRWindowSec`,
`StudioEditorViewModel.scopedOverlayValues`, and `StudioHRPlacement.captureWindow` /
`extendedWindow` / `sample` / `sampleExtended` with `SampledClipHR` (no caller left in the app;
the tests written against them now ask `ClipHeartRate` through an adapter in the test target,
`StudioHRPlacementTestSupport.swift`). `StudioHRPlacement` keeps `renditionRange` (new: a clip's
trims as the range the resolver is asked about) and the offset / clock lookup.
`HROverlayValues` gained two optional arguments: `chartSamples` (only the reel passes it) and
`countedSamples` (the readings the aggregates count, when an edge copy is left out).

### The clip's Studio edit reaches every surface

`ClipStudioEdit.byMedia(projects:media:)` (and `byMedia(context:media:)`, one fetch) is the one
lookup, per LIST of media rows, never per cell: only the projects of sessions that have media in
the list are opened. It stamps `MediaInput.edit` in:

- the Clips feed (`ClipsFeedView.makeSnapshot`, as before, now through the shared function);
- Recap: `FeedMediaIndex.editsByMedia`, built once with the index (`FeedView` and
  `CardDetailView` gained a `@Query` of the projects; the feed's signature includes their count
  and newest change), read by `FeedMediaResolver.mediaInputs(for:)` for the card carousel, its
  viewer and "View all";
- the activity pages and the Kilter library: `ActivityMediaStore.snapshot` stamps
  `ActivityMediaInput.edit`, which `mediaInput` (the viewer, compare) and `averageBPM` carry;
- the festival set screen: `ClipRow.edit`, looked up once in `load`.

A baked clip or a posted reel never carries an edit (it is in the pixels), the same rule as
`MediaInput.from`. `ClipOverlayStyleSheet`'s sample clip is not a session's clip.

### One behaviour where two disagreed (each is in `decisions.md`, 2026-11-26)

1. **The chip shows the overlay's PEAK and AVG.** Over the clip's own HR window (its Studio
   lead-in and tail, 5 s and 30 s for a clip never edited), with the clip's scope and its trim.
2. **The activity average is the viewer's AVG.** Same request. Where the viewer's reading is a
   held one (the whole window outside the recording) the list prints no number: it has no
   dashed line to say the number is not a measurement.
3. **A photo is read 10 s either side of its moment**, on both surfaces.
4. **A reel's scorebug reads each clip's own heart rate while that clip is on screen**, from the
   clip's own session, and shows nothing over a clip that has none.
5. **A clip's Studio edit is read everywhere the clip is shown.**
6. **One limit outside the recording: 90 s from the footage's nearest edge, both sides.**
7. **Each recorded sample counts once in the peak and the average.**

### Reels (`Features/Reel/ReelHeartRate.swift`, new, pure)

- `ReelHeartRate.Input`: the planner's media, the baked clips' time maps, and one
  `ReelHeartRate.Session` per session in the reel (its own series in its own seconds, its max and
  rest, where its second 0 sits on the reel's media timeline, which media are its own).
  `ReelSource.heartRate(for:usesManualMedia:)` builds it: one session from the workout for a
  session reel; `WeeklyHighlights.stitchedWorkout`'s new `heartRate` for a weekly, month,
  picked-clips or festival reel. **A clip is resolved against its own session's series only.**
  The stitched series (sessions one second apart) is still what the planner scores; reading a
  clip from it held Monday's last sample over Tuesday's clip.
- `ReelHeartRate.slots(plan:)` (the preview) and `slots(plan:placements:)` (the export): where
  each segment is in the reel. The exporter skips a segment whose asset fails to load, so the
  burned scorebug is timed from `PlacedComposition.placements`, as the captions are.
- `ReelHeartRate.track(slots:totalDuration:input:)`: for each slot it asks `ClipHeartRate.resolve`
  for `startWithinMedia … endWithinMedia` of the clip, footage only, through a clock made from the
  planner's `MediaItem`, the session's origin and the row's `BakedTimeMap`. The readings are laid
  end to end in **runs**: a run is a stretch of neighbouring segments of one session that all
  have heart rate. A photo holds the reading of its moment.
- A segment with no heart rate is in no run. `Track.run(at:)` is `nil` while it plays, so the
  preview shows no scorebug, and `ReelExporter.placedScorebugs` burns one scorebug per run, each
  shown only over its run (`PlacedClipHR`, the Studio's per-clip path), so nothing is drawn over
  the gap and no line is smoothed into or out of it. A reel of one session whose clips all have
  heart rate is one run over the whole reel: one scorebug, drawn as before.
- Within a run the live number and the line are the run's. AVG and PEAK are over every reading
  in the reel that comes from the run's session, so they do not change from one clip of a
  session to the next. Zones are against that session's own maximum.
- The reel editor's preview (`ReelViewModel.previewHRTile(atReelFraction:)`), the exported reel
  (`ReelExporter.HROverlay.heartRate`) and the feed's Animate
  (`ClipExportCoordinator.heartRate(context:workout:)`) all go through these.

The time maps reach the reel beside the planner's inputs, which are not changed:
`SessionHighlightInput.Clip.timeMap` and `KilterWorkoutBuilder.Clip.timeMap` (new, optional),
`SessionHighlightInput.Clip.from(_:)` (one way to make a clip from a row; it decodes the row's
map once) and `ReelSource.timeMaps`. `HighlightEngine` is not touched.

**What stays inexact for reels** (reels move to the new model in P9 and P10):

1. **Which moments the planner picks.** `HighlightEngine` knows a clip as a start and a length.
   For a clip baked at a speed or from joined parts it still scores heart rate second for second
   from the first baked frame, and a weekly reel's trimmed window inside such a clip is placed by
   that scoring. It also scores a weekly reel from the stitched series, so a clip at the very
   edge of a session can be scored with a neighbour's samples. Only the choice is affected; the
   scorebug over whatever was chosen is exact.
2. **Studio edits that are not baked.** A reel plays the asset as Photos has it. A trim, a speed
   or an HR window set in the Studio and not saved to the original does not reach a reel; the
   scorebug matches what the reel plays, and its numbers are always over the footage.
3. **The drawn line in the exported file across a cut inside a run.** The numbers and the
   preview's line come from each clip's own display series. The export's Core Animation chart
   builds its line from the run's samples and smooths it again, so within about a second of a
   cut between two clips that both have heart rate the burned line is slightly rounder than the
   preview's. (Not across a gap: a gap ends the run. Goes away when the compositor draws the
   tile: prompt 308.)
4. **Hand-picked media** (the limited-Photos picker) are not session rows: no time map is
   applied, and they are read against the one session the reel was opened from.
5. Inside a baked clip made of joined parts the reading moves at an even pace through the window
   (as prompt 305 noted for the Studio).
6. A scorebug is not faded in or out at a gap: it is there for the run and gone for the gap.

### Not changed

- Layout. No golden frame changed (the HR tile is not in them yet).
- `StudioHRTimingUITests` (prompt 306) is not extended: its three clips lie inside the recording
  with their windows, so no number in it changed.
- The feed shows no calories and no HRV; the Studio does (`energyProfile`, `includesHRV`).
- The tile's decoration colour (row 10) and the planner's scoring (row 9).
- `FestivalSetStats.hrSlice` reads a SET's window, not a clip's.

### Not done

- **A time-weighted average.** The average is the plain mean of the readings (now each recorded
  sample once, plus a straight-line reading at an edge that falls between two samples). With
  evenly spaced samples that is the time-weighted mean; with sparse or uneven samples it is not
  (the sparse fixture: plain mean 136, time-weighted about 134). A time-weighted mean is the
  honest number. It would change AVG on every surface for unevenly sampled sessions, and it is
  the same statistic the session summary uses (`WorkoutHRStats`), so it is a decision about
  more than clips. Not switched here.
- **A cue on the poster chip for a held reading.** The tile draws a held window dashed; the
  activity list now prints no number for one. The Recap chip still prints the held number with
  no cue (as it did before this prompt).
- A media row cannot hold a negative offset (`SessionMedia.init` clamps it), so "filmed before
  the session" reaches the resolver only from rows changed after they were made. The limit is in
  the resolver all the same and is tested through the values each surface reads.

## What changes for the user

1. **Recap: the peak / average chip on a clip's poster** (feed card carousel and "View all")
   now matches the tile shown when the clip is opened. Example: 95 / 93 becomes 110 / 99. The
   chip's colour is the peak's zone, so it can change with it.
2. **Activity pages and the Kilter library: "♥ avg" next to a clip** now matches AVG in its
   viewer. Example: 93 becomes 99. A clip filmed between two sparse samples now has a number
   where it had none.
3. **Photos**: the chip and the activity number are both read 10 s either side of the photo.
   Example: chip 93 / 92 becomes 95 / 90.
4. **Reels** (session, Kilter, weekly, month and picked-clip reels, festival reels, progress
   reels, the feed's Animate): the scorebug's BPM, chart, AVG and PEAK are the heart rate of the
   clips in the reel, each while it is on screen. Before, they were the whole session squeezed
   over the reel. Example: a reel of one clip filmed 60…70 s of a 300 s session: BPM 60 → 210,
   AVG 135, PEAK 210 becomes BPM 90 → 95, AVG 93, PEAK 95.
5. **A reel clip with no heart rate has no scorebug over it.** In a weekly reel, a clip from a
   day with no band showed the stretched week's series before; the scorebug now disappears for
   that clip and comes back for the next one that has heart rate. In a weekly reel the chart and
   the zone colours start again at each change of session, and AVG / PEAK are that session's.
6. **The feed's Animate for a session with no heart rate** no longer burns an empty glass panel
   at the bottom of the video. A change of pixels, for the better.
7. **A clip edited in the Studio looks the same everywhere.** In Recap, on the activity pages,
   in the Kilter library and on the festival set screen, a clip with a Studio trim now plays its
   kept range, starts its poster at the first kept frame and shows the "Edited" chip, as it
   already did in the Clips feed, and its tile and the numbers next to it use the clip's HR
   window and "Clip only" scope. Example (the clip of disagreement 5): Recap and the activity
   viewer AVG 145 / PEAK 172 become AVG 151 / PEAK 159, the Clips feed's numbers.
8. **Clips feed, "Share with heart rate" and the Studio change in two cases only:**
   - *A clip filmed outside the recorded heart rate.* More than 90 s after the last sample (it
     was 95 s for a video) or more than 90 s before the first one (it had no limit): no tile.
     Example: a clip that starts 93 s after the heart rate stopped showed "210" held, now shows
     none; a clip filmed ten minutes before the session showed "60", now shows none.
   - *A clip whose HR window reaches past the start or the end of the recording.* AVG no longer
     counts the first or last sample twice. Example: AVG 145 becomes 146 (the prompt 304 clip,
     recording ends inside the tail). Where the samples are dense the average usually rounds to
     the same beat. Clips inside the recording with their whole window are unchanged, bit for
     bit.

## Tests

- `ClipHRCharacterizationTests`: eighteen clips (never baked; baked with a start trim; baked at
  2×; baked from joined parts; sparse samples; none nearby; held at the recording's edge; 93 s
  after it; before the session; lead-in clamped at the session's start; the prompt 304 series
  with defaults; the same trimmed with a 3 s / 4 s window and "Clip only"; no lead-in and no
  tail; a one-sample series; an empty series; a recording that ends inside the tail; one that
  starts inside the footage; a video of unknown length) through the feed, the share plan, the
  poster chip, the activity average and the running Studio view model (preview at six playhead
  times, sliders, export). Everything is compared as exact text.
  **How the "before" values were taken:** the test file and its Studio harness were copied into
  a separate checkout of `studio-v2` at `009e59ca` and run there (the chip and the photo asked
  as that commit's Recap carousel asked them). That run printed all 94 records. It confirmed
  every one of the 52 values the first commit of this branch had recorded (which had been taken
  in the working tree before any surface was rerouted, not on a clean checkout) and supplied the
  rest. 63 records are unchanged; the 31 that differ are listed in the test with their old
  values, and a test fails if a feed, share or Studio record changes outside the two rules of
  "What changes for the user" 8.
- `ClipHRCrossSurfaceTests`: the cross-surface test. For each clip one in-memory store holds
  the session, the media row and the Studio project, and every surface gets the clip the way it
  really does (the table at the top of the file). Fixtures: clips A, B and C of prompt 306's
  seed, the prompt 304 series, a sparse clip, four clips edited in the Studio (a trim, "Clip
  only", a custom window, all three) and a clip with no samples nearby. Compared with the Clips
  feed's: the bpm at six moments, the printed live number, PEAK, AVG and the samples, for share,
  the Recap chip and viewer, the activity number and viewer, the festival viewer, the Studio
  preview, sliders and export; over the footage alone also the reel's preview and its burned
  tile. A second test shows each Studio edit does change the numbers, so a surface that dropped
  it would fail. No assertion compares a surface with `ClipHeartRate` itself. Also: no samples
  nearby shows nothing anywhere; the 90 s limit on both sides on every surface; a sample at the
  edge counts once; the numbers are the seconds the clip was filmed at; a baked clip stands
  down. Reels: two clips; a segment that starts inside a clip; a clip without heart rate in the
  MIDDLE (no scorebug in preview or export, no line across); one session's AVG / PEAK on both
  sides of a gap; a skipped middle segment (timed from placements); a weekly reel whose second
  session has no band; a clip just before its own session's start; each source hands over the
  time maps and the sessions and hand-picked media get neither; Animate's input, and nothing
  burned without heart rate.
- `FeedMediaTests`, `ActivityMediaIndexTests`, `BakedClipHRTimeTests`: updated where a recorded
  decision changed a number (each with the old number in a comment).
- Not covered by a test: the one line in `ReelViewModel` that passes
  `source.heartRate(for:usesManualMedia:)` on (the view model needs an `AppModel`, which the
  unit tests cannot make), and the same line in `ClipExportCoordinator.animate`. What they pass
  is tested.
- Full unit suite, the UI classes `StudioHRTimingUITests`, `LiveWorkoutStudioWalkthroughTests`,
  `ClipsFeedUITests`, `FeedHRCardUITests`, `ActivityProgressUITests`, and a device compile.

## Owed on device

Nothing here was run on a phone.

1. Recap: a session with heart rate and a video. The chip on the poster and the PEAK / AVG of the
   tile after opening it are the same numbers.
2. An activity page with a past clip: "♥ n" in the list equals AVG in the viewer.
3. Trim a clip in the Studio and set "Clip only" (do not save to the original). The clip plays
   trimmed, shows "Edited", and shows the same PEAK / AVG in the Clips feed, in Recap, on its
   activity page and, for a festival clip, on the set screen. Scroll Recap and an activity page
   with many clips: no new hitch.
4. Make a highlight reel of a session with two clips filmed at clearly different efforts. In the
   editor's preview the BPM over each clip is that clip's (compare with the Clips feed); export
   and check the burned scorebug agrees, including across the cut.
5. A weekly reel with a day recorded without a band: no scorebug over that day's clips, in the
   preview and in the exported file; it returns for the next day's, with that day's AVG / PEAK.
6. A reel that contains a clip baked at 2× ("Save to original"): the BPM runs through the whole
   effort over the clip.
7. The feed's Animate on a climb session: the burned scorebug reads the clip's heart rate. On a
   session with no heart rate: no panel at all.
8. A clip filmed a couple of minutes after stopping the band: no tile in the feed (it showed the
   last reading held).
9. Clips feed tile, "Share with heart rate" and the Studio tile on a clip filmed mid-session:
   unchanged from before this build.
