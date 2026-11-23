# Prompt: A clip deleted from the Studio timeline stays deleted

**File**: pdd/prompts/features/studio-review/296-ios-studio-deleted-clips-stay-deleted.md
**Created**: 2026-11-23
**Project type**: iOS
**Chain**: third fix from the 2026-11 Studio code review; builds on prompt 294
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Problem

Confirmed by reading the code on `5855c00b` (prompt 294). Not reproduced on a device.

One Studio project is shared by a whole session. Every time the Studio opens,
`StudioEntry.resolveProject` (and its Kilter copy, `KilterStudioProjects.resolve`) looks for
session videos whose `SessionMedia.id` is not among the project's clips and appends them. This is
meant for videos filmed or imported after the project was made.

The Delete button on the timeline (`StudioEditorViewModel.deleteSelected()` →
`StudioProjectEditor.removeClip`) removes the clip from the project and records nothing. On the
next open the deleted clip's media is "not among the project's clips", so it was appended again, at
the end of the timeline, with none of its edits. The project could not tell "never added" from
"deleted by the user".

The scoped entries ("Edit this clip", a climb's "Edit all") relied on the same step: they filter
the shared project to a set of media ids, so a clip the project does not have gives an empty
editor. The Studio has no "add clip" action, so nothing else could bring a clip back.

## Change

- `StudioProject.removedMediaIDs: [UUID]?` (new, optional) lists the media the user deleted from
  the timeline. It is part of `StudioProjectSnapshot` (so undo restores it) and of the backup row.
- `StudioProjectEditor.removeClip` adds the clip's media id to the list when no other clip of that
  media is left. Deleting one part of a split clip records nothing while another part remains.
- `StudioEntry.reconciled(clips:removedMediaIDs:footage:scope:)` (pure) is the one rule for what
  joins the timeline when the Studio opens. Both the gym and the Kilter entry use it:
  1. a video on the timeline is left alone;
  2. a video that was never on the timeline is appended, in capture order;
  3. a video in `removedMediaIDs` is not appended;
  4. the Studio does not open on an empty timeline: if rules 1–3 leave no clip in the scope being
     opened (the whole project when unscoped), the deleted videos in that scope come back and are
     taken off the list.
- The entries pass their scope (the same set they pass as `visibleClipMediaIDs`) to
  `resolveProject(…scope:…)` / `KilterStudioProjects.resolve(…scope:…)`.

What the user sees:

- Delete a clip in the whole-session Studio, or in a post's or climb's "Edit all clips": it is gone
  the next time that Studio opens. Videos filmed later still appear.
- Open "Edit this clip" on a clip that was deleted from the timeline: the clip is there, as a fresh
  clip without its old edits, and it is back in the whole-session Studio too. Opening a clip
  explicitly is treated as asking for it.
- Delete every clip of a project: the next open starts over with all of them.
- Undo of a delete brings the clip back and forgets the deletion.

Not changed: `StudioEditorViewModel`, the editor views, the composer, `ClipBakePlan`. A bake keeps
the list as it is and keeps the surviving clip's media id, so it cannot make a clip look deleted.
A listed id whose media is on the timeline is ignored and dropped.

## Known gaps

- A clip that comes back does not get its trims, tags or text back. Undo is the way to get those.
- Projects saved before this change have no list, so a clip deleted before the update comes back
  once more.
- When the user deletes a `SessionMedia` row itself, its id can stay in the list. It has no effect.

## Tests

SnappetTests, no device:

- `StudioEntryTests`: never-added media is appended in capture order; a deleted clip is not; later
  footage is still added next to a deleted clip; a scope that still shows a clip brings nothing
  back; "Edit this clip" on a deleted clip brings back that clip only; an emptied project starts
  over; a record for media on the timeline is dropped; the footage filter; and the whole path on an
  in-memory store (delete in the view model, reopen, undo, redo, scoped reopen).
- `StudioProjectEditorTests`: `removeClip` records the media; a split clip is recorded only when
  its last part goes; undo and redo carry the record; a snapshot without the new key decodes.
- `ClipBakePlanTests`: after a bake that merges split parts and re-points the asset, the next open
  changes nothing.
- `SnappetBackupTests`: the list survives export and restore.

## Owed on device

In a session with three or more videos:

1. "Edit in Video Studio" → delete one clip → Done → open it again. The clip is still gone.
2. Tap the deleted clip in the session's media → the Studio opens on that clip. Open the
   whole-session Studio: the clip is at the end of the timeline.
3. Delete a clip, tap Undo, close, reopen. The clip is where it was.
4. An app updated over an existing install opens its old Studio projects (the new field is
   optional; this is the store migration).
