# Prompt: Quick Session climb — clip lifecycle (dynamic attempt# · deep-tap reassign / remove / delete)

**File**: pdd/prompts/features/quick-session-redesign/11-climb-clip-lifecycle.md
**Created**: 2026-06-18
**Chain**: follows prompt 10; user on-device feedback on per-attempt clips + "Edit all clips".
**Context**: `pdd/context/*`.

## Goal
Four refinements to climbing attempt clips:
1. The "Attempt #" tag in the Studio editor is driven by the **currently selected clip** (dynamic),
   especially in "Edit all clips" where the focused clip changes — its attempt # follows the selection.
2. **Deep-tap (long-press)** an attempt clip → **reassign it to a different attempt** of the climb.
3. Deep-tap → **remove the clip from the attempt** (untie it; keep the file).
4. Deep-tap → **permanently delete the clip** — with a confirmation that warns it ALSO removes the file
   from Photos.

## Context — almost all of this exists; PORT it (verified file:line)
`SessionDetailView.swift` already does 2/3/4 post-session — reuse its exact patterns:
- **`thumbMenu(for:)`** (`SessionDetailView.swift:521`) — a `.contextMenu` with "Edit in studio", a
  "Move to…" `Menu` over `moveTargets` (+ "General"), and a destructive "Remove…".
- **`reassign(_ item:to exerciseID:set:)`** (`:593`) — sets `assignedExerciseID/assignedSetIndex` and
  `assignmentSource = exerciseID == nil ? .general : .manual` (so `.manual` pins it — `reconcileAssignments`
  only touches `.auto` rows, `:604`).
- **The deletion `.confirmationDialog`** (`:111`): buttons **"Remove from session only"** (`removeTag`)
  / **"Delete from Photos too"** (`deleteFromPhotos`, role `.destructive`) / Cancel, message: *"Remove from
  session" keeps the video in your Photos library. "Delete from Photos" permanently removes it (iOS will
  ask once more).* `deleteFromPhotos(_:)` (`:160`) calls `mediaLibrary.deleteAssets(localIdentifiers:)`
  (`MediaLibraryService.swift:102`, does the `PHAssetChangeRequest.deleteAssets`) then `context.delete` + save.
- **`SetMediaStrip.swift`** renders each clip thumb at `:44–53` (a video is a `Button{onEdit}` →
  `SessionMediaThumb`); it has NO context menu today. `@Query` scopes to `(sessionID, assignedExerciseID,
  assignedSetIndex)` (`:34`).
- **Editor VM** (`StudioEditorViewModel.swift`): `selectedClipID` (`:39`) → `selectedClip: TimelineClip?`
  (`:154`) → `selectedClip?.sessionMediaID` → fetch `SessionMedia` (pattern at `:502`). The "Attempt #"
  gate `canShowClimbAttempt` (`:459`) + `setSelectedClimbShowsAttempt` (`:474`) currently use the STATIC
  `suggestedAttemptNumber` threaded at open.

## Approach
### Part 1 — dynamic attempt # (editor)
- Add `var selectedClipAttemptNumber: Int?` to the VM: fetch the `SessionMedia` for
  `selectedClip?.sessionMediaID`; return `assignedSetIndex.map { $0 + 1 }`. Make `canShowClimbAttempt` and
  `setSelectedClimbShowsAttempt` (and any display of the number) use **`selectedClipAttemptNumber ??
  suggestedAttemptNumber`** so the tag reflects the SELECTED clip in multi-clip mode and the single clip in
  single-clip mode. (Keep `suggestedAttemptNumber` as the fallback when no SessionMedia lookup.)
- If a `.climbName` overlay already has "Attempt #" ON and the user selects a different clip, recompute its
  appended line to the newly-selected clip's number (recompose via `KilterClimbCaption.climbTagContent`).

### Parts 2–4 — deep-tap clip menu on the live strip (port SessionDetailView)
- Give `SetMediaStrip` a `.contextMenu` per thumbnail (works for photos too): "Move to attempt…" (a `Menu`
  over the CLIMB's attempts) + "Remove from attempt" + "Delete clip…" (destructive). Thread closures from
  `FreeformPlayerView` down: `onReassign: (SessionMedia, UUID?, Int?) -> Void`, `onRequestDelete:
  (SessionMedia) -> Void`, plus the move-target list for the strip's climb.
- In `FreeformPlayerView`: add `reassignClip(_:to:set:)` (port of `reassign`) and host a single
  `.confirmationDialog($pendingClipDeletion)` (port the SessionDetailView dialog VERBATIM, incl. the Photos
  wording) → "Remove from attempt only" (`reassignClip(to: nil)`) and "Delete from Photos too"
  (destructive → `deleteClipFromPhotos`). Get the `MediaLibraryService` the same way SessionDetailView does.
  Move targets for a climb = its attempts — a pure helper `climbClipMoveTargets(for ex:) -> [ClipMoveTarget]`
  (id, title "Attempt N", exerciseID, setIndex) → UNIT-TEST it. "Remove from attempt" = reassign to General
  (assignedExerciseID nil) so it leaves the strip but keeps the file.
- a11y ids: `freeform.clipMenu` on the thumbnail (so the menu is queryable), `freeform.clipMove.<i>`,
  `freeform.clipRemove`, `freeform.clipDelete`, and the dialog's destructive button.

## Output
- `SetMediaStrip.swift` (context menu + closures), `FreeformPlayerView.swift` (reassign/delete + dialog +
  move targets + thread closures into BOTH climb-attempt strips), `StudioEditorViewModel.swift`
  (`selectedClipAttemptNumber` + dynamic gate/recompose). A pure helper + test for `climbClipMoveTargets`
  (`SnappetTests`).
- `decisions.md` entry; `docs/knowledge-graph/data.js` update.

## Acceptance criteria
- [ ] In "Edit all clips", selecting a different clip changes the attempt # the climb-name "Attempt #"
      toggle uses/shows (confined to the selected clip).
- [ ] Long-pressing an attempt clip offers: Move to another attempt (reassigns + pins `.manual`), Remove
      from attempt (→ General, file kept), Delete clip (confirmation explicitly warns it deletes from
      Photos too; iOS then asks once more).
- [ ] Reassigned/removed clips are sticky against auto-reconcile (`.manual`/`.general`).
- [ ] `xcodegen generate` + `build-for-testing` clean (Swift 6, 0 new warnings); full `SnappetTests` green
      (incl. the `climbClipMoveTargets` test); `NamedClimbTests`/`EditClimbTests` still pass.

## Test plan
`xcodegen generate`; `xcrun simctl shutdown all`; `build-for-testing`; `test-without-building -only-testing:SnappetTests`; climb UITests. On the unit-runner wedge ("hung before establishing connection"): `simctl shutdown all` + retry, else `xcrun simctl erase "iPhone 17"` and run on `name=iPhone 17` (a connected+locked MrRobot disrupts the 17 Pro sim). Device-only: the actual Photos deletion (system confirm) + PHPicker + context-menu long-press feel. Commit (changed files only) when green; message `feat(quick-session): climb clip lifecycle — dynamic attempt# + deep-tap reassign/remove/delete (Photos-aware)`.
