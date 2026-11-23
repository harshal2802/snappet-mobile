# Prompt: One Studio undo step and one save per slider drag

**File**: pdd/prompts/features/studio-review/299-ios-studio-undo-one-step-per-gesture.md
**Created**: 2026-11-23
**Project type**: iOS
**Chain**: fix from the 2026-11 Studio code review; built on prompt 294 (the bake lock)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Problem

A read-only review of the Studio found that Undo floods. Confirmed by reading the code on
`fix/studio-bake-flatten-294` (`5855c00b`). Not reproduced on a device.

Three sliders wrote to the view model on every tick, through a plain `Binding` with no
`onEditingChanged`. Each tick went through `editOverlaysOnly`, which added an undo step and saved
the SwiftData store. One drag therefore made dozens of undo steps and dozens of saves. Undo then
stepped back one tick at a time, and a long drag could push older edits out of the 50-step history.

### Audit of every continuous control in the Studio

| Control | File | Before this change |
|---|---|---|
| Overlay **Size** slider (`overlaySize`) | `StudioEditorView` | **step + save per tick** |
| Overlay **Opacity** slider (`overlayOpacity`) | `StudioEditorView` | **step + save per tick** |
| HR tile **Opacity** slider (`hrTileOpacity`) | `StudioEditorView` | **step + save per tick** |
| HR window Lead-in / Tail sliders | `StudioEditorView` | once, at the end (the drag is view state) |
| Clip volume slider (`volumeSlider`) | `StudioEditorView` | once, at the end |
| Clip adjust sliders (`adjust-…`) | `StudioEditorView` | once, at the end |
| Drag / pinch / corner resize of a picture-in-picture, the HR tile, the base frame | `StudioOverlayCanvas` | once, in `onEnded` (`@GestureState` while moving; `onChanged` only selects and draws guides) |
| Drag / pinch of a text, sticker or climb-name overlay | `StudioOverlayCanvas` | once, in `onEnded` |
| Clip trim handles | `StudioTimelineView` | once, in `onEnded` |
| Overlay bar move and its edge handles | `StudioTimelineView` | once, in `onEnded` |
| Timeline scrub, timeline pinch-zoom | `StudioTimelineView` | no edit at all (seek / view state) |

There is no rotate gesture in the Studio. Only the three sliders in bold needed a fix.

## Change

- `UndoStack` (pure) has a transaction:
  - `beginTransaction()` opens it and changes nothing;
  - `replaceCurrent(_:)` sets the current value without adding a step, any number of times (with no
    transaction open it is a plain `commit`);
  - `endTransaction(where:)` / `endTransactionIfChanged()` closes it. If the value changed, the
    stack gains exactly one step holding the value from before the gesture, and the redo branch is
    cleared once. If it did not change, the stack is as it was, redo included;
  - `commit`, `undo` and `redo` close an open transaction first. A `commit` with no transaction
    open behaves as before.
- `StudioEditorViewModel` has `beginGesture()` and `endGesture()`. While a gesture is open, the
  three slider setters (`setOverlayScale` for non-video overlays, `setOverlayOpacity`,
  `setTileOpacity`) replace the snapshot live, so the canvas follows the finger, and do not save.
  `endGesture()` records the one step and saves once; it does neither if nothing changed.
- Every other edit, Undo and Redo close an open gesture first. So a gesture cannot swallow a
  different edit, and a gesture that was never closed heals at the next action.
- The three sliders call `beginGesture` / `endGesture` from `Slider(onEditingChanged:)`, and call
  `endGesture` when they disappear (the panel can close while a finger is down).
- The bake lock (prompt 294) covers the new paths: a gesture cannot begin and a tick does nothing
  while a bake renders. `endGesture` is allowed during a bake, because it writes only the snapshot
  the bake already read.

Not changed: with no gesture open, the three setters add a step and save on every call, as before
(a VoiceOver adjust and the canvas pinch reach them that way). Preview rebuilds are untouched: none
of the three sliders rebuilt the preview before, and none does now. No named undo steps and no
delayed save for single edits.

## Tests

`StudioUndoGestureTests` (SnappetTests, no device):

- pure: many replacements make one step holding the pre-gesture value; an unchanged or untouched
  gesture makes no step and keeps redo; redo is cleared once when a step is recorded; a replacement
  outside a transaction is a plain commit; `commit` and `undo` close an open transaction; the
  history limit counts a gesture as one step;
- view model, in-memory store: 30 opacity ticks in one gesture leave the stored project unchanged
  until the end, then one save, and one Undo restores the pre-drag value; the Size and HR tile
  opacity sliders behave the same; ticks outside a gesture are plain steps; Undo and another edit
  during a drag close it first; a drag does nothing while a bake renders.

## Owed on device

The slider's `onEditingChanged` cannot be driven from a unit test. On a phone, in a Studio project
with a text overlay and an HR tile:

1. Drag the overlay Size slider back and forth, lift. One Undo returns the size from before the
   drag. Redo restores the dragged size.
2. The same for overlay Opacity and for the HR tile Opacity.
3. Start a drag, and with the finger still down tap away so the panel closes. The value is kept
   and one Undo removes it.
4. With VoiceOver on, adjust a slider by one increment: one step, saved.
