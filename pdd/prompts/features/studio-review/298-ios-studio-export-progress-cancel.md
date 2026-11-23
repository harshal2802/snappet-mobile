# Prompt: A Studio export shows progress, can be cancelled, and cleans up its files

**File**: pdd/prompts/features/studio-review/298-ios-studio-export-progress-cancel.md
**Created**: 2026-11-23
**Project type**: iOS
**Chain**: from the 2026-11 Studio code review (the "Export as new video" lane); built on prompt 294
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Problem

A read-only review of the Studio found four faults in "Export as new video". All four were
confirmed by reading the code on `fix/studio-bake-flatten-294` (`5855c00b`). None has been
reproduced on a device.

1. **No progress and no cancel.** `StudioEditorViewModel.export()` awaited
   `StudioComposer.export(...)` and the view drew a spinner with "Exporting…". A long 4K export
   gave no sign of how far it was and could not be stopped.
2. **The render kept running after the Studio closed.** The Export menu started it with
   `Task { await vm.export() }`. Nothing held that Task, so nothing could cancel it. The export
   session ran to its end with the Studio gone.
3. **Temp files were never deleted.** The exported `.mp4` handed to the share sheet stayed in the
   temp directory. A failed render could leave a partial file. (The bake lane already deleted its
   own temp file.)
4. **A failed export could be invisible.** The message was drawn in the action bar. That bar is
   replaced by the overlay bar while a text or tag overlay is selected.

## Change

- `StudioComposer.export` takes an optional `progress` callback (main actor). It reads
  `AVAssetExportSession.states(updateInterval: 0.2)` in a watcher Task and reports
  `fractionCompleted`. `export(to:as:)` already cancels the session when the calling Task is
  cancelled; the function then throws `CancellationError`. On any throw it deletes the partial
  output file. It also checks for a cancel after the composition is built, before the session
  starts. The composition-building code is unchanged.
- `ExportShareState` (pure):
  - `.exporting` is now `.exporting(progress:)`;
  - `exportProgressed(_:)` takes a report only while exporting, keeps it in 0…1, never moves back;
  - `exportCancelled()` goes from exporting to idle and changes nothing else;
  - `shareDismissed()` and `failureAcknowledged()` return to idle;
  - `fileToDelete(movingTo:)` names the temp file the old state held and the new one does not;
  - `exportProgress` and `exportPercentLabel` feed the bar.
- `StudioEditorViewModel`:
  - owns the export Task (`startExport()`, `cancelExport()`, `studioClosed()`);
  - changes `exportState` in one place, which deletes the file `fileToDelete` names;
  - `isRendering` is still true for any exporting value, and also while a cancelled export has
    not yet stopped, so a second render cannot start beside it;
  - `renderComposition` passes the progress callback through; a bake passes none.
- `StudioEditorView`:
  - the preview shows a progress bar with the percent and a Cancel button
    (`studioExportProgress`, `studioExportCancel`);
  - a failed export is an alert ("Couldn't export"), like the bake lane's;
  - closing the share sheet deletes the exported file;
  - `onDisappear` cancels a running export and deletes the exported file.

Not changed: what is rendered, the quality presets, the bake lane (no progress bar, no cancel, same
"Saving to original…" indicator), the `studioExport` / `studioExportNew` identifiers.

## Tests

`ExportShareStateTests` (SnappetTests, no device):

- progress is reported only while exporting, stays in 0…1, never moves back, ignores NaN;
- a report that arrives after a cancel, a failure or a finish changes nothing;
- a new export starts at 0; the percent label rounds down;
- cancel returns to idle with no message; a cancel after the export ended keeps its result;
- closing the share sheet and closing the failure message return to idle;
- the exported file is named for deletion when the share sheet closes, a new export starts or the
  Studio closes; it is kept while a state still holds it; states with no file name nothing.

`ClipBakePlanTests` is run as well, because the bake lane shares the render.

## Owed on device

A real render cannot run on the simulator, so none of the following has been seen working:

1. Export a long project at 4K. The bar moves from 0 to 100% and the share sheet opens.
2. Tap Cancel half way. The bar goes at once, no message is shown, the Export button is usable
   again within a moment, and a new export works.
3. Start an export and close the Studio. The phone stops rendering (no heat, no battery drain;
   Instruments shows no export session).
4. Export, share to Messages, AirDrop and "Save Video", one after the other. Each one receives the
   whole video although the file is deleted when the sheet closes.
5. Check the app's temp directory (Xcode → Devices → download container) after steps 1–4: no
   `snappet-studio-*.mp4` is left.
6. Select a text overlay, then make an export fail (for example a clip whose iCloud original cannot
   be downloaded in Airplane Mode). The "Couldn't export" alert is shown.
7. Opening the share sheet or a tool sheet does not cancel a running export (the Studio's
   `onDisappear` must not fire for a sheet shown over it).
8. "Save to original" still shows "Saving to original…" and still works.
