# Prompt: Studio export — forward per-clip HR to the composer (WYSIWYG fix)

**File**: pdd/prompts/features/118-studio-export-clip-hr-forwarding.md
**Created**: 2026-07-10
**Project type**: Native iOS bugfix (Swift / AVFoundation) — code lands in this repo.
**Chain**: Studio HR overlay line (prompts 115 extended-window → 116 convergence → 117 bake) — a regression fix on that path.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

The exported Studio video burned the **whole-session** HR overlay instead of the **per-clip capture
window** the editor shows — a WYSIWYG break. On a ~9s clip the editor tile read `PEAK 108 / AVG 103 /
KCAL 4 / Z1 · Recovery` (a short rising warm-up curve), but the exported file read `PEAK 150 / AVG 105
/ KCAL 584 / Z3 · Aerobic` with a dense multi-minute curve — i.e. the entire session's HR. Users edit
the clip-scoped tile, so the export must match it.

## Context the implementer needs

Two render paths feed the HR tile and they must agree (WYSIWYG):

- **Editor preview** draws the tile via SwiftUI — `StudioEditorViewModel.previewTile` → `previewHR`
  (its own per-clip slice). This path was always correct.
- **Export** burns the tile in via Core Animation — `StudioEditorViewModel.renderComposition()` builds
  `clipHRContent()` (per-clip windows, keyed by clip id) and passes it as `clipHRByID` to
  `StudioComposer.export(...)` → `makeComposition(...)` → `assemble(...)` →
  `StudioOverlays.makeAnimationTool(...)`.

`StudioOverlays.makeAnimationTool` draws per-clip tiles when `clipHR` is non-empty, otherwise falls
back to the **session-wide** `hrTile` over the whole timeline. That fallback is the observed symptom.

**Root cause:** `StudioComposer.makeComposition(...)` declares a `clipHRByID` parameter but its call to
`assemble(...)` **omitted the argument**, so `assemble` received the default `[:]`. `assemble` then
built an empty `placedHR`, and `makeAnimationTool` took the session-wide fallback. The editor preview
was unaffected because it never goes through this composer path (and `rebuildPreview` calls
`makeComposition(forPlayback: true)`, which drops the overlay tool entirely). The bug was invisible
until export. Note the transition path (`assemble` → `assembleWithTransitions`) already forwarded
`clipHRByID` correctly — only the first hop, `makeComposition` → `assemble`, dropped it.

## Approach

One-line forwarding fix in `ios/App/Snappet/Services/StudioComposer.swift`: pass `clipHRByID:
clipHRByID` in the `makeComposition(...)` → `assemble(...)` call. No behavior change to the value logic
(`HROverlayValues`), the placement math (`StudioHRPlacement`), or the overlay renderer.

## Output

- `ios/App/Snappet/Services/StudioComposer.swift` — thread `clipHRByID` through the dropped call.

## Acceptance criteria

- [x] Exported Studio video's burned-in HR tile matches the editor tile for the clip under edit
      (per-clip window: Z1 · Recovery, PEAK 108, KCAL 4, short curve — not the session-wide values).
      Device-verified on MrRobot.
- [x] App type-checks / builds for device (Debug-iphoneos) with the fix.
- [x] No platform imports added to `HighlightEngine` (untouched).
- [x] `decisions.md` note added for the WYSIWYG two-path invariant.

## Constraints

- On-device only; the render (`assemble`) needs a real `AVAsset`, so it is not unit-testable without
  the device seam (the S0 profiling spike is the only synthetic-video harness).
- State verification honestly: this is confirmed by a device export + eyeball against the editor, not
  by a simulator run.

## Test plan

1. Build for device (`make ios-device`), install on MrRobot.
2. Open a Quick Session clip in Studio with a per-clip HR tile; note the editor tile's zone/peak/kcal.
3. Export; scrub the exported file — the burned-in tile must show the SAME clip-window values, not the
   session-wide curve. (Verified 2026-07-10: now matches.)
