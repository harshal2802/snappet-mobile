# Prompt: Kilter clip editing — per-clip scope, per-climb "Edit all", shared edits, Climb panel

**File**: pdd/prompts/features/20-ios-kilter-clip-scoped-editing.md
**Created**: 2026-06-05
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: follow-up to `19-ios-kilter-session-media-reel.md` (Kilter per-climb media + studio parity).
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

After 19, tapping a Kilter clip opened the **whole-session** Studio with that clip merely pre-selected —
too coarse for "just fix this one clip", and there was no way to edit one climb's clips together or to
adjust the climb's log from inside the editor. Deliver: (1) tap one clip → edit **just that clip** (big
preview); (2) a per-climb **"Edit all · N"** when a climb has ≥2 video clips; (3) edits shared across all
scopes (one source of truth); (4) a **Climb panel** in the scoped editors — read-only catalog info plus
editable angle / result+tries / a personal note, and per-clip "Move clip to another climb".

## Context the implementer needs

- `StudioEditorViewModel` derives display/preview/export from `snapshot.clips` (a Codable value array on
  the `StudioProject` `@Model`), and **all edits are clip-id-based** via the pure `StudioProjectEditor`.
  So one session `StudioProject` + a visibility filter gives every scope while sharing edits — no schema
  change, no separate per-clip project.
- Foundation already present (from 19): `SessionMedia.assignedClimbUUID`, `KilterMediaGrouping.clips`,
  `KilterSessionDetailView.openStudio(focusing:)` (find-or-create + reconcile), the
  `StudioEditorView(…focusClipMediaID:)` pre-select hook, `existingSessionEntry`'s `(sessionId,climbUUID)`
  fetch, `kilterDisplayGrade`, `KilterCatalog.shared.climb/stats/layouts`.
- `KilterLogEntry` had no `note` field. Its `angle`/`statusRaw`/`attempts` are already mutable.

## Approach

- **Scope filter (the only workout-side change)** — keep it a *view* over the clips so edits still target
  the full project by id: `StudioGeometry.filterByMedia(_:to:)` (pure); `StudioEditorViewModel` gains
  `visibleClipMediaIDs: Set<UUID>?` (default `nil`) and routes `clips` / `placedClips` / `totalDuration`
  / preview / export through a filtered (`scopedSnapshot`) copy; `StudioEditorView` threads the param.
  **No changes to `StudioComposer` or `StudioTimelineView`.** `nil` ⇒ identical workout behavior.
- **`KilterLogEntry.note: String? = nil`** — additive, defaulted → SwiftData lightweight migration.
- **`KilterClimbPanel`** (new sheet): resolves the in-session `KilterLogEntry` + the catalog climb; shows
  read-only name/grade/board and editable angle/result/tries/note (write-through `try? save()`); per-clip
  presentations add "Move clip to another climb" (`SessionMedia.assignedClimbUUID`).
- **`KilterClipStudio`** (new container): `StudioEditorView` (scoped) + a floating "Climb ✎" button that
  presents `KilterClimbPanel` (only when a single climb is known).
- **`KilterSessionDetailView`**: one `ClipStudioPresentation` drives a single `fullScreenCover`. Tap a clip
  → scope `{clip.id}` + climb; "Edit all · N" (≥2 video clips) → that climb's clip ids + climb; bottom
  "Open studio" → `visible: nil`, no climb (session-wide, no panel). All share `resolveStudioProject`.

## Output

- Modify: `StudioGeometry.swift`, `StudioEditorViewModel.swift`, `StudioEditorView.swift`,
  `KilterModels.swift` (`note`), `KilterSessionDetailView.swift`.
- New: `Features/Kilter/KilterClimbPanel.swift`, `Features/Kilter/KilterClipStudio.swift`.
- Tests: `StudioGeometryTests` (`filterByMedia`), `KilterLogEntryTests` (`note`); "Edit all" grouping is
  already covered by `KilterWorkoutBuilderTests.testMediaGroupingByClimbSortsByOffset`.
- Knowledge graph + `decisions.md` updated in the same change.

## Acceptance criteria

- [ ] Tap a clip → big single-clip editor + Climb panel; editing angle/result/note updates History.
- [ ] "Edit all · N" on a multi-clip climb shows just that climb's clips; a per-clip trim is visible in
      "Edit all" and in the session-wide studio (one shared project).
- [ ] Workout studio behaves identically (filter defaults to `nil`).
- [ ] App + widget + watch type-check (Swift 6, 0 warnings); no platform imports added to `HighlightEngine`.
- [ ] `decisions.md` updated.

## Constraints

- On-device only; no backend/network. Edits remain pure (`StudioProjectEditor`) + clip-id-based.
- Honest verification: type-check ≠ device run for the Photos/AVFoundation preview path.

## Test plan

1. `cd ios/HighlightEngine && swift test` (unchanged) + `cd ios/App && xcodebuild test … iPhone 17 Pro`,
   incl. the new `StudioGeometryTests`/`KilterLogEntryTests`.
2. Device: tap a clip → per-clip editor + Climb panel; edit angle/result/note; "Edit all" on a ≥2-clip
   climb; confirm a per-clip trim shows in "Edit all" and the session studio.
