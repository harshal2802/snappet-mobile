# Prompt: Studio overlays & grids — split grade filter, climb-name overlay, overlay timeline, PiP grids

**File**: pdd/prompts/features/21-ios-studio-overlays-grids.md
**Created**: 2026-06-05
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: follow-up to `20-ios-kilter-clip-scoped-editing.md` (studio reaches Kilter; this enriches the editor).
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Four user-requested studio/browse improvements, shipped together: (1) the Kilter browse bar's single
"Grade" chip (a From+To picker) becomes **two independent chips** (Min / Max); (2) a **climb-name
overlay** that overlays the climb's name on a clip the way the HR chart does — auto-filled with
**name · grade · angle**, a **setter on/off** toggle, and freely editable text; (3) a **timeline lane**
to control **how long** a text / climb-name / PiP overlay stays on screen (drag to move, handles to
trim); (4) **PiP "grids"** — resize PiP clips with **corner handles**, one-tap **collage layouts**
(split-screen presets), and **alignment guides + snap** while placing them.

## Context the implementer needs

- Overlays are one Codable value type `OverlayItem` on the `StudioProject` `@Model`, already carrying
  `startSec`/`endSec`, a normalized centre, opacity keyframes, and `kind ∈ {text, sticker, video}`.
  Text/sticker render export-only via `StudioOverlays.makeAnimationTool` (Core Animation); `.video`
  (PiP) is a real second track via `StudioComposer.insertPiPTrack`. All edits are pure
  (`StudioProjectEditor`) and the preview is a WYSIWYG SwiftUI layer (`StudioOverlayCanvas`) reading
  the same normalized values export reads.
- PiP previously used a single uniform `scale` (a square-of-canvas box) — too rigid for split-screen
  cells or free corner resize.
- Climb metadata is available without the SQLite catalog from the persisted `KilterLogEntry`
  (`climbName`/`gradeLabel`/`angle`, keyed by `(sessionId, climbUUID)`); the **setter** comes from the
  read-only `KilterCatalog.shared.climb(uuid)`. A clip ties to a climb via
  `SessionMedia.assignedClimbUUID` (looked up from `TimelineClip.sessionMediaID`).

## Approach

- **Grade split** (`KilterRootView`): two `Menu` chips (`kilter.minGrade` / `kilter.maxGrade`) over the
  same `gradeScale`, with `.onChange` coupling so the range stays valid. No model/query change
  (`KilterCatalog.list` already min/max-swaps).
- **Climb-name overlay**: add `OverlayItem.Kind.climbName` (renders like text but as a lower-third chip);
  a **pure** `KilterClimbCaption.caption(...)` formats the string; the VM resolves the climb for the
  selected/first clip and adds an `OverlayItem(kind: .climbName, …)`. Export via a new
  `StudioOverlays.climbNameLayer` (text + rounded background); preview via a `.climbName` chip case.
  Reuses the existing overlay timeline + keyframes (no separate config).
- **Overlay timeline**: `StudioProjectEditor.setOverlayTimeRange` (pure, clamped, min 0.2s); a second
  lane in `StudioTimelineView` (`OverlayBar` with body-move + edge-trim, sharing the clip lane's
  `pps`/offset); selection is shared with the bottom overlay controls.
- **PiP grids**: `OverlayItem` gains optional per-axis `normalizedWidth/Height` (default = `scale`,
  back-compatible decode) + a `pipSize` accessor; `ClipEditGeometry.pipRect(center:size:canvas:)`
  overload; a **pure** `StudioGridLayout` (collage `Preset` cells + `snap` → alignment guides);
  `StudioProjectEditor.setOverlayFrame`/`applyPiPGrid`; corner-resize handles + live guides in
  `StudioOverlayCanvas`; the composer uses `pipSize`. A "Grid" tool sheet (presets + snap toggle).

## Output

- Modify: `KilterRootView.swift`, `StudioProject.swift` (`OverlayItem`), `ClipEditGeometry.swift`,
  `StudioProjectEditor.swift`, `StudioEditorViewModel.swift`, `StudioOverlayCanvas.swift`,
  `StudioTimelineView.swift`, `StudioEditorView.swift`, `StudioOverlays.swift`, `StudioComposer.swift`.
- New: `Features/Kilter/KilterClimbCaption.swift`, `Features/WorkoutTracker/StudioGridLayout.swift`.
- Tests: `KilterClimbCaptionTests`, `StudioGridLayoutTests`, plus cases in `ClipEditGeometryTests`
  (per-axis `pipRect`) and `StudioProjectEditorTests` (`setOverlayContent`/`setOverlayTimeRange`/
  `setOverlayFrame`/`applyPiPGrid`).
- Knowledge graph + `decisions.md` updated in the same change.

## Acceptance criteria

- [ ] Browse shows two grade chips; each filters independently; Min above Max drags Max along.
- [ ] "Climb" adds a lower-third name·grade·angle chip; Show setter appends "· by …"; Edit text frees it;
      it renders in **export**, time-gated to its window.
- [ ] The timeline overlay lane moves/trims an overlay's on-screen window; preview/export honor it.
- [ ] A collage preset tiles ≥2 PiPs; corner handles resize per-axis; dragging shows guides + snaps;
      export matches the preview. Old projects (no per-axis size) render unchanged.
- [ ] App + widget + watch type-check (Swift 6, 0 warnings); no platform imports added to `HighlightEngine`.
- [ ] `decisions.md` updated.

## Constraints

- On-device only; no backend/network. Edits remain pure (`StudioProjectEditor`) + value-typed.
- Honest verification: type-check ≠ device run for the Photos/AVFoundation preview + export paths.

## Test plan

1. `cd ios/HighlightEngine && swift test` (unchanged) + `cd ios/App && xcodebuild test … iPhone 16 Pro`,
   incl. the new `KilterClimbCaptionTests` / `StudioGridLayoutTests` and the added editor/geometry cases.
2. Device: split-grade browse; add a climb overlay (setter toggle + edit); move/trim it in the timeline;
   add 2 PiPs → apply a grid, corner-resize, confirm guides/snap and that export matches the preview.
