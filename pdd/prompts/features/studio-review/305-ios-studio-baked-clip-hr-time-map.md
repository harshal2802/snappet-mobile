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
  revertsTo: (segments, renditionDurationSec)?                only over a replaced video
```

- **Rendition time** is seconds into the video the asset plays now. **Source time** is seconds
  into the recording whose first frame was filmed at `offsetSec`.
- `nil` means the two are the same: never baked, reverted, a "Save to original" that changed no
  timing, or baked before this field existed.
- The value is also the row's **bake record**. `isRevertible == false` says "this asset IS the
  bake, there is nothing to revert". A "Replace original" row always has one, also when its
  timing is the identity (review follow-up, below). `revertsTo` is the timing of a replaced video
  under a later "Save to original": what a Photos revert goes back to.
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
- **"Replace original"** moves `offsetSec` forward to the earliest kept footage, as before, and
  stores a map with that shift taken out of it and `isRevertible = false`. For a plain start
  trim that map is the identity: it changes no time and is kept as the record. A speed change,
  joined parts, or a map carried over from an earlier bake give a real map.

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
- `revertFinding(map:)` reads what "no edited rendition" means for a row: `nothingToRevert`
  (a replaced asset), `backToReplaced(map)` (a "Save to original" over a replaced video), or
  `backToRecording`.
- `earliestTrimStart` is gone. The shift is `BakedTimeMap.earliestSourceSec`.

### Revert

`reconcileBakedFlags` clears the map with `isBaked` and the restored length, in the same save,
when the row's record says the asset went back to the recording. The two Photos questions are
behind `bakedAssetProbe` (`nil` in the app), so the revert path can be tested.

### Review follow-ups (same PR, second commit)

1. **A replaced clip stays baked.** A "Replace original" asset is a new video with no edited
   rendition, and "no edited rendition" is how a revert is found. So the next Studio open cleared
   `isBaked` and the clip's `baked` record on every replaced clip: the feed drew a live HR
   overlay over the burned one, "Share with heart rate" burned a second tile and the Studio drew
   project-wide items again. (This was so since prompt 117.) Now a replaced row always carries a
   not-revertible record, and the check leaves such a row alone: flag, `baked` record, map,
   offset and length stay.
2. **A revert over a replaced clip goes back to the replaced video's record.** "Save to
   original" on a replaced clip keeps that clip's timing in `revertsTo`. A found revert sets the
   row's map to it (not revertible again), keeps `isBaked`, and records the asset's length. A
   "Save to original" that changes no timing over a replaced clip stores an identity map, so the
   record is not lost.
3. **The festival set screen** (`FestivalSetDetailView.ClipRow`) carries the row's flag and map:
   its viewer stands down on a baked clip and its set reel starts at `captureStartSec`.
4. **A bake asks Photos first.** `bake()` awaits the same check before it reads its snapshot, so
   the row's map is composed into the new one only after a probe. The check also runs when the
   app returns to the foreground with the Studio open. After a found revert the clip's length is
   read again and the composer forgets the opened asset, as after a bake. The check does nothing
   while a bake or an export renders.

### Second review follow-ups (same PR, third commit)

1. **One check at a time.** `reconcileBakedFlags()` holds the check in flight; the Studio's
   opening, the return to the foreground, `bake()` and `startExport()` all get the same task, and
   its value says whether any clip changed. The rows are fetched once. It returns `nil` when the
   session has no baked video.
2. **A "checking" phase** in the pure `StudioEditorState` (`checkBegan(kind)`, `checkPassed`,
   `checkFoundRevert`). From the save or export tap until Photos has answered: no edit, no
   close, no other render. It is entered only when the session has a baked video, so an export
   of a session with none starts at once, as before.
3. **A check that changed a clip stops the render.** The preview and the trims on screen were
   made against the video that is gone, so the bake does not carry on with them. The lane's own
   failure alert says "This clip was reverted in Photos. Check it and save again." (export:
   "… and export again."). The next tap has no baked row to ask about, or asks again.
4. **An export asks Photos first too**, through the same check, phase and stop rule. Before, an
   export right after a revert in Photos burned heart rate through the stale map.
5. **Nothing of the check runs under a render.** A check that finds a revert while a bake or an
   export renders changes nothing, is remembered (`reconcileOwed`) and runs again when the render
   ends. A render cannot start under the check's last part (forget, read the length, rebuild the
   preview), because every render waits for the check in flight.
6. **Availability before anything is opened.** After a revert the video that is current again
   may be in iCloud only. The check asks the availability service about the changed assets
   before the composer forgets them and before a length is read or a preview built. A clip that
   is not on this phone gets the "Download clip" panel (prompt 302) and its recorded length, as
   any other clip; nothing is downloaded without a word.
7. **Back from Photos inside a full-screen cover.** The Studio also observes
   `UIApplication.didBecomeActiveNotification`, because the scene phase may not be delivered
   inside a cover. Both signals for one return share one check.

### Clips replaced before this change

They have `isBaked` and no record, exactly like a "Save to original" that changed no timing.
Nothing stored tells the two apart, so such a clip is still un-flagged the next time the Studio
is opened for its session (if it is still flagged today; any clip whose Studio was opened since
its bake already is). A rule from dates was looked at and dropped: a replaced asset's creation
date is the bake time only when the rendered file has no creation date of its own, the row's
`linkCapturedAt` is stamped again from whatever asset the row points at, and a manually added
clip's capture date has no fixed relation to its offset. A wrong "replaced" would keep a
reverted clip flagged for good, with no overlay anywhere. To put one right by hand: "Replace
original" again from the Studio (a bake with no edits), which writes the record.

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
| Reel maker (`SessionHighlightInput.Clip`, `KilterWorkoutBuilder.Clip`: session, weekly, festival-recap, festival-set and Kilter reels, the feed's Animate) | offset as the clip's start | `SessionMedia.reelStartSec` (`ClipRow.reelClip` on the festival set screen): when the first frame of the baked video was filmed |
| Festival set viewer (`FestivalSetDetailView`) | offset, no flag | `ClipRow.mediaInput` carries the flag and the map, like `MediaInput.from` |

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
- The festival tag matcher (`FestivalTagging`, which set a clip belongs to) still places a clip
  by `offsetSec`. It reads no heart rate.
- Inside the HR window of joined parts the chart is one stretch of the session and the dot moves
  through it at an even pace, so it runs slightly behind after a join. The window's start, end
  and numbers are right.
- A clip replaced before this change is still read as reverted (see "Clips replaced before this
  change").
- After a revert over a replaced clip the Studio clip's `baked` record (which project-wide items
  are in its pixels) is kept as the later bake left it. Items only the reverted bake burned stay
  hidden over that clip until it is baked again; the other way round would draw the replaced
  video's own items twice.
- **Cloud vault.** The vault uploads an asset's `.video` resource (the original) in preference to
  `.fullSizeVideo`. A "Save to original" clip restored on another phone can therefore carry a
  revertible map over an untrimmed original until the Studio is opened for that session (the
  check then finds no edited rendition and clears it).
- **The same asset in another session.** A bake updates the rows of the session it was made in.
  A row for the same asset in another session gets no map and no flag.

## Tests

`BakedClipHRTimeTests` (new). The heart-rate series is `bpm = 100 + t`, so a reading names the
second it came from.

- the map, pure: nothing trimmed, an end trim alone and a split with nothing removed store `nil`;
  a start trim; start and end trim; speed 0.5; speed 2 (also with nothing trimmed); two parts
  with a gap, with `captureTime` and `segmentIndex` on, before and after the boundary; parts out
  of recording order; a transition between parts; a second bake on top of a first (trim and
  speed, 2× on 2×, a bake that changes nothing); a second bake across a join.
- row updates, pure: "Save to original" keeps the offset and writes a revertible map; "Replace
  original" moves the offset and always stores a not-revertible record (the identity for a plain
  trim), with the same capture times before and after; what a found revert means for each kind
  of record; replace at 2×, save with a 5 s trim, revert: the row is back on the replaced
  record and 30 s read 60 s of heart rate; the stored JSON, a value without `revertsTo`, an
  unreadable value, `captureClock` and `reelStartSec` on the row.
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
  baked 2× clip reads 4 s over its 2 s. "Replace original": offset 12 and an identity record;
  with 2×, offset 12 and a map. A replaced clip (plain trim and 2×, scoped, with a burned tile)
  stays baked when the Studio asks Photos again: flag, `baked` record, map, offset and length
  stay, no tile in the Studio or an export, no feed overlay, raw share. A clip flagged with no
  record is still un-flagged. A revert over a replaced clip restores its record and the clip's
  length. A bake after an unseen revert: the first tap stops with the message, writes nothing to
  Photos and clears the stale map; the next save stores source start 5, not 25; the same bake
  with the first still in place stores 25. While a bake waits for Photos (the stand-in probe is
  held): close, export, a second bake and an edit are refused, and one bake comes out. An export
  waits for the check, stops with its message on a revert, and starts at once when nothing is
  baked. A check under a held export changes nothing, builds no preview, is owed, and runs when
  the export ends (the export's result stays). Three checks asked for at once are one task and
  one question to Photos. A reverted clip that is in iCloud only: the panel stands, its length
  is not read, it has its recorded length, and a save tap does nothing. An asset Photos does not
  know (the stand-in's default, as the app's probe answers on a simulator) clears nothing and
  blocks neither lane. `timeMap` with no parts drops an identity record and keeps a real map.
  The festival set row carries the flag and the map, read through the functions `openViewer`
  and `reelSource` call (`viewerInputs`, `reelClips`). A failing
  save: the flag, the length and
  the map are all on the row when the save is tried, nothing reaches the store, and the next save
  that works stores the three together.

`SnappetBackupTests`: the map survives a backup and a restore; the same file without the key
restores with no map. `ClipBakePlanTests`: `testEarliestTrimStart` is replaced by the same case
through the map. `StudioEditorStateTests`: the checking phase, pure (locks, what cannot begin
inside it, both endings for both lanes, when it cannot begin).

Each of the map tests fails if the map is ignored. The full unit suite was run. For the third
commit the editor's states changed, so `LiveWorkoutStudioWalkthroughTests` and `ClipsPostUITests`
were run too. No test asks the real Photos library: the probe is a stand-in everywhere.

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
6. "Replace original" with a start trim: the tile is on the right seconds. With 2×: the chart
   covers the whole effort. Close and open the Studio: the clip still shows BAKED in the feed,
   with no live overlay over the burned tile.
9. "Replace original", then "Save to original" with a further trim, then "Revert to Original"
   in Photos: the clip is the replaced video again and is still BAKED.
10. "Save to original", leave the Studio open, revert in Photos, come back, trim and "Save to
    original" again: the first tap says "This clip was reverted in Photos. Check it and save
    again." and saves nothing; the clip has its full length; the second save works and the
    tile is on the right seconds.
11. "Save to original" with a burned text or HR tile, leave the Studio open, "Revert to
    Original" in Photos, come back and do NOT save: without closing the Studio the clip has its
    full length again and the project's items are drawn over it again (the check ran on the
    return, inside the full-screen cover).
12. The same as 11 with "Optimise iPhone Storage" on and the original in iCloud only: the
    "Download clip" panel appears; nothing downloads until it is asked for.
13. The same as 11, but tap "Export as new video" right after coming back: either the message
    "This clip was reverted in Photos. Check it and export again." appears, or the export
    starts from the reverted clip. It never renders heart rate from the baked timing.
7. Back up, restore on the same phone, open a baked clip in the Studio: the tile is unchanged.
8. Install over a store from the build before this one: every clip is there and nothing about
   clips baked earlier has changed.
