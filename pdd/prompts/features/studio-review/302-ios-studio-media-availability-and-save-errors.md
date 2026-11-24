# Prompt: The Studio shows missing clips and reports a failed save

**File**: pdd/prompts/features/studio-review/302-ios-studio-media-availability-and-save-errors.md
**Created**: 2026-11-23
**Project type**: iOS
**Chain**: from the 2026-11 Studio code review; built on prompt 301 (the editor's one state)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Problem

A read-only review of the Studio reported two faults. Both were checked against the code on
`studio-301-editor-state` (after prompt 301). Neither has been reproduced on a device.

1. **A clip that is not on the phone was handled without a word.** The review said Photos assets
   are requested with `isNetworkAccessAllowed = false`. **That part is no longer true:** since
   prompt 265 `StudioComposer.avAsset` allows the network. The rest of the finding stands, and
   allowing the network made part of it worse:
   - a clip that is only in iCloud is downloaded inside "Building preview…", with no progress, no
     cancel and no word about why the Studio is waiting (also once more for its duration when the
     Studio opens);
   - if the download fails (no network), or the video was deleted from Photos, the composer skips
     the clip. The preview and the export are shorter, or there is no preview at all, and the
     timeline still shows the clip. On a phone the only text was "Preview renders on a device",
     which is the simulator's message.
2. **A failed save was silent.** Every save was `try? context.save()`. That includes the save at
   the end of a bake, after "Replace original" has already deleted the original video: the bake
   then reported "Saved to original" although the project had not been updated.

## Change

- **`StudioMediaAvailabilityService`** (new, `Services/`, device edge). For a list of Photos
  identifiers it reports per asset: on this phone / in iCloud / missing. It asks Photos for the
  video with the network off: an asset back means it is here; nothing back with
  `PHImageResultIsInCloudKey` means iCloud; an identifier Photos does not return means missing
  (deleted, or outside what the user lets Snappet see). It can download an iCloud video with
  progress, and the download is cancelled with the calling Task. It makes the same request the
  composer makes, so what it downloads is what the composer opens. On the simulator it reports
  everything as available, so the simulator keeps its own placeholder. `StudioComposer` is unchanged.
- **`StudioMediaPlan`** (new, pure). From the timeline's sources (visible video clips, then
  picture-in-picture sources) and their statuses: the problems, how many clips are ready, the
  panel for the first problem (title, message, whether Download and "Preview without it" are
  offered, download progress, error), why export is off, and the state after each choice
  (download began / progressed / finished / failed / cancelled, clip removed, preview without it,
  back to the choices). `StudioPreviewGaps` maps the playhead between the timeline and a preview
  that leaves clips out.
- **`StudioEditorState`**: a `clipMissing(panel)` phase (editing allowed, no play, no export),
  `exportBlockedReason`, a `saveFailure`, and the bake result `savedProjectNotUpdated`.
- **`StudioEditorViewModel`**:
  - asks the service first when the Studio opens, and only resolves durations for clips that are
    on the phone;
  - `rebuildPreview` does not call the composer while a missing clip waits for a decision, and
    hands it only the available clips in "Preview without it";
  - `downloadMissingClip`, `cancelClipDownload`, `previewWithoutMissingClips`,
    `showMissingClipOptions`, `removeMissingClip` (the normal undoable delete; a
    picture-in-picture source removes its overlay);
  - one `persist()` that does `try` and reports a failure through the state; the edit stays in
    memory and in undo; the next save that works clears the message. `reconcileBakedFlags` saves
    through the same path;
  - `bake()`: if the save after the Photos write fails, the result is `savedProjectNotUpdated`,
    not `saved`. What the bake writes is unchanged;
  - bake is not offered, and a clip is not offered as a picture-in-picture source, while a clip is
    not on the phone.
- **`StudioEditorView`**: the panel in the preview area ("Clip 2 is in iCloud" · Download clip ·
  Preview without it · Remove clip from video; a progress bar with Cancel while it downloads);
  "Export needs all clips" beside the disabled Export button; a line over a preview made without
  a clip, which opens the choices again; a save-failed message with a close button; an alert for
  the bake whose project was not updated. "Preview renders on a device" is now shown on the
  simulator only; a phone says "The preview couldn't be made".
- **`StudioTimelineView`**: a clip that is not on the phone is marked "iCloud" or "Missing" (dashed
  outline, and in its VoiceOver label).

New identifiers: `studioMissingClipPanel`, `studioClipDownload`, `studioClipDownloadProgress`,
`studioClipDownloadCancel`, `studioClipDownloadError`, `studioClipPreviewWithout`,
`studioClipRemove`, `studioMissingClipNotice`, `studioExportBlockedReason`, `studioSaveError`,
`studioSaveErrorDismiss`. No existing identifier changed.

Not built: checking again while the Studio stays open (a video deleted in Photos with the Studio
open is noticed the next time it opens); downloading all missing clips at once; photos (the
composer does not render photo clips).

## Tests

`StudioMediaPlanTests` (SnappetTests, no device):

- pure plan: all available; a clip in iCloud (title, message, counts, export reason); a deleted
  clip (different words, no Download); the only clip cannot be previewed without; a
  picture-in-picture source; preview without it; download progress never moves back and ends with
  the clip available; a failed download says so and a cancelled one does not; removing the clip
  and undoing it; several problems one at a time;
- pure gaps: the playhead across one and several left-out clips, and none;
- pure state: `clipMissing` allows editing and refuses play, export and bake; a failed save is
  shown until closed or a save works; a bake whose project save failed is not `saved`;
- view model with a stand-in service: the phase, the timeline status, export / bake / PiP not
  offered; remove is undoable; preview without it; download ends the phase; a failed download is
  reported and a cancelled one is not; a failed save is reported, the edit is kept, and the next
  good save clears the message.

Also run: `StudioEditorStateTests`, `ClipBakePlanTests`, `ExportShareStateTests`,
`StudioUndoGestureTests`, `StudioEntryTests`, `StudioProjectEditorTests`, `StudioGeometryTests`.
The UI suite was not run.

## Owed on device

The service's Photos code is compiled out on the simulator, so **none of it has run**:

1. A project where one clip is only in iCloud (Settings → Photos → Optimise iPhone Storage, an old
   video). Open the Studio: the panel says "Clip N is in iCloud", the clip is marked "iCloud" on
   the timeline, Export is off with "Export needs all clips", and the other clips are **not**
   reported as in iCloud.
2. Tap Download clip. The bar moves, and at the end the preview is made with every clip. Check
   that the composer then opens the clip without a second wait (the download is the same request).
3. Start the download and tap Cancel. The bar goes, no message is shown, and Download works again.
4. Start the download and turn on Airplane Mode. The panel says the clip couldn't be downloaded.
   Turn Airplane Mode off: Download works.
5. Open the same project in Airplane Mode: the clip is reported as in iCloud (not as missing).
6. Tap "Preview without it". The preview plays the other clips, the line "Clip N is not in this
   preview" is shown, Export stays off, and the playhead on the timeline jumps over the missing
   clip's strip while playing. Scrub into the missing clip's strip: the preview shows the first
   frame after it. Tap the line: the panel is back.
7. Delete a clip's video from Photos, then open the project. The panel says "Clip N can't be
   found", there is no Download, and the clip is marked "Missing". Tap "Remove clip from video":
   the preview is made, Export works, and Undo brings the clip and the panel back.
8. With "Limited access" to Photos and a clip outside the selection: reported as "can't be found".
9. A picture-in-picture whose source is in iCloud: the panel names a picture-in-picture clip, and
   "Remove picture-in-picture" removes the overlay.
10. A slow-motion or edited video that is on the phone is **not** reported as in iCloud or missing.
11. A project with every clip on the phone opens as fast as before (the check asks Photos once per
    clip before the composer does).
12. The scoped Studio ("Edit this clip") on a clip in iCloud: "This clip is in iCloud".
13. "Save to original" is not in the Export menu while a clip is in iCloud.
14. A failed save cannot be forced on a device without a debugger; the unit test covers it. If the
    store is ever read-only (disk full), check that the message appears and goes after freeing space.
