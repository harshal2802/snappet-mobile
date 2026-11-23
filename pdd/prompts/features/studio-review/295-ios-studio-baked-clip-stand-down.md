# Prompt: The Studio does not draw project-wide items over a baked clip

**File**: pdd/prompts/features/studio-review/295-ios-studio-baked-clip-stand-down.md
**Created**: 2026-11-23
**Project type**: iOS
**Chain**: 2026-11 Studio code review; closes the "Known gap" of prompt 294; follow-up to prompt 117
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Problem

One Studio project is shared by a whole session. Since prompt 294, a bake of one clip ("Edit this
clip" → "Save to original" or "Replace original") keeps the project-wide items in the project,
because the other clips still use them: the HR tile, overlays not bound to a clip (text, stickers,
picture-in-picture), the added music and the base frame.

The baked clip already has those items in its pixels. The Clips feed knows this through
`SessionMedia.isBaked` and plays the clip raw. The Studio did not. Opening the baked clip in the
Studio again showed the HR tile over the baked tile, and an export or a second bake rendered the
tile, the text, the picture-in-picture, the music and the base frame a second time.

Hiding everything project-wide whenever the clip is baked was tried first and rejected: a text or
a tile the user adds to that clip after the bake would be stored but never drawn.

Confirmed by reading the code on `fix/studio-bake-flatten-294`. Not reproduced on a device.

## Change

The Studio stands down for exactly the items that were in the render of the bake.

- `TimelineClip.baked: BakedItems?` is a new optional field (old projects decode it as `nil`). It
  lists the project-wide items a bake kept in the project although they are in this clip's pixels:
  `overlayIDs` (unbound overlays, picture-in-picture included), `audioTrackIDs` (added music, only
  when the render mixed it), `hrTile`, `baseFrame`.
- `ClipBakePlan.flattened` writes the record on the merged clip. It works out what the bake
  rendered (the clip's scope, minus what an earlier bake already recorded), adds that to the record
  the parts already had, and drops items that are no longer in the project. After a whole-project
  bake those items were removed, so the record is `nil`. `hrTileDrawn: false` keeps the tile out of
  the record when the render had no heart-rate data to draw.
- `ClipBakePlan.standingDown(_:visible:)` (pure) returns the snapshot to preview and render. An
  unbound overlay, a music track, the HR tile or the base frame is left out only when every
  visible clip's record holds it. That is "Edit this clip" on a baked clip. Anything added after
  the bake is in no record and is drawn and exported normally.
- HR tile on a mixed timeline: a clip whose record has `hrTile` gets no per-clip HR content, the
  canvas hides the tile while the playhead is on it (`canvasHRTile`), and the session-wide fallback
  tile is not rendered when any visible clip has `hrTile`, because it is one layer over the whole
  output.
- `StudioEditorViewModel`: the canvas overlays, the overlay lane, the base-frame handle, the
  preview composition and the render all read one stood-down snapshot. `bake()` passes whether the
  render draws a tile. The view model does not look at `SessionMedia.isBaked` for this.
- Photos revert: when `reconcileBakedFlags` clears a row's `isBaked`, it also clears the record on
  that asset's clips (`ClipBakePlan.clearingBakeRecords`), replaces the undo history, saves and
  rebuilds the preview. It does nothing while a bake is running.
- `StudioEditorView` draws `vm.canvasHRTile` in place of `vm.hrTile` on the canvas (one line).

Not changed: the composer, the overlay renderer, `SessionMedia.isBaked` and the feed, the tool
sheets, `StudioProjectSnapshot`. The backup carries the field without a change, because it stores
`[TimelineClip]` as Codable.

## What is still wrong, left for a decision

1. **Mixed timeline.** With a baked and an unbaked clip on one timeline ("Edit all clips"),
   unbound text and stickers, picture-in-picture, music and the base frame still apply to the whole
   output, so the baked clip gets them twice. They have no per-clip gate in `StudioComposer`, which
   this job does not touch. Only the HR tile is correct there.
2. **Mixed timeline, clip with no media link.** The session-wide fallback tile is dropped when any
   visible clip was baked with a tile. An unbaked clip that has no capture offset then has no HR
   tile in that export. It had the whole-session tile before.
3. **The tile and the base frame have no identity.** If a clip was baked with an HR tile, a tile
   the user removes and adds again later is still not drawn over that clip; the same for the base
   frame. The record says "this clip has a tile in its pixels", not which one. A recorded text
   that is edited afterwards also stays hidden over that clip. A Photos revert clears all of it.
4. **Clips baked before this change have no record.** Nothing is hidden for them; they behave as
   they did before this prompt. For bakes made before prompt 294 the flatten had already deleted
   the tile and the text from the whole project.

## Tests

`ClipBakePlanTests` (SnappetTests, no device):

- a scoped bake records the kept text, picture-in-picture, music, tile and base frame on the baked
  clip and nothing on the other; no tile when none was drawn; no music when the transition path
  did not mix it; no record after a whole-project bake;
- "Edit this clip" on the baked clip: the recorded items are left out; a text, a bound tag and a
  music track added after the bake stay; the input snapshot is unchanged; the other clip's scope
  and a clip with no record are unchanged;
- after a whole-project bake a new text, tile, base frame and music are all drawn;
- mixed timeline: snapshot unchanged, tile hidden over the baked clip only, session-wide tile
  refused; two baked clips hide only what both recorded;
- a second bake adds to the record, merged split parts keep it, `neutralizedClips` keeps it, a
  tile that left the project leaves the record;
- a Photos revert clears the record by media row or by asset identifier;
- a clip encoded without the field decodes; a record survives a round trip;
- view model, in-memory store: the baked clip's scope shows none of the baked items and does show
  a text added afterwards; the other scope shows everything; the stored project keeps everything.

## Owed on device

Nothing here was run on a phone. In a session with two clips, an HR tile, one text and music:

1. Bake clip A from "Edit this clip". Open "Edit this clip" on A again: one HR tile and one text
   are visible (the baked ones), and the overlay lane is empty. Add a second text: it appears.
   Export: one tile, the first text once, the second text, the music once.
2. Open "Edit this clip" on clip B: tile, text and music are there as before.
3. Open "Edit all clips" and export: the tile appears once over A and once over B.
4. A one-clip session: "Replace original", then add a text and an HR tile. Both are drawn and
   exported.
5. In Photos, "Revert to Original" on A. Open the Studio on A: the tile and the first text are
   drawn again a moment after the editor opens.
6. Install over a build without this change and open an existing project: it opens with its clips.
