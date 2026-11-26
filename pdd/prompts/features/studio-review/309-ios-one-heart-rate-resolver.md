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

The series is prompt 306's ramp, `bpm = 60 + seconds / 2`, unless said.

1. **Poster chip against the overlay it opens** (rows 3 and 1). A clip filmed 60…70 s. Recap
   poster chip: peak 95, avg 93 (the footage). Tap it: the viewer's tile says PEAK 110, AVG 99 (the
   window 55…100 s). The chip also ignored a Studio trim.
2. **Activity average against the viewer it opens** (rows 4 and 1). The same clip: "♥ 93" in the
   list, AVG 99 in the viewer.
   - Sparse samples (100 at 0 s, 118 at 48 s, 151 at 61 s, 140 at 75 s, 122 at 110 s; clip 55…67 s):
     list "♥ 151" (the one sample inside), viewer AVG 136, poster chip avg 144.
   - A clip filmed 320…330 s when the heart rate ended at 300 s: list shows no number, the viewer
     and the chip show 210 (the last sample, held).
3. **A photo** (rows 3 and 4). Taken at 60 s: chip peak 93 / avg 92 (60…66 s), activity page 90
   (50…70 s).
4. **A reel against everything else** (row 8). A reel of only that 60…70 s clip, session 300 s
   long: the scorebug's BPM ran from 60 to 210 while the clip played, AVG 135, PEAK 210. The feed
   over the same clip: 90 to 95, peak 95.

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
- `ClipHRResult` is `.data(ClipHR)` or `.noData(ClipHRGap)` (`noSeries` or `farFromAnySample`).
- `ClipHR`: `captureStartSec` and `window` (the capture window), `samples` (window time),
  `renditionSamples` and `renditionChartSamples` (seconds of the video), `bpm(atVideoFraction:)`,
  `bpm(atRenditionTime:)`, `zone(atVideoFraction:)`, `peakBpm`, `averageBpm`, `summary` (whole
  beats), and `values` (the `HROverlayValues` every tile is drawn from).

The rules are the ones rows 1, 2, 5 and 7 already shared, now written once (the type's doc lists
them). Nothing about them changed, so those surfaces give bit for bit what they gave.

### Every surface calls it

| Surface | Now |
|---|---|
| Feed overlay and viewers | `ClipHROverlay.make` → `ClipHROverlay.resolve` → `ClipHeartRate.resolve` with `.clip(edit:)` |
| "Share with heart rate" | unchanged: burns the payload's values |
| Poster chip | `FeedMedia.clipHR(for:hrSeries:maxHR:)` → `ClipHROverlay.summary` → `ClipHeartRate.summary`, asked exactly as the overlay asks (`ClipHROverlay.request`) |
| Activity average | `ActivityMediaIndex.averageBPM` → `ClipHROverlay.summary` over the clip as its viewer gets it |
| Studio preview, sliders, export, bake | `StudioEditorViewModel.clipHeartRate(of:sourceDuration:)` → `ClipHeartRate.resolve` with `.studio(clip:)`. `scopedOverlayValues` is gone. `PreviewHR` carries the resolved values |
| `StudioHRPlacement` | `extendedWindow` is `ClipHeartRate.window`; `sampleExtended` is `ClipHeartRate.resolve`; `renditionRange` (new) turns trims into the range asked about |
| Reel scorebug | `ReelHeartRate.track` → `ClipHeartRate.resolve` per segment with `.footageOnly` (below) |

Removed: `FeedMedia.clipHR(offsetSec:…)`, `FeedMedia.clipHRWindow`, `ActivityMediaIndex.photoHRWindowSec`,
`StudioEditorViewModel.scopedOverlayValues`. `HROverlayValues` gained `rawAverageBpm` and an
optional `chartSamples` argument (only the reel passes it).

### One behaviour where two disagreed (each is in `decisions.md`, 2026-11-26)

1. **The chip shows the overlay's PEAK and AVG.** Over the clip's own HR window (its Studio
   lead-in and tail, 5 s and 30 s for a clip never edited), with the clip's scope and its trim.
   Prompt 115 chose the whole window as the default for a clip's numbers ("PEAK includes the spike
   that lands after the camera stops"); the chip now follows that choice.
2. **The activity average is the viewer's AVG.** Same request. It gains the edge readings and the
   90 s hold, so a clip between two sparse samples has a number.
3. **A photo is read 10 s either side of its moment**, on both surfaces. A photo has no "after".
4. **A reel's scorebug reads each clip's own heart rate while that clip is on screen.**

### Reels (`Features/Reel/ReelHeartRate.swift`, new, pure)

`ReelHeartRate.track(plan:media:series:timeMaps:)` walks the planned segments on the reel's
timeline (`ReelTimelineMap`). For each video segment it asks `ClipHeartRate.resolve` for
`startWithinMedia … endWithinMedia` of the clip, footage only, through a clock built from the
planner's `MediaItem` and the row's `BakedTimeMap`; the readings are laid end to end in reel time.
A photo holds the reading of its moment for as long as it is shown. `ReelHeartRate.values` builds
the scorebug's values; the reel editor's preview, the exported reel and the feed's Animate all use
the two calls.

The time maps reach the reel beside the planner's inputs, which are not changed:
`SessionHighlightInput.Clip.timeMap` and `KilterWorkoutBuilder.Clip.timeMap` (new, optional),
`SessionHighlightInput.Clip.from(_:)` (one way to make a clip from a row, used by the session,
weekly, collection, festival and Animate sources) and `ReelSource.timeMaps`. So a clip baked at
2× or from joined parts now has the right heart rate in a reel's scorebug.
`HighlightEngine` is not touched.

**What stays inexact for reels** (reels move to the new model in P9 and P10):

1. **Which moments the planner picks.** `HighlightEngine` knows a clip as a start and a length.
   For a clip baked at a speed or from joined parts it still scores heart rate second for second
   from the first baked frame, and a weekly reel's trimmed window inside such a clip is placed by
   that scoring. Only the choice is affected; the scorebug over whatever was chosen is exact.
2. **Studio edits that are not baked.** A reel plays the asset as Photos has it. A trim, a speed
   or an HR window set in the Studio and not saved to the original does not reach a reel; the
   scorebug matches what the reel plays.
3. **The drawn line in the exported file across a cut.** The numbers and the preview's line come
   from each clip's own display series. The export's Core Animation chart builds its line from
   the reel's samples and smooths it again, so within about a second of a cut the burned line is
   slightly rounder than the preview's. (Goes away when the compositor draws the tile: prompt 308.)
4. **A clip with no heart rate inside a reel.** The line runs straight across it and the number
   holds; `Track.segmentsWithoutData` names it. The scorebug is not hidden for that clip.
5. **Weekly, collection and festival reels**: one maximum and one resting heart rate for the whole
   reel (the highest and the lowest of its sessions), so zone colours are not per session. A clip
   that lies outside its own session's recording can take its edge reading from the neighbouring
   session on the stitched timeline.
6. **Hand-picked media** (the limited-Photos picker) are not session rows: no time map is applied.
7. Inside a baked clip made of joined parts the reading moves at an even pace through the window
   (as prompt 305 noted for the Studio).

### Not changed

- Visuals and layout. No golden frame changed (the HR tile is not in them yet).
- The Studio's numbers: `StudioHRTimingUITests` (prompt 306) is not extended.
- The feed shows no calories and no HRV; the Studio does (`energyProfile`, `includesHRV`).
- The average stays the plain mean of the window's readings (recorded samples plus the two edge
  readings), not a time-weighted mean. When the recording ends inside the window, the last sample
  is also the window's end reading and so counts twice. Feed, share and Studio have always shown
  this number; changing it would change all three and is not a disagreement between surfaces.
- The activity pages, Recap and the festival set screen do not pass a clip's Studio edit to their
  viewer or their number: both use the defaults, so they agree with each other, but a clip with a
  custom HR window in the Studio shows the default window there. P6 (clip edits) is the place.
- The tile's decoration colour (row 10) and the planner's scoring (row 9).
- `FestivalSetStats.hrSlice` reads a SET's window, not a clip's.

## What changes for the user

1. **Recap: the peak / average chip on a clip's poster** (feed card carousel and "View all")
   now matches the tile shown when the clip is opened. Example: 95 / 93 becomes 110 / 99. The
   chip's colour is the peak's zone, so it can change with it.
2. **Activity pages and the Kilter library: "♥ avg" next to a clip** now matches AVG in its
   viewer. Example: 93 becomes 99. A clip filmed between two sparse samples, or just after the
   heart rate stopped, now has a number where it had none.
3. **Photos**: the chip and the activity number are both read 10 s either side of the photo.
   Example: chip 93 / 92 becomes 95 / 90; the activity number for a photo between sparse samples
   can change (it now counts the readings at the window's edges).
4. **Reels** (session, Kilter, weekly, month and picked-clip reels, festival reels, progress
   reels, the feed's Animate): the scorebug's BPM, chart, AVG and PEAK are the heart rate of the
   clips in the reel, each while it is on screen. Before, they were the whole session squeezed
   over the reel. Example: a reel of one clip filmed 60…70 s of a 300 s session: BPM 60 → 210,
   AVG 135, PEAK 210 becomes BPM 90 → 95, AVG 93, PEAK 95. A reel whose clips have no heart rate
   near them has no scorebug (before: the session's).
5. Nothing changes in the Clips feed's own tile, "Share with heart rate", or the Studio.

## Tests

- `ClipHRCharacterizationTests` (written and recorded BEFORE the refactor, on `009e59ca`): ten
  clips (never baked; baked with a start trim; baked at 2×; sparse samples; none nearby; held at
  the recording's edge; lead-in clamped at the session's start; a 40 s real-shaped series with
  defaults; the same trimmed with a 3 s / 4 s window and the "Clip only" scope; no lead-in and no
  tail) through the feed, the share plan, `StudioHRPlacement`, the poster chip, the activity
  average and the running Studio view model (preview at six playhead times, sliders, export).
  Everything is compared as exact text. After the refactor all 40 feed / share / Studio /
  view-model records are unchanged; the chip and activity records that changed are listed in the
  test with their old values.
- `ClipHRCrossSurfaceTests`: the cross-surface test. Clips A, B and C of prompt 306's seed, the
  prompt 304 heart-rate fixture, a sparse clip and a clip with no samples nearby. Each surface is
  asked through its own entry point and compared with the feed's: the bpm at six moments, the
  printed live number, PEAK and AVG, and the samples. Over the clip's own window: feed, share,
  chip, activity, Studio preview, sliders, export. Over the footage alone: feed, share, chip,
  Studio and the reel (planned by `ReelPlanner` from the session source's clip). No samples
  nearby: nothing anywhere. Also: the numbers are the seconds the clip was filmed at; a clip
  marked baked still stands down in the feed; a reel of two clips reads each clip's own heart
  rate; the reel's clock for a baked clip is the row's clock; a reel clip without heart rate
  leaves the other in place. No assertion compares a surface with `ClipHeartRate` itself.
- `FeedMediaTests`, `ActivityMediaIndexTests`, `BakedClipHRTimeTests`: updated where a recorded
  decision changed a number (each with the old number in a comment); the slicing tests ask the
  resolver's footage-only samples.
- Full unit suite, the UI classes `StudioHRTimingUITests`, `LiveWorkoutStudioWalkthroughTests`,
  `ClipsFeedUITests`, `FeedHRCardUITests`, and a device compile.

## Owed on device

Nothing here was run on a phone.

1. Recap: a session with heart rate and a video. The chip on the poster and the PEAK / AVG of the
   tile after opening it are the same numbers.
2. An activity page with a past clip: "♥ n" in the list equals AVG in the viewer.
3. Make a highlight reel of a session with two clips filmed at clearly different efforts. In the
   editor's preview the BPM over each clip is that clip's (compare with the Clips feed); export
   and check the burned scorebug agrees, including across the cut.
4. A weekly reel: the scorebug changes with each clip and never shows a number from between
   sessions.
5. A reel that contains a clip baked at 2× ("Save to original"): the BPM runs through the whole
   effort over the clip.
6. The feed's Animate on a climb session: the burned scorebug reads the clip's heart rate.
7. Clips feed tile, "Share with heart rate" and the Studio tile on one clip: unchanged from
   before this build.
