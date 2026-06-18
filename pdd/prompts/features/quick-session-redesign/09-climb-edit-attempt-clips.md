# Prompt: Quick Session climb — edit details · per-attempt clips → editor · climb-name overlay

**File**: pdd/prompts/features/quick-session-redesign/09-climb-edit-attempt-clips.md
**Created**: 2026-06-18
**Chain**: follows the Quick Session redesign (Phases 1–8); user-requested iteration on the climb card.
**Context**: `pdd/context/*`. Source: user (on-device feedback).

## Goal

Three cohesive refinements to a freeform CLIMB card (all on the same surface, so one prompt):
1. **Edit climb details** — a climb just added can have its TYPE/GRADE/SCALE/NAME/GYM/WALL/COLOUR edited
   (today only the name is inline-editable).
2. **Per-attempt media** — film/attach a video or photo for **each attempt** under the climb; tapping a
   video clip opens the **Studio clip editor** (as set clips already do for lifting/timed).
3. **Climb-name overlay** — when that editor opens for a climb clip, the **climb's name** is available as
   a toggleable **on-video text overlay** the user can show/position.

## Context the implementer needs (verified file:line refs)
- **Climb card** is `climbSection`/`climbHeader`/`climbFooter` in `FreeformPlayerView.swift`. The header
  Menu currently has only "Remove climb" (~`FreeformPlayerView.swift:667`). The expanded card lists
  attempts (each a `SetLog` at index `i`).
- **`AddClimbSheet`** captures `AddClimbParams(type, scale, grade, name, gym, wall, color)` via
  `onAdd(_:logFirstAttempt:)`. `addClimbFromSheet` builds the `.climbAttempt` `SessionExercise`. The sheet
  reads its initial state in `.onAppear` (type/scale/grade/recents/gym/wall) — extend it to PREFILL from
  an existing climb and SAVE back.
- **`SetMediaStrip(session:exerciseID:setIndex:onEdit:)`** (`SetMediaStrip.swift:24`) renders the clips
  assigned to `(exerciseID,setIndex)` + a PHPicker "attach" button; a video thumbnail tap calls
  `onEdit(clip)`. It's placed today on the LAST set of reps/weight + timed exercises
  (`FreeformPlayerView.swift:~587`). **Auto-assignment ALREADY tags `.climbAttempt` sets** —
  `SessionMediaAssignment.completions(from:startedAt:)` iterates all exercise kinds, so a clip filmed
  during a climb attempt already maps to `(climbExerciseID, attemptIndex)`. So per-attempt media is
  purely a UI add (render the strip per attempt) + manual attach (already supported).
- **`presentStudio(_ clip:)`** (`FreeformPlayerView.swift:1257`) resolves a `StudioProject`
  (`StudioEntry.resolveProject`) and opens `StudioEditorView` via the `.fullScreenCover(item:$studioClip)`
  on a `FreeformStudioPresentation` (`FreeformPlayerView.swift:1315`).
  `StudioEditorView.init(project:context:focusClipMediaID:visibleClipMediaIDs:)` (`StudioEditorView.swift:33`).
- **Studio overlays:** `OverlayItem` (`StudioProject.swift:175`) has kinds `.text`, `.sticker`, `.video`,
  **`.climbName`**. `StudioEditorViewModel.addClimbNameOverlay()` (`:401`) drops a `.climbName` lower-third
  overlay — but it's gated on `resolvedClimbUUID` (the **Kilter** `KilterLogEntry` path) and builds the
  caption from `KilterCatalog`/`KilterLogEntry`. A FREEFORM climb has no `KilterLogEntry`; its caption is
  `SessionExercise.displayName` + `climbGradeLabel`. `addText(_:)` (`:360`) adds a plain `.text` overlay.

## Approach
### Part 1 — Edit climb details
- Add **"Edit details"** (pencil) to the climb header Menu, above "Remove climb". It presents
  `AddClimbSheet` in an EDIT mode prefilled from the climb.
- Give `AddClimbSheet` an optional `initial: AddClimbParams?` (when non-nil: title "Edit climb", primary
  CTA "Save", single CTA — no "Add & log first attempt"; seed `type/scale/grade/color/name/gym/wall` from
  it in `.onAppear`). The player routes the result to a new `updateClimb(_ exID:UUID, _ params:)` that
  overwrites the existing `SessionExercise`'s climb fields (type/grade/scale/name/gym/wall/colour) in
  place — NOT a new climb. `resolvedName` empty still falls back to the type label. a11y: `freeform.editClimb`
  (menu), reuse the existing `addClimb.*` ids; the Save CTA id `addClimb.save`.
- Carry `color` + `wall` in the prefill (Phase-8 fields). Keep migration-safe.

### Part 2 — Per-attempt media strip
- In the expanded climb card, render a **`SetMediaStrip(session:exerciseID:ex.id, setIndex:i, onEdit:{ presentStudio($0) })`**
  under EACH attempt row `i` (keyed `.id("climb-media-\(ex.id)-\(i)")`), so a clip filmed during / attached
  to that attempt shows under it and a video tap opens the editor. Keep it compact (it sits in the attempt
  list). No model change — assignment already works.

### Part 3 — Climb-name overlay for freeform clips
- Thread the freeform climb's caption to the editor: extend `FreeformStudioPresentation` with
  `climbCaption: String?`; `presentStudio` looks up the clip's `assignedExerciseID` → if it's a
  `.climbAttempt` `SessionExercise`, build `caption = [displayName, climbGradeLabel].compactMap{…}.joined(" · ")`
  (e.g. "Cave Roof · V5") and pass it. Add a `suggestedClimbCaption: String?` param down
  `StudioEditorView.init` → `StudioEditorViewModel`.
- In `StudioEditorViewModel.addClimbNameOverlay()`: when `resolvedClimbUUID == nil` but
  `suggestedClimbCaption` is set, drop the same `.climbName` lower-third overlay seeded with the suggested
  caption (reuse the existing overlay shape/position/editability). Surface the editor's "Add climb name"
  action whenever `resolvedClimbUUID != nil || suggestedClimbCaption != nil` (find where that button is
  gated and widen the condition). The overlay stays draggable / editable / deletable (the user "picks to
  make it visible"); deleting hides it.

## Output
- `AddClimbSheet.swift` (edit mode), `FreeformPlayerView.swift` (edit menu + updateClimb + per-attempt
  strips + caption in presentStudio + presentation field), `StudioEditorView.swift` +
  `StudioEditorViewModel.swift` (`suggestedClimbCaption` + freeform climb-name overlay).
- A pure test if any pure helper is added (e.g. a caption builder → `SnappetTests`). Update
  `NamedClimbTests` (or add `EditClimbTests`) to drive Edit (change a grade → assert the card updates).
- `decisions.md` entry; `docs/knowledge-graph/data.js` note (edit-climb + per-attempt media + freeform
  climb-name overlay).

## Acceptance criteria
- [ ] A climb's Menu has "Edit details" → the sheet opens prefilled (type/grade/scale/name/gym/wall/colour);
      Save updates THAT climb in place (no duplicate); attempts under it are preserved.
- [ ] Each attempt shows a media strip; attaching/ filming a clip shows it under the attempt; tapping a
      video opens the Studio editor.
- [ ] In the editor for a freeform climb clip, the user can add the climb's name as an on-video overlay
      (lower-third) and move/edit/remove it.
- [ ] `xcodegen generate` + `build-for-testing` clean (Swift 6, 0 new warnings); full `SnappetTests` green.
- [ ] The climb UITest passes (edit-grade path included).

## Test plan
`xcodegen generate`; `xcrun simctl shutdown all`; `build-for-testing`; `test-without-building -only-testing:SnappetTests`; the climb UITest. (Photos/PHPicker + the actual editor overlay render are device-only — note them.) Commit (changed files only) when green; message `feat(quick-session): climb edit details + per-attempt clips → editor + climb-name overlay`.
