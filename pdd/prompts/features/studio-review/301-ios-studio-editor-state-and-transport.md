# Prompt: The Studio editor has one state and reads play/pause from the player

**File**: pdd/prompts/features/studio-review/301-ios-studio-editor-state-and-transport.md
**Created**: 2026-11-23
**Project type**: iOS
**Chain**: from the 2026-11 Studio code review; built on prompts 294 (bake lock), 298 (export
progress and cancel) and 299 (one undo step per drag)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Problem

A read-only review of the Studio found four faults in how the editor keeps track of itself. All
four were confirmed by reading the code on `studio/299-undo-one-step-per-gesture` (`2d8defff`).
None has been reproduced on a device.

1. **The play button was a remembered wish.** `isPlaying` was a Bool set by `play()` and `pause()`.
   Nothing compared it with the `AVPlayer`. After a phone call, a stall, or an item that failed,
   the player had stopped and the button still showed "pause".
2. **A failed preview left things behind.** When `rebuildPreview` could not make a preview it set
   the player to `nil` and nothing else: `isPlaying` kept its value, the time observer was never
   removed (it was removed through the player property, which was already `nil`), and the playhead
   could sit past the end of a timeline that had become shorter.
3. **A scrub during a rebuild was undone.** `rebuildPreview` read the playhead before it awaited
   the new composition and seeked back to that value afterwards. A scrub made in between was lost.
   The same was true of a pause: "was playing" was also read before the await.
4. **The editor's condition was spread over loose flags.** `isBuildingPreview`, `previewError`,
   `previewPlayer == nil`, `exportState`, `bakeState`, `isBaking`, `isRendering`, two optional
   selection ids, and nine `@State` sheet flags in the view. Combinations that make no sense could
   be written down (a clip and an overlay both selected; two sheets open). An export did not lock
   editing, although the agreed design says it does.

## Change

- **`StudioEditorState.swift`** (new, Foundation only):
  - `StudioEditorState` is one value with a reducer, `reducing(_:)`, over `Event`. It holds the
    selection, the export lane (`ExportShareState`), the bake lane (`StudioBakeState`), whether the
    export task is still alive, the preview's load state, and the player's status.
  - Derived: `phase` (loading · ready · rendering(export with progress | bake) ·
    finished(exported file | saved to original)), `isBaking`, `isRendering`, `canEdit`, `canPlay`,
    `canExport`, `canClose`, `lockReason`.
  - The reducer refuses a second render, a render before the first load, a late result after a
    cancel, and dismissing a bake that is still running.
  - `StudioSelection`: none · clip(id) · overlay(id).
  - `StudioTransport`: what the play button shows for a player status, when the playhead follows
    the player's clock, where a rebuilt preview resumes, whether it resumes playing.
  - `StudioEditorSheet`: the one sheet or dialog open over the editor. `StudioTool` moved here.
- **`StudioEditorViewModel`**:
  - holds `state` and changes it in one place, `send(_:)`, which also deletes the exported temp
    file the old state held (prompt 298's rule, unchanged);
  - `exportState`, `bakeState`, `isBaking`, `isRendering`, `isBuildingPreview`, `previewError`,
    `isPlaying`, `selectedClipID`, `selectedOverlayID` are still there, now read from `state`;
  - every edit path checks `canEdit`, so an export locks editing as a bake does;
  - `startExport` and `bake` need `canExport` (no render in flight, first load done) and pause the
    preview;
  - transport: observes the player's `timeControlStatus`, the item's `status`, its end and its
    failure, and copies the player's real status into the state. `play()` and `pause()` also read
    it back at once. The observers are removed from the player they were added to;
  - a failed preview, and an item that fails while playing, go through one `teardownPlayer()`:
    observers removed, player stopped and dropped, status paused, playhead inside the timeline;
  - a rebuilt preview resumes at the position and the play status **at the moment of the swap**.
- **`StudioEditorView`**:
  - one `@State presented: StudioEditorSheet?` replaces nine sheet / alert / dialog flags. The
    three result alerts (bake saved, bake failed, export failed) are independent and unchanged;
  - while a render runs the transport, the timeline and the tool bars are dimmed and disabled, the
    canvas does not take touches, and one line says "Editing is locked while exporting" (or
    "…while saving to the original"), identifier `studioLockedNotice`. The export's progress bar
    and Cancel (prompt 298) stay usable and gained the line "Keep Snappet open until this
    finishes." The bake indicator is unchanged;
  - Close is disabled only during a bake. Export is disabled while a render is in flight and until
    the first preview has loaded.

Not changed: what is rendered, what a bake writes, the sheets themselves, every accessibility
identifier, `setOverlayOpacity` and `endGesture` (another change owns them).

### Behaviour that changed on purpose

- **An export locks editing.** Before, the project could be edited under a running export.
- **Selecting an overlay deselects the clip.** Before, both ids could be set, and "Done" on the
  overlay bar returned to the clip that was still selected underneath. Now it returns to no
  selection. A climb tag's "Show setter" and "Attempt #" read the tag's own clip instead.
- **The preview is paused when a render starts.**

## Tests

`StudioEditorStateTests` (SnappetTests, no device):

- pure: the phase and the four permissions in every phase; a rebuild after the first load is not
  "loading"; one render at a time; a cancelled export blocks a new render until its task ends;
  late events change nothing; closing the Studio drops the export; the play button for each player
  status; the player status is mirrored only while there is a player; the resume position and
  resume-playing rules; the selection and presentation values;
- view model (in-memory store): no export before the first load, but edits work; every edit path
  refuses while an export renders and works again after a cancel; a bake still locks and is the
  only thing that blocks closing; the selection is one value; with no player nothing is "playing"
  and the playhead stays inside the timeline.

Also run, because they share the view model: `ClipBakePlanTests`, `ExportShareStateTests`,
`StudioUndoGestureTests`, `StudioEntryTests`, `StudioProjectEditorTests`, `StudioGeometryTests`.

The UI suite was not run. Every identifier it uses (`studioExport`, `studioPlayPause`,
`studioQuality`, `studioSplit`, `studioUndo`, `studioClose`, `studioPreview`, `studioActionBar`,
`studioHRTool`, `timelineClip`) is still there, and the simulator placeholder text is unchanged.

## Owed on device

A real player cannot run on the simulator (no Photos assets), so none of this has been seen working:

1. Play, then take a phone call (or start a timer alarm). The button shows "play" when the sound
   stops, and tapping it plays again.
2. Play a clip whose original is in iCloud on a slow network so it stalls. The button keeps
   showing "pause" while it waits, and tapping it stops the attempt.
3. Play to the end. The button shows "play", the playhead is at 0, and Play starts from the top.
4. Make an edit that rebuilds the preview (a trim) and scrub while "Building preview…" could
   still be running. The playhead stays where the scrub left it.
5. Play, make an edit: playback continues across the rebuild. Pause during the rebuild: it stays
   paused.
6. Make a preview fail (for example delete the only clip's video from Photos, then trim). The
   placeholder is shown, the button shows "play" and is disabled, and the next edit that can make
   a preview brings the player back.
7. Start an export. The transport, the timeline and the tool bars dim, the line "Editing is locked
   while exporting" is shown, nothing on the canvas can be dragged, Cancel works, and Close closes
   the Studio and stops the export.
8. Start "Save to original". The same lock is shown with "…while saving to the original", and
   Close is disabled until it ends.
9. Open each sheet and dialog once (Speed, Volume, Filter, Adjust, Transition, Canvas, HR, Grid,
   text style, Add text, Rename, Edit text, Music, PiP, Replace original, Share): each opens and
   closes as before.
10. VoiceOver: the play button reads "Pause" while playing and "Play" after an interruption.
