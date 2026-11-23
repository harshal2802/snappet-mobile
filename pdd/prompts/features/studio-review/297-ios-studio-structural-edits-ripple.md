# Prompt: Splitting and shortening a Studio timeline carry transitions and overlays with them

**File**: pdd/prompts/features/studio-review/297-ios-studio-structural-edits-ripple.md
**Created**: 2026-11-23
**Project type**: iOS
**Chain**: from the 2026-11 Studio code review; built on prompt 294
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Problem

The review found three faults in what happens to transitions and overlays when the timeline changes
shape. All three were confirmed by reading the code on `5855c00b`. None has been reproduced on a
device.

1. **A split left the transition between the two halves.** A transition is keyed `afterClipID` and
   means "between this clip and the next". `StudioProjectEditor.splitClip` kept the original id on
   the first half and did not touch the transitions. The dissolve that led out of the clip then
   played in the middle of it, and the second half cut to the next clip.
2. **Overlays could outlast the timeline.** Text, stickers and picture-in-picture store absolute
   times. After a trim, a speed change, a delete or a split the timeline can end before them.
   - Picture-in-picture: `StudioComposer.insertPiPTrack` inserts the track at the stored time with
     no upper limit, so the composition became longer than its clips (a tail with no main video),
     in the preview and in the export.
   - Text and stickers: the export already limits them to the composition length, so the file was
     right. One that started after the end became a zero-length window on the last frame.
   - Climb tags bound to a clip were not affected: their window comes from the clip's slot.
3. **`OverlayBar` never read its `total` parameter.** It was unused from the commit that added the
   lane (`b728bdda`). A bar could be dragged anywhere past the end of the video, and nothing showed
   that part of a window would not play.

## Change

- `StudioProjectEditor.splitClip` re-keys the transition that led out of the split clip to the
  second half. The halves join with a cut. The transition into the clip is keyed to the clip
  before it and is not touched.
- `StudioGeometry` (pure) gets:
  - `clampedWindow(start:end:total:)` — a window cut to `[0, total]`; `nil` when it starts at or
    after the end; unchanged when the length is not known (`nil` or `≤ 0`);
  - `clampedToTimeline(_:total:)` — the same for a list of overlays, leaving out the `nil` ones;
  - `playedFraction(start:end:total:)` — the share of a stored window that plays;
  - `overlayWindow(dragging:bySeconds:start:end:total:)` — the window a bar drag asks for;
  - `minOverlayWindowSec` (0.2), now also used by `setOverlayTimeRange`.
- `StudioEditorViewModel.renderedOverlays(_:)` passes its result through `clampedToTimeline` with
  the visible timeline's length. The canvas, the preview and the export all read it. Stored times
  are not changed, so undoing or lengthening restores the window.
- `OverlayBar` uses `total` as the end of the timeline. The bar still covers the stored window; the
  part past the end is dimmed. A move keeps at least 0.2 s inside the timeline. The end handle
  cannot be dragged past the end; an end that is already past it is not pulled back unless it is
  dragged earlier. A tag bound to a clip on the timeline gets no limit.

Not changed: `removeClip`, `moveClip`, the composer, the overlay canvas, export and bake code, the
stored model.

## Checked and left as it is

- **Reorder.** A transition stays keyed to its clip and travels with it. That matches the editor,
  which sets a transition on the selected clip as the way that clip is left.
- **Last clip.** `StudioGeometry.timeline` ignores a transition on the last clip (it needs a next
  clip). It stays stored and applies again if a clip is added or moved after it.

## Open

1. **A stored transition that does not apply still chooses the composer path.**
   `StudioComposer.assemble` (and its mirror `ClipBakePlan.rendersMusic`) takes the transition path
   when any stored transition is not `.none`. That includes one on the last clip, and one keyed to
   a clip hidden by the "Edit this clip" scope. The transition path does not mix added music. So a
   project with one unused transition exports without its music. The fix is to pass only the
   transitions that apply to the composer; that is composer and view-model code outside this job.
2. **Remove.** `removeClip` drops the transition out of the removed clip. The transition into it
   (keyed to the clip before) stays and now leads to the clip after. Reasonable; not changed here.
3. **A split leaves the climb tag on the first half only.** The tag is bound to the original id.
   The second half has no tag until one is added.
4. **The lane draws a bound climb tag at its stored times**, which can differ from the clip's slot
   after a trim or reorder. The render uses the slot. Dragging that bar changes stored times that
   the render does not read.
5. **The composer keeps a 0.1 s minimum for a picture-in-picture window.** One that starts less
   than 0.1 s before the end can still make the composition up to 0.1 s longer.
6. **A selected overlay that starts after the end is not on the canvas** (the canvas reads the
   rendered list). It is still in the lane, dimmed, and can be dragged back.
7. **No VoiceOver wording for the dimmed part of a bar.**
8. **Added music** has its own absolute `startSec`. The composer already limits it to the
   composition length. Not reviewed further.

## Tests

`StudioProjectEditorTests` and `StudioGeometryTests` (SnappetTests, no device):

- a split moves the outgoing transition to the second half, keeps its kind and length, and leaves
  the timeline the same length; the incoming transition is untouched; a split that does nothing
  changes nothing;
- a moved clip keeps its transition, and on the last clip the layout ignores it;
- a window is cut to the timeline, dropped when it starts at or after the end, and left alone when
  the length is not known; a list of overlays keeps everything else about each overlay;
- the played share of a bar; move, start-handle and end-handle drags against the end;
- through the view model: after a trim from 10 s to 5 s the text ends at 5, the picture-in-picture
  that starts at 6 is left out, the stored times are unchanged, and undo restores all three.

## Owed on device

1. Two clips with a dissolve between them. Split the first. The dissolve is still between the
   second half and the next clip; the halves cut.
2. A 10 s clip with a picture-in-picture from 6 to 10 s. Trim the clip to 5 s. The preview and the
   export are 5 s long. Undo: the picture-in-picture is back.
3. Text from 2 to 9 s on the same clip, trimmed to 5 s: the bar is dimmed after 5 s; its end handle
   cannot be dragged past the end; the bar cannot be dragged off the end.
