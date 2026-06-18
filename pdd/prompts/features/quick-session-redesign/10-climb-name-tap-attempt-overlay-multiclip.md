# Prompt: Quick Session climb — name-tap expands · attempt-count on the tag · edit-all-clips together

**File**: pdd/prompts/features/quick-session-redesign/10-climb-name-tap-attempt-overlay-multiclip.md
**Created**: 2026-06-18
**Chain**: follows prompt 09 (climb edit + per-attempt clips + climb-name overlay); user on-device feedback.
**Context**: `pdd/context/*`.

## Goal
Three refinements to a freeform CLIMB card + its clip editor:
1. **Tapping the climb name expands/collapses the card** (no longer inline-edits the text — name editing
   now lives in "Edit details", prompt 09).
2. In the clip editor, an **option to show the ATTEMPT COUNT under the climb-name tag** (per-clip — the
   clip is attached to a specific attempt).
3. An **"Edit all clips" option for a climb** that opens the Studio editor scoped to ALL the climb's
   attempt clips together, reflecting the per-clip edits already made (the project is shared+persisted).

## Context the implementer needs (from prompts 08/09, verified)
- `climbHeader` in `FreeformPlayerView.swift` renders the name via **`ClimbNameHeader`** — an inline-editable
  `TextField` (`freeform.climbName`) that commits to `displayName`. A separate chevron toggles
  `toggleExpanded(ex)`. The header **Menu** (`freeform.climbMenu`) has "Edit details" (`freeform.editClimb`,
  prompt 09 — edits NAME + everything via `AddClimbSheet`) and "Remove climb".
- Clip flow (prompt 09): each attempt row has `SetMediaStrip(... onEdit: { presentStudio($0) })`.
  `presentStudio(_ clip:)` builds a `FreeformStudioPresentation(project:, visibleClipMediaIDs:[clip.id],
  focusClipMediaID:, climbCaption:)` and opens `StudioEditorView(... suggestedClimbCaption:)`.
  `FreeformStudioPresentation.climbCaption` is set from the climb's `displayName · climbGradeLabel`.
  `StudioEditorViewModel.addClimbNameOverlay()` drops a `.climbName` lower-third overlay seeded from
  `suggestedClimbCaption` (freeform) or the Kilter `KilterLogEntry` (board). `OverlayItem` content is a
  plain string; `visibleClipMediaIDs: Set<UUID>?` already supports a multi-clip view (nil = whole session).
- A clip's attempt index is `SessionMedia.assignedSetIndex` (0-based) on the climb exercise.

## Approach
### Part A — name tap = expand/collapse
- Replace `ClimbNameHeader` in the header with a plain, non-editing **`Text(name)`** that is part of the
  tappable expand/collapse affordance: tapping the name (or the name+chevron row) calls `toggleExpanded(ex)`.
  Keep an `accessibilityIdentifier("freeform.climbName")` on the label so it stays queryable, but it is now
  a label, not a field. Name EDITING is solely via the ⋯ menu → "Edit details" (already wired). Remove the
  now-unused `ClimbNameHeader` (or repurpose). Keep `freeform.climbExpand` working too (either still drives
  expand, or both the name and chevron do).
- **Update every UITest that types into `freeform.climbName`** (grep it): the rename path now goes through
  Edit details (`freeform.climbMenu` → `freeform.editClimb` → `addClimb.name` → `addClimb.save`). Update
  `NamedClimbTests` (and any other) accordingly; keep them green.

### Part B — attempt count on the climb-name tag
- Thread the focused clip's attempt number to the editor: add `suggestedAttemptNumber: Int?` to
  `FreeformStudioPresentation` + `StudioEditorView.init` + `StudioEditorViewModel` (additive, default nil).
  In `presentStudio`, when the clip is a climb attempt, set it to `clip.assignedSetIndex.map { $0 + 1 }`.
- In the editor, add a user-toggleable **"Attempt #"** option for the `.climbName` overlay (only shown when
  `suggestedAttemptNumber != nil` and a `.climbName` overlay exists/is selected). Toggling ON regenerates
  the overlay content to include the attempt — e.g. caption + a second line / suffix "Attempt N"; OFF
  removes it. Keep it as ONE `.climbName` overlay (don't add a second). The base caption stays editable.
  Pure-ify the string composition (`climbTagContent(caption:attempt:showAttempt:) -> String`) so it's
  unit-tested.

### Part C — edit all of a climb's clips together
- Add **"Edit all clips"** to the climb ⋯ menu (`freeform.editAllClips`), shown only when the climb has ≥1
  VIDEO clip (any `SessionMedia` with `assignedExerciseID == ex.id`, `kind == .video`).
- A `presentStudioForClimb(_ ex:)`: gather those clips' `SessionMedia.id`s, resolve the shared project
  (`StudioEntry.resolveProject`), and present `FreeformStudioPresentation(project:,
  visibleClipMediaIDs: Set(those ids), focusClipMediaID: first, climbCaption: <climb name·grade>,
  suggestedAttemptNumber: nil)`. Because the `StudioProject` is the session's single shared, persisted
  project, every overlay/trim/edit made in the per-clip editors is ALREADY on it — the combined view shows
  them together. (No new persistence; just a wider `visibleClipMediaIDs`.)

## Output
- `FreeformPlayerView.swift` (name-as-toggle; `presentStudioForClimb`; menu item; attempt number into
  `presentStudio`), `StudioEditorView.swift` + `StudioEditorViewModel.swift` (`suggestedAttemptNumber` +
  the "Attempt #" toggle + pure `climbTagContent`), a small pure test for `climbTagContent`
  (`SnappetTests`). Update `NamedClimbTests` (+ any test typing into `freeform.climbName`).
- `decisions.md` entry; `docs/knowledge-graph/data.js` updates.

## Acceptance criteria
- [ ] Tapping a climb's name expands/collapses the card; it never enters a text field. Editing the name is
      via ⋯ → Edit details.
- [ ] In a single attempt-clip's editor, the climb-name tag can show the attempt count (toggle on/off);
      it stays one overlay and the base caption is still editable.
- [ ] A climb with clips has ⋯ → "Edit all clips" opening the editor with all its attempt clips visible,
      carrying the edits made per-clip.
- [ ] `xcodegen generate` + `build-for-testing` clean (Swift 6, 0 new warnings); full `SnappetTests` green
      (incl. the new `climbTagContent` test).
- [ ] `NamedClimbTests` (updated) + `EditClimbTests` pass.

## Test plan
`xcodegen generate`; `xcrun simctl shutdown all`; `build-for-testing`; `test-without-building -only-testing:SnappetTests`; the climb UITests. If the unit runner hangs ("hung before establishing connection"), `xcrun simctl shutdown all` + retry, else `xcrun simctl erase "iPhone 17"` and run on `name=iPhone 17` (a connected+locked device can disrupt the 17 Pro sim). Device-only: the actual overlay burn-in + Photos. Commit (changed files only) when green; message `feat(quick-session): climb name-tap expands · attempt-count tag option · edit-all-clips together`.
