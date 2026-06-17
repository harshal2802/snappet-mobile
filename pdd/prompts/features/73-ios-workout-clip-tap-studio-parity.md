# Prompt: Workout clip-tap opens the scoped Studio (Kilter parity) + retire the single-clip editor

**File**: pdd/prompts/features/73-ios-workout-clip-tap-studio-parity.md
**Created**: 2026-06-17
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: `live-workout-studio/PLAN.md` → Track B (studio) — supersedes **B3** (`B3-clip-editor.md`).
**Source**: User request — "tapping an individual clip during the workout should give the CapCut-style
Studio like Kilter, instead of the old Edit-clip editor, and remove the dead code."
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Reference prompts**: `20-ios-kilter-clip-scoped-editing.md` (the Kilter per-clip scoped-Studio
precedent this brings to the gym side), `live-workout-studio/DESIGN-full-studio.md` (the S1 multi-clip
studio), `B3-clip-editor.md` (the single-clip editor being retired).

## Goal

Bring the WorkoutTracker (gym) session detail to **parity with Kilter**: tapping a video clip should
open the CapCut-style **multi-clip Studio** (`StudioEditorView`) **scoped to that one clip**, the same
editor Kilter already opens per-clip — not the old single-clip "Edit Clip" sheet (`ClipEditorView`).
The workout side already opened the full Studio session-wide via the "Edit in Video Studio" button; it
just hadn't adopted the studio for the per-clip tap. With both clip-editing paths now flowing through
the one multi-clip Studio, the **entire old single-clip editor stack becomes dead code** and is removed
(one editor, one render engine, one edit model — the multi-clip `StudioProject`/`StudioComposer`).

## Context the implementer needs

- The ONLY presentation of the old editor is `SessionDetailView`'s `.sheet(item: $editingClip) {
  ClipEditorView(media:) }`; the per-clip tap routes through `SessionMediaSection.onEditClip`.
- Kilter's precedent: `KilterSessionDetailView.editClip(_:)` → `presentStudio(visible:[clip.id],
  focusing:clip.id)` → `KilterClipStudio` (which wraps `StudioEditorView` and adds a Kilter-only Climb
  panel). The gym side must use the **bare** `StudioEditorView` scoped — gym sessions have **sets, not
  climbs**, so no Climb panel.
- `StudioEditorView(project:context:focusClipMediaID:visibleClipMediaIDs:)` already supports scoping
  (its `.task` selects the focused clip). Scoping a single clip = `visibleClipMediaIDs: [clip.id]`.
- Gotcha: `StudioEntry.findOrCreateProject` returns the existing `StudioProject` **without** appending
  videos discovered after it was created. A scoped open of a not-yet-in-project clip would show an empty
  timeline. Kilter reconciles inline; the gym side needs the same.

## Approach

- Add `StudioEntry.resolveProject(for:media:context:)` — find-or-create **then** append any
  newly-discovered video clips (mirrors Kilter's `resolveStudioProject`), so a scoped open is never
  blank. Shared, pure-at-the-edge SwiftData helper.
- `SessionDetailView` / `SessionMediaSection`: replace the `editingClip` sheet + `onEditClip` plumbing
  with a single `StudioPresentation` (`{project, visibleClipMediaIDs, focusClipMediaID}`) driving the
  existing `fullScreenCover`. `openStudio()` opens it unscoped; new `editClip(_:)` opens it scoped to
  the tapped clip. Repoint the row tap + the "Edit in studio" menu item.
- Delete the dead stack: `ClipEditorView.swift`, `ClipEditorViewModel.swift`, `ClipEdit.swift`
  (`@Model ClipEdit` + `TextOverlay`), `Services/VideoStudio.swift` (`VideoStudio` + `EditPlan`), and
  `AppModel.videoStudio`. Keep the SHARED `ClipEditGeometry`, `HROverlayConfig`, and the whole multi-clip
  Studio stack.
- Drop `@Model ClipEdit` from `SnappetSchema.models` (`SnappetCore.swift`) **and** from the backup
  (`SnappetBackup.swift`: schema list, `clipEdits` field + count, export, restore/wipe, `ClipEditRow`).

## Output

- `StudioEntry.resolveProject(...)`; rewired `SessionDetailView.swift`.
- Four deleted files + removed `AppModel.videoStudio`.
- `SnappetCore.swift` + `SnappetBackup.swift` schema/format edits.
- Tests: `SnappetBackupTests` (drop the ClipEdit round-trip; recordCount 22→21); the UI walkthrough
  (`LiveWorkoutStudioWalkthroughTests` step 11g now expects the Studio `studioClose`, not
  `clipEditorDone`).
- `docs/knowledge-graph/data.js` (remove `wt-clip-editor`/`videostudio`/`model-clipedit` nodes + edges;
  repoint the clip-tap edge to the scoped studio) + this PDD set.

## Acceptance criteria

- [ ] Tapping a video clip in a completed gym session opens the multi-clip Studio **focused on that
      clip** (not the old sheet); the session-wide "Edit in Video Studio" button still opens it unscoped.
- [ ] A clip tagged AFTER the project was created still appears (reconcile) — not a blank timeline.
- [ ] `ClipEditorView`/`ClipEditorViewModel`/`ClipEdit`/`TextOverlay`/`VideoStudio`/`EditPlan` are gone;
      no live references remain (grep clean; only deliberate past-tense lineage in comments).
- [ ] App type-checks (Swift 6, 0 warnings) against the iOS SDK; `SnappetTests` pass (incl. the backup
      schema tripwire `testCodecCoversEverySchemaModel`).
- [ ] The UI walkthrough's clip-tap step passes against the Studio.
- [ ] `decisions.md` records the schema-removal + data-loss note; the knowledge graph has no drift.

## Constraints

- On-device only; no backend. Gym side uses the **bare** `StudioEditorView` (no Climb panel).
- `HighlightEngine` stays platform-free (untouched here).
- The `@Model ClipEdit` removal is **destructive** to legacy single-clip edits (see decisions.md) — it
  must land with both schema arrays in lockstep and the backup-format change in the same change.

## Test plan

1. `cd ios/App && xcodegen generate` (regenerates the project after the 4 deletions).
2. `xcodebuild build-for-testing -scheme Snappet -destination 'platform=iOS Simulator,name=iPhone 16 Pro'`.
3. `xcodebuild test -scheme Snappet -only-testing:SnappetTests -destination '…iPhone 16 Pro'`
   (the backup tripwire + decremented recordCount).
4. This PR changes real UI, so run the UITest suite (at least
   `SnappetUITests/LiveWorkoutStudioWalkthroughTests`) — step 11g now drives the scoped Studio.
5. Device: tap a freshly-discovered clip and confirm the focused clip appears in the timeline (reconcile).
