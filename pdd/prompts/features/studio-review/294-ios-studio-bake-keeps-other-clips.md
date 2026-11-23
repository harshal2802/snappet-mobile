# Prompt: "Save to original" removes only what it rendered, and locks the project while it renders

**File**: pdd/prompts/features/studio-review/294-ios-studio-bake-keeps-other-clips.md
**Created**: 2026-11-23
**Project type**: iOS
**Chain**: first fix from the 2026-11 Studio code review (findings 1–3 of 13); follow-up to prompt 117
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Problem

A read-only review of the Studio found three faults in the bake lane ("Save to original" and
"Replace original", prompt 117). All three were confirmed by reading the code on main `e9b77959`.
None has been reproduced on a device.

1. **Edits made during a bake were lost or reset.** Only the Export menu was disabled while a bake
   rendered. `bake()` read `undo.current` after the render, then awaited the Photos write (for
   "Replace original" that includes the iOS deletion dialog), then replaced the undo stack with
   that copy. An edit made during the render was treated as if it were in the pixels: a trim was
   reset to zero, a new text overlay was deleted. An edit made during the Photos write was thrown
   away. The capture-offset shift was computed from the clips as they were after the render.
2. **A bake of one clip wiped the other clips.** One Studio project is shared by a whole session,
   and "Edit this clip" opens it scoped to one clip. The bake is offered in that scope (a hidden
   clip of another asset does not block it), but the flatten ran on the whole project:
   `overlays.removeAll { $0.kind != .video }` and `hrOverlay = nil`. Every other clip lost its
   climb tag and its text, and the session lost its HR tile.
3. **A bake of the whole project left rendered things behind.** Picture-in-picture overlays, added
   music and the base frame stayed in the project, so the next export applied them a second time.
   After "Replace original" a picture-in-picture still named the deleted asset.

Found while confirming these, in the same code:

4. **Split parts were left as separate clips.** Each part was reset to "play the whole asset", so a
   clip split in two played the baked video twice after a bake. The transition between the parts
   stayed too.

## Change

- `ClipBakePlan.flattened(_:target:replacedBy:)` (pure) is now the one place that decides what
  leaves the project after a bake:
  - the target's parts become one neutral clip in the first part's place, re-pointed at the new
    asset after "Replace original";
  - overlays bound to a target part are removed; overlays bound to other clips are kept;
  - a transition between two parts is removed; a transition out of the last part moves to the
    merged clip;
  - when the bake covers the whole project (`coversWholeProject`), unbound overlays,
    picture-in-picture, the HR tile, the base frame and the music are removed;
  - when other clips exist, those project-wide items are kept, and a picture-in-picture that showed
    the replaced asset is re-pointed at the new one.
- `ClipBakePlan.rendersMusic(_:)` (pure) mirrors the composer's path choice: its transition path
  does not mix the music, so those tracks are not removed.
- `StudioEditorViewModel.bake()` reads the snapshot and the visible clips once, before the first
  await, and computes the flatten and the offset shift from them.
- `StudioEditorViewModel.isBaking` locks the project: `edit`, `editOverlaysOnly`, `undoEdit` and
  `redoEdit` refuse while it is true. `StudioEditorView` disables the editor and its dismissal for
  the same time. The "Saving to original…" indicator is unchanged.

Not changed: the render, the Photos writes, when a bake is offered, the `SessionMedia` updates, the
export lane (an export still allows edits; it writes nothing back to the project).

## Known gap, left for a decision

After a bake of one clip in a session with other clips, the HR tile, unbound text, music and base
frame stay in the project for the other clips. The Studio does not yet skip them for the baked clip
(the Clips feed does, through `SessionMedia.isBaked`). So opening that clip in the Studio again
shows the tile over the baked tile, and exporting or baking it again renders them twice. The fix is
a stand-down for baked clips in the Studio's preview and render, which is outside the bake flow.

## Tests

`ClipBakePlanTests` (SnappetTests, no device):

- a scoped bake keeps the other clip's tag, the unbound text, the HR tile, the base frame and the
  music, and leaves the other clip untouched;
- a whole-project bake removes all of them, including picture-in-picture, and re-points the clip;
- split parts become one clip; the transition between them goes; the one out of the last part moves;
- a picture-in-picture of the replaced asset follows it; a revertible bake re-points nothing;
- music the transition path did not mix stays;
- a target that is not in the project changes nothing;
- with `bakeState == .baking`, rename, delete clip, add picture-in-picture and undo change neither
  the view model nor the stored project; they work again when the bake ends.

## Owed on device

The Photos writes cannot run on the simulator. On a phone, in a session with two or more clips, one
with a climb tag each and an HR tile:

1. "Edit this clip" → "Save to original · revertible". The editor is disabled until the alert. The
   other clip still has its tag and the session still has its HR tile.
2. Split a clip in two, add a dissolve, bake. The timeline shows one clip of the baked length.
3. A one-clip session with picture-in-picture and music → "Replace original". Export again: one
   picture-in-picture layer gone, music heard once.
