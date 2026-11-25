# Prompt: Review fixes for the Studio compositor, editor state and missing media

**File**: pdd/prompts/features/studio-review/303-ios-studio-review-fixes-300-302.md
**Created**: 2026-11-24
**Project type**: iOS
**Chain**: an independent review of prompts 300, 301 and 302 (PRs #489–#491), before the plan in
`PLAN.md` starts. Built on `studio-v2`.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Problem

The review found no important defect. It found the twelve below. Each was confirmed by reading the
code on `studio-v2` (`a98fd6ce`) before it was changed. None has been reproduced on a device.

1. **A clip that is not on the phone could be 0 s long.** The Studio reads a clip's length only
   when its video is on the phone. A clip with no stored trim end then had no length at all: an
   8-point sliver on the timeline, left out of the total, and no gap in "Preview without it". A
   trim on it stored `trimEnd = 0`, and that stayed after the video was downloaded. How narrow
   this is: a new clip gets its trim end from the recorded length, so the case is a clip whose
   media row has no recorded length, or a clip that was baked (a bake clears the trim).
2. **The opening Studio said "The preview couldn't be made".** The text looked at
   `isBuildingPreview`, which is false until the first build begins.
3. **An edit in the opening window started a preview build** before the availability check had
   answered. The composer then downloaded an iCloud clip without a word, which prompt 302 removed.
4. **A download's error was not tied to its clip.** After the failed clip was removed, the next
   problem's panel opened already showing the error.
5. **A clip shorter than its two transitions ended at full volume**: its fade-out was dropped.
6. **Two heart-rate tiles were drawn on top of each other for the length of every transition**,
   because each clip's tile was shown over its whole slot and the slots overlap there.
7. **"Preview without it" showed a picture-in-picture late.** Its window is in timeline time; the
   shorter preview needs it moved across the left-out clip, as the playhead is.
8. **A late clock tick could overwrite a seek.** After playing to the end the playhead could rest
   at the end instead of 0, and it could flick to 0 when a preview was rebuilt while playing.
9. **Tests that passed with the feature broken.** Two view-model tests checked "export is off"
   before any preview had loaded, when export is off anyway. One render-plan assertion sat inside
   an `if let` that could be skipped. Nothing ran `bake()` with a failing save. Nothing rendered a
   clip with a speed change and sound, or three clips sharing an audio track. The rebuild-count
   test counted through observation callbacks and sleeps.
10. Small: a failed save at the end of a bake showed the bake alert **and** the save banner;
    download progress could land on the next download's bar; a picture-in-picture wholly past the
    end of the timeline counted as a source and could block the export.
11. **After a bake the preview kept the old video.** Nothing dropped the clip's stored length or
    the composer's opened asset, so until the Studio was reopened the clip had its length from
    before the bake and, after "Save to original", the pictures from before it.
12. **A bake could re-point the project and not the media rows.** The rows were fetched with
    `try?` after the Photos write; an empty or failed fetch still ended as "Saved".

All twelve were real. None was skipped.

## Change

Pure decisions (Foundation and CoreGraphics only, unit-tested):

- **`StudioGeometry`**
  - `timelineSourceDurations`: the lengths the timeline is laid out with — the real length where
    it has been read, else the recorded one, for the clips the caller allows to fall back.
  - `trimSourceLength`: the length a trim is measured against (real, else recorded, else the
    clip's own trim end), or `nil` when none is known.
  - `ownedWindows` / `ownerIndex`: the stretch of the output each clip owns. It is the clip's
    slot, with every transition split at its middle. No moment has two owners; none has none.
- **`StudioRenderPlan`**
  - `audioFades`: when a clip's two transitions meet, the shared stretch is split in the middle,
    so the clip rises and then falls to silence.
  - each placed clip carries `ownedStartSec` / `ownedEndSec`.
- **`StudioMediaPlan`**
  - `isChecked`: the service has reported at least once.
  - `DownloadFailure`: the message with the clip it belongs to. The panel shows it only for that
    clip, and it goes when that clip is no longer a problem.
  - a download has a request number, and a progress report carries one; a report from another
    download is ignored.
  - `sources(clips:overlays:total:)`: a picture-in-picture that starts at or after the end of the
    timeline is not a source.
  - `StudioPreviewGaps.playable(_:unavailable:)`: the project as the composer gets it for
    "Preview without it" — unavailable clips and picture-in-picture sources left out, and every
    timeline time (overlay windows, picture-in-picture opacity keyframes, music start) moved with
    `playerTime(forTimelineTime:)`, the playhead's own mapping.
- **`StudioEditorState`**
  - `showsBuildingPreview` (the `loading` phase, or a build in flight) and `canBuildPreview`
    (the first availability result is in).
  - `StudioSeekGate`: each seek gets a number; a clock tick moves the playhead only when the
    latest seek has finished.
  - a bake that ends as `savedProjectNotUpdated` clears the save banner.
  - `StudioBakeState.recordsUnreadableMessage`.

Device edge and view model:

- **`StudioEditorViewModel`**
  - loads each video's recorded length with the capture offsets, and uses it on the timeline for
    a clip that is not on the phone. The composer is still handed real lengths only.
  - `trimSelected` refuses while the length is not known; `canTrim` hides the trim handles.
  - `rebuildPreview` returns at once until `canBuildPreview`; the opening builds the preview
    right after the first result, from the project as it is then.
  - the availability check asks about every picture-in-picture source, also one past the end.
  - `seek` opens a seek in the gate and closes it in the player's completion handler; the clock
    observer checks the gate.
  - the clip under the playhead (preview tile, HR-window sliders) is the clip that owns the
    moment, the same rule the export uses.
  - `bake()`: reads the `SessionMedia` rows first and refuses with a message if there are none;
    afterwards drops the baked clip's stored length and aspect, tells the composer to forget the
    asset, and reads the length again before the preview is rebuilt.
  - rebuilds go through one `scheduleRebuild()`, which keeps its tasks so a test can wait for
    them; `previewBuildCount` counts builds.
  - three seams for tests, all `nil` in the app: `sourceDurationLoader`, `renderOverride`, and
    the `ClipBaking` protocol for the bake's two Photos writes.
- **`StudioComposer`**: `forget(localIdentifiers:)`; each clip's HR tile is handed its owned
  stretch.
- **`StudioOverlays`**: `PlacedClipHR` has an optional visible stretch. The tile's values and
  chart still run over the clip's whole slot; only when it is shown changes.
- **`StudioEditorView`**: the empty preview's text reads `showsBuildingPreview`.
- **`StudioTimelineView`**: trim handles and the VoiceOver trim actions need `canTrim`.

### Behaviour that changed on purpose

- During a transition the export shows one HR tile: the outgoing clip's for the first half, the
  incoming clip's for the second. The preview's tile and the HR-window sliders change clip at the
  same moment (they used to change at the end of the transition).
- An edit made while the Studio is still opening does not start a preview; the opening's own
  build shows it.
- A never-trimmed clip whose length is not known cannot be trimmed until it is.

### Follow-ups from the second review (same PR, second commit)

- **"Save to original" records the rendered length.** `ClipBakePlan.revertibleMediaUpdate` sets
  `SessionMedia.durationSec` to the rendered length (a 60 s clip trimmed to 10 s, baked and later
  moved to iCloud showed 60 s on the timeline). The capture offset does **not** move for this
  variant; see `decisions.md`. When a "Revert to Original" is found, the recorded length becomes
  the asset's own again (`ClipBakePlan.revertedDuration`, `ClipBakeService.currentDuration`).
- **A stored end is never an estimate.** A trim of the start alone leaves `trimEnd` as it was
  (none stays none), and the second half of a split keeps the clip's own `trimEnd` (none stays
  none). Before, both stored the length they were clamped against, which can be the recorded
  length of a video that is not on the phone.
- **No HR tile for a clip that owns no stretch.** `StudioComposer.placedHR` (the tiles the export
  hands the overlay tool, now one function) leaves such a clip out, and
  `StudioOverlays.hrTileLayer` returns no layer for an empty window (`tileIsShown`). The empty
  window used to pulse for the length of the gate's edges.
- **`ownedWindows` with crossed middles.** When a clip's two boundaries cross, it owns nothing and
  its neighbours meet at one point. `StudioGeometry.timeline` cannot produce such slots today (a
  transition is no longer than either clip); the rule no longer depends on that.
- **The availability question has a time limit.** `StudioAvailabilityProbe` (pure): the four
  answers and the status each gives; no answer within 4 s counts as available, like "no reason".
  `StudioFirstAnswer.wait` (no Photos): one answer from a callback, or the fallback after the
  limit, resumed once; the request is cancelled when the limit wins.
- **Seams for the tests:** `useStandInPlayer(seek:)` (acts as a built preview whose player plays,
  with the given seek), `playerClockTicked` (the clock observer now calls it), `composer` is
  readable, and `StudioComposer.remember` / `hasOpened`.

## Not done

- A "Save to original" bake does not move the capture offset, so an HR tile added in the Studio
  to an already baked, start-trimmed clip is sampled from the original's start (earlier by the
  trimmed length). Moving it needs the old offset stored for a revert: a new model field.
- In "Preview without it", music that started before a left-out clip does not skip that clip's
  length (there is no source offset to move).
- A short clip that lies wholly under both of its transitions owns no stretch, so its own HR tile
  is never shown; its neighbours' tiles meet in the middle.

## Tests

`StudioMediaPlanTests`

- pure: a download error stays with its clip and goes when the clip is removed; a late progress
  report does not move the next download's bar; a picture-in-picture past the end is not a
  source; nothing may be built before the first availability result, and the opening text is not
  the failure text; a bake whose save failed shows one message; "Preview without it" moves
  picture-in-picture windows, their keyframes and the music start with the playhead's mapping.
- view model, fixed: the two "export is off" tests now run the whole opening first, check that
  the preview has loaded, try `startExport`, and the first one also opens the same project with
  every clip on the phone and checks that it **can** export.
- view model, new: a clip in iCloud has its recorded length until it is downloaded, then its real
  one; a trim is refused while the length is unknown and works after the download; an edit before
  the availability result builds no preview (the check is held by a gate); a picture-in-picture
  past the end does not block export, and does once it is moved inside; bake is not offered and
  refuses while the clip is in iCloud; a bake with a save that fails ends as
  `savedProjectNotUpdated` for both variants, with no save banner; after a bake the clip's length
  is read again; a bake is refused, with nothing rendered or written, when the video has no rows.
- follow-ups: the bake fixture renders a real 1 s video and the stand-in reader then reports
  1.5 s, so the length after the bake can only come from the second read (`refreshing:`), and the
  composer is given an opened video first, which must be gone after the bake (`forget`); the
  recorded length is the rendered one and the offset stays (moves by the trim start for "Replace
  original"); a baked clip later in iCloud has its baked length; a start-only trim and a split
  against the recorded length store no end; a clock tick before the seek has finished does not
  move the playhead (through `useStandInPlayer`), also with two seeks in a row; the four probe answers;
  `StudioFirstAnswer.wait` with an answer, with none (fallback, cancel called), and with a late one.
  The unused view model in the picture-in-picture test is gone.

`StudioRenderPlanTests`: the short-middle-clip test asserts its fades unconditionally (up over
3…3.5, down over 3.5…4); the fade rule by itself; owned stretches (back to back, inside each
slot, the editor's owner rule, the export's tile gate); timeline lengths and the trim length.
Follow-ups: a short middle clip under transitions of different lengths; slots whose middles
cross; the `PlacedClipHR` values the composer builds are the owned windows, and a clip that owns
nothing has none.

`StudioProjectEditorTests`: a split of a clip with no stored end. `ClipBakePlanTests`: the
"Save to original" update and the length after a revert.

`StudioEditorStateTests`: the seek gate.

`StudioCompositorRenderTests`: a 2× clip with sound (source 2 s on the output in 1 s, no mix) and
a ½× clip at half volume; three clips with two transitions reuse one audio track, with each
clip's own level and fades on it; the rebuild-count test counts with `previewBuildCount` and
waits with `previewBuildsFinished`, no sleeps.

The full unit suite was run. The UI suite was not: no identifier changed.

## Owed on device

Nothing here was run on a phone.

1. A baked clip (or any clip with no stored trim end) whose video is only in iCloud: its strip on
   the timeline has its real width, the total includes it, and "Preview without it" jumps over
   it. After Download the width is still right.
2. Open the Studio on a slow phone: the empty preview says "Building preview…", never "The
   preview couldn't be made", before the first preview shows.
3. Open a project with an iCloud clip and make an edit at once (tap a clip, change the speed).
   The panel "Clip N is in iCloud" appears and nothing is downloaded until Download is tapped.
4. Two clips in iCloud. Download the first in Airplane Mode (it fails), then "Remove clip from
   video". The panel for the next clip opens with no error text.
5. Three clips, the middle one about a second long, a dissolve on both sides, all with sound: no
   jump in loudness when the middle clip ends.
6. An export with the HR tile and a one-second dissolve between two clips: one tile at every
   moment; it changes clip in the middle of the dissolve. The preview's tile changes at the same
   moment.
7. "Preview without it" with a picture-in-picture that starts after the missing clip: it appears
   when the playhead reaches its bar on the timeline.
8. Play to the end: the playhead is at 0 and the button shows "play". Play again, and trim a clip
   while it plays: the playhead does not flick to 0.
9. Scrub quickly while playing: the playhead follows the finger and then the player; it never
   stops following (the seek gate depends on the player always reporting that a seek ended).
10. "Save to original" on a trimmed clip: when the alert closes, the timeline shows the new,
    shorter clip and the preview plays the baked video. The same for "Replace original".
11. Start a download, cancel, start again: the bar starts at 0.
12. A picture-in-picture moved past the end of the timeline, with its source in iCloud: Export is
    on. Drag it back inside: the panel appears.
13. "Save to original" on a trimmed clip, then "Revert to Original" in Photos, then open the
    Studio: the clip has its full length again (the reverted length is read from Photos; the
    simulator cannot run this).
14. The time limit of the availability question is only compiled for a phone
    (`StudioMediaAvailabilityService.localStatus`); the Studio opens as before with clips on the
    phone and in iCloud.
