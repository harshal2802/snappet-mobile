# Prompt: A baked clip keeps its heart-rate timing

**File**: pdd/prompts/features/studio-review/305-ios-studio-baked-clip-hr-time-map.md
**Created**: 2026-11-25
**Project type**: iOS
**Chain**: closes the first "Not done" item of prompt 303; a user-reported priority, done before
P2 of `PLAN.md`. Built on `studio-v2`.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`,
`pdd/context/snappet-core-schema.md`

> **Warning: this adds a model field** (`SessionMedia.bakeTimeMapData`). The phone must only ever
> get builds that contain it. A build without the field migrates it out of the real store, and
> every baked clip loses its map (repo memory rule "phone build = schema superset").

## Problem

"Save to original · revertible" writes the trimmed or sped video into the same Photos asset.
Prompt 303 left `SessionMedia.offsetSec` where it was, because "Revert to Original" in Photos
brings the original back and there was nowhere to keep the offset from before the bake.

So the app knew when the ORIGINAL started and nothing about the video the asset plays now. An HR
tile added in the Studio to an already baked clip that was trimmed at the start read heart rate
from the original's start: early by the trimmed seconds. A baked speed change was wrong in the
same way (a baked 2× clip of 4 s read 4 s of heart rate instead of 8), and so were baked split
parts (the seconds left out between two kept ranges were not skipped).

Confirmed by reading the code on `studio-v2` (`612ac00d`). Not reproduced on a device.

## Change

### One new stored field

`SessionMedia.bakeTimeMapData: Data?` holds a JSON `BakedTimeMap` (typed view: `bakeTimeMap`).
Optional, no default, so SwiftData migrates it without a plan (the repo has no versioned schema;
every earlier field was added the same way).

```
BakedTimeMap
  segments: [ (renditionStartSec, sourceStartSec, speed) ]   ordered, the first starts at 0
  renditionDurationSec                                        where the last segment ends
  isRevertible                                                true = "Save to original"
```

- **Rendition time** is seconds into the video the asset plays now. **Source time** is seconds
  into the recording whose first frame was filmed at `offsetSec`.
- `nil` means the two are the same: never baked, reverted, a bake that changed no timing, or
  baked before this field existed. An identity map is never stored.
- A segment owns its start and not its end, so a boundary belongs to the segment that begins
  there.

### One rule for when a frame was filmed

`ClipCaptureClock(offsetSec:timeMap:)`, in `BakedTimeMap.swift`, is the only place the two
values are combined:

```
capture time = offsetSec + (timeMap?.sourceTime(renditionTime) ?? renditionTime)
```

`captureTime(renditionTime:)` is that line. `captureWindow(renditionStart:renditionEnd:)` is the
window a heart-rate reader slices: from the earliest frame in the range to the latest. Two joined
parts give one window that includes the seconds left out between them.

A bake changes one of the two values for a given shift, never both:

- **"Save to original"** never moves `offsetSec`. All of the bake's timing goes in the map.
- **"Replace original"** moves `offsetSec` forward to the earliest kept footage, as before. A
  plain start trim needs nothing else and stores no map. A speed change, joined parts, or a map
  carried over from an earlier bake cannot be said with an offset, so the map is stored too, with
  the offset's shift taken out of it and `isRevertible = false`.

### `ClipBakePlan` (pure)

- `timeMap(parts:sourceDurations:transitions:existing:isRevertible:)` computes the map from the
  snapshot the bake rendered (`bakedClips`, `sourceDurations` and the transitions, all read before
  the first `await` in `bake()`). One segment per part, over the stretch of the output the part
  owns (`StudioGeometry.ownedWindows`). A transition between two parts is split at its middle,
  the rule the HR tile and the playhead already use. Neighbouring segments that run on without a
  jump are joined, so a split with nothing removed is `nil`.
- `existing` is the map the row already carries. A second bake renders the first bake's video,
  so the two maps are composed: the result is still measured from the original recording.
- `revertibleMediaUpdate` and the new `replacedMediaUpdate` return `MediaUpdate(offsetSec,
  durationSec, timeMap)`. `bake()` writes all three with `isBaked`, before its one save.
- `revertedTimeMap`: `nil` for a revertible map, unchanged for a "Replace original" map.
- `earliestTrimStart` is gone. The shift is `BakedTimeMap.earliestSourceSec`.

### Revert

`reconcileBakedFlags` clears the map with `isBaked` and the restored length, in the same save. A
"Replace original" map stays: that asset is a new video with no edited rendition, which is what
the revert probe looks for, and it has no original to go back to. The two Photos questions are
behind `bakedAssetProbe` (`nil` in the app), so the revert path can be tested.

### Every heart-rate reader

| Reader | What it did | Now |
|---|---|---|
| Studio preview tile (`previewHR`, `previewTile`) | offset + trim | `captureClock(of:)` → `StudioHRPlacement.extendedWindow(timeMap:)` → the clock |
| Studio HR-window sliders (`hrWindowInfo`) | offset + trim | the same call |
| Studio export and bake (`clipHRContent` → `StudioComposer.placedHR`) | offset + trim | `sampleExtended(timeMaps:)` → the clock |
| Feed overlay (`ClipHROverlay.make`) | none on a baked clip | unchanged and pinned by a test; the map is passed for a clip that has one and is not marked baked |
| "Share with heart rate" (`ClipSharePlan`) | raw for a baked clip | unchanged and pinned; it burns the feed overlay's payload |
| Poster peak / average chip (`FeedMedia.clipHR`: Recap carousel, media browser) | offset + length | the clock, through `MediaInput.timeMap` |
| Activity pages' average (`ActivityMediaIndex.averageBPM`, also Kilter library) | offset + length | the clock, through `ActivityMediaInput.timeMap` |
| Reel maker (`SessionHighlightInput.Clip`, `KilterWorkoutBuilder.Clip`: session, weekly, festival-recap and Kilter reels, the feed's Animate) | offset as the clip's start | `SessionMedia.reelStartSec`: when the first frame of the baked video was filmed |

`StudioEditorViewModel` keeps one clock per media row (`mediaClocks`), so a clip's offset and map
always come from the same row (`StudioHRPlacement.resolveClock`, the lookup `resolveOffset` uses).

### Backup

`SnappetBackup.SessionMediaRow.bakeTimeMap` carries the map as a nested value. A backup without
the key restores with no map. The cloud backup uploads the same file. Nothing else copies media
rows (`isBaked` was searched for).

### Clips baked before this change

They have no map and nothing can rebuild one: the trim left the project with the bake. Their
behaviour is exactly as before this prompt (an HR tile added in the Studio reads from the
original's start). Baking such a clip again stores a map for the second bake only.

## Not done

- The reel planner (`HighlightEngine`) knows a clip's start and length only. A baked start trim
  is now exact in a reel. A baked speed change or joined parts are not: the reel reads heart rate
  second for second from the first baked frame. P4 of `PLAN.md` (one heart-rate resolver) is the
  place for it.
- The festival set viewer and the festival set reel build their clips from the tag pipeline's own
  snapshot (`FestivalTagging`), which does not carry the map. They read `offsetSec` as before.
- Inside the HR window of joined parts the chart is one stretch of the session and the dot moves
  through it at an even pace, so it runs slightly behind after a join. The window's start, end
  and numbers are right.
- A "Replace original" clip loses `isBaked` the next time the Studio opens (the new asset has no
  edited rendition, so the revert probe reads it as reverted). That was so before this prompt and
  is not changed here; the map of such a clip is kept, and the feed overlay it then gets reads
  through the map.

## Tests

`BakedClipHRTimeTests` (new). The heart-rate series is `bpm = 100 + t`, so a reading names the
second it came from.

- the map, pure: nothing trimmed, an end trim alone and a split with nothing removed store `nil`;
  a start trim; start and end trim; speed 0.5; speed 2 (also with nothing trimmed); two parts
  with a gap, with `captureTime` and `segmentIndex` on, before and after the boundary; parts out
  of recording order; a transition between parts; a second bake on top of a first (trim and
  speed, 2× on 2×, a bake that changes nothing); a second bake across a join.
- row updates, pure: "Save to original" keeps the offset and writes a revertible map; "Replace
  original" moves the offset and stores a map only for speed, joined parts or a carried map, with
  the same capture times before and after; a revert drops a revertible map only; the stored JSON,
  an unreadable value, `captureClock` and `reelStartSec` on the row.
- readers: no map changes nothing; the Studio window builder and `sample` with a map; the clock
  is resolved like the offset; the poster chip and the activity average; the feed gives no
  overlay for a baked clip with a map, shares it raw, and reads the map for a clip not marked
  baked.
- view model (in-memory store, stand-in baker, render and length reader): a clip trimmed 2–6 s
  is saved to the original and an HR tile is added. The export's `PlacedClipHR`
  (`StudioComposer.placedHR` on the render plan's clips) and the preview tile both start at 112
  and end at 116; `offsetSec` is still 10; the lead-in slider reaches back from second 12; the map
  is in the store. After a stand-in revert the map is `nil`, the length is the original's and
  both start at 110. A probe that still finds the edited video, or no asset, clears nothing. A
  baked 2× clip reads 4 s over its 2 s. "Replace original": offset 12 and no map; with 2×, offset
  12 and a map, which a "revert" probe does not clear. A failing save: the flag, the length and
  the map are all on the row when the save is tried, nothing reaches the store, and the next save
  that works stores the three together.

`SnappetBackupTests`: the map survives a backup and a restore; the same file without the key
restores with no map. `ClipBakePlanTests`: `testEarliestTrimStart` is replaced by the same case
through the map.

Each of these fails if the map is ignored. The full unit suite was run. The UI suite was not: no
screen and no identifier changed.

## Owed on device

Nothing here was run on a phone. Each step needs a session with recorded heart rate.

1. A clip with a clear effort in the middle. Trim off the start, "Save to original". Add the HR
   tile in the Studio. The chart's peak is at the same moment of the picture as in the feed
   overlay before the bake (not earlier by the trimmed seconds). Export: the file agrees.
2. The same with "Revert to Original" in Photos afterwards, then open the Studio: the clip has
   its full length and the tile starts at the original's start.
3. A clip at 2×, "Save to original", add the tile: the chart covers the whole effort, not its
   first half.
4. Split a clip, delete the middle part, "Save to original", add the tile: the chart runs from
   the first kept frame to the last.
5. Bake a baked clip again with a further start trim: the tile is still on the right seconds.
6. "Replace original" with a start trim: as before this prompt (the tile is on the right
   seconds). With 2×: the chart covers the whole effort.
7. Back up, restore on the same phone, open a baked clip in the Studio: the tile is unchanged.
8. Install over a store from the build before this one: every clip is there and nothing about
   clips baked earlier has changed.
