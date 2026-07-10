# Prompt: Clip bake lane — "Save to original" (revertible + destructive) with feed stand-down

**File**: pdd/prompts/features/117-clip-bake-lane.md
**Created**: 2026-07-10
**Project type**: Native iOS feature (Swift / SwiftUI / Photos) — code lands in this repo.
**Chain**: prompt 115 (extended HR window) → 116 (live-reflect) → **117 (bake lane — lane ② of the
approved model)**.
**Source**: user request — full parity for speed/filters/text in the feed without per-cell
compositions, plus "will there be an option to make the in-place update to the original video in
gallery?" (answer: yes — revertible; and a destructive space-freeing variant, both approved).
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Wireframes**: `docs/ux-research/clips-feed-convergence/wireframes.html` §4 (approved)

## Goal

Render a scoped Studio project's FULL edit — trims, speed, filters, text/sticker overlays, the HR
tile at the user's placement — INTO the Photos asset itself, once, at an explicit Export-menu
action. Every surface (the Clips feed, Messages, Photos) then shows the baked pixels with zero
per-cell composition cost. Two variants with the storage truth stated in the UI: **Save to original
(revertible)** — `PHContentEditingOutput` rendition, Photos keeps the original, "Revert to
Original" works, **no space is freed**; **Replace original (frees space)** — save-as-new +
delete-original (iOS system confirm; Recently Deleted ~30 days), with the app's records re-pointed
at the replacement in the same save.

## Context the implementer needs

- The bake targets ONE asset: gate on `ClipBakePlan.bakeTarget` (every visible video clip
  references one `localIdentifier` — the "Edit this clip" scoped studio, or split parts).
- Baked pixels + the feed's live overlay would double-render: `SessionMedia.isBaked` (additive
  optional) stands the feed down — `MediaInput.from` strips the live-reflect `edit` and
  `ClipHROverlay.make` returns nil (name tag only); the poster shows a green BAKED chip instead of
  EDITED. The feed rebuild key is the project's `updatedAt` — a revertible bake changes only
  `SessionMedia`, so `bake()` bumps it explicitly.
- Destructive re-pointing must move `offsetSec` forward by the earliest kept `trimStart` (the new
  asset IS the trimmed composition) and reset the project's trims — `ClipBakePlan` owns the math.
- Deletion runs in a second change block: a cancelled system dialog must not undo the bake (the new
  asset survives; the original just lingers).
- Revert detection: `PHAssetResource` `.fullSizeVideo` presence; probe at Studio-open
  (`reconcileBakedFlags`), never per feed rebuild; a nil probe (sim/iCloud-evicted) clears nothing.
- Never automatic: bake ties to the Export menu, not to per-edit saves (each bake is a full render).

## Output

- New: `Features/WorkoutTracker/ClipBakePlan.swift` (pure), `Services/ClipBakeService.swift`
  (device-only Photos writes), `SnappetTests/ClipBakePlanTests.swift`
- Edits: `SessionMedia.swift` (isBaked), `FeedMedia.swift`/`FeedInputs.swift` (MediaInput.isBaked +
  edit stripping), `ClipHROverlay.swift` (stand-down), `ClipsFeedView.swift` (BAKED chip),
  `StudioEditorViewModel.swift` (bake state machine + re-pointing + reconcile),
  `StudioEditorView.swift` (three-destination Export menu + destructive confirm + result alerts)
- Docs: knowledge-graph node/edges, `decisions.md`, this prompt.

## Acceptance criteria

- [ ] Export menu shows the two bake options only for single-source-asset projects with a tracked
      `SessionMedia` row; copy states "revertible ≠ smaller" and the destructive caveats inline.
- [ ] Revertible bake: rendition written with `com.snappet.app.bake` adjustment data; `isBaked`
      stamped; the feed recomposes (BAKED chip, no live overlay, raw playback) without manual refresh.
- [ ] Destructive bake: new asset created, original deleted behind the iOS confirm; `SessionMedia`
      (identifier/offset/duration) and the project timeline re-pointed in one save; a cancelled
      deletion still leaves a consistent re-pointed state.
- [ ] "Revert to Original" in Photos → next Studio open clears `isBaked` (feed overlay stands back up).
- [ ] Limited/denied Photos auth → an actionable error, never a crash.
- [ ] Pure logic (`ClipBakePlan`, stand-down) unit-tested without a device; suites green.
- [ ] `decisions.md` updated; `HighlightEngine` untouched.

## Constraints

- Photos writes are device-only; the simulator path must degrade gracefully (probe returns nil).
- No automatic bakes; no bake for multi-asset compositions (export-as-new covers them).

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'` — `ClipBakePlanTests` + full suite.
2. `LiveWorkoutStudioWalkthroughTests` (Export button semantics unchanged: existence-checked only).
3. Device leg (MrRobot): revertible bake a trimmed+tail clip → feed shows BAKED chip, baked pixels,
   no double overlay; Photos "Revert to Original" → reopen Studio → feed overlay returns.
   Destructive bake a throwaway clip → confirm re-pointing (session detail + feed follow), the iOS
   dialog, and Recently Deleted behaviour.
