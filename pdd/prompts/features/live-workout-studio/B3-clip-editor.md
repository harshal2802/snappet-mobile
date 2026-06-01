# Prompt: CapCut-style non-destructive on-device clip editor

**File**: pdd/prompts/features/live-workout-studio/B3-clip-editor.md
**Created**: 2026-06-01
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: `live-workout-studio/PLAN.md` → Track B → **B3** (builds on B1 tagged media; feeds B4/B5).
**Source**: GitHub issue [#15](https://github.com/harshal2802/snappet-mobile/issues/15); `RESEARCH.md` §3.5.
**Context**: `pdd/context/project.md`, `conventions.md`, `decisions.md` (2026-05-30/31 `ReelExporter` +
Photo-Ken-Burns; B1 `SessionMedia`).

## Goal

Let the user edit each tagged video — the user's "individually adjust the split/crop, text overlay and all
the basic CapCut/edit features" — **non-destructively**, **fully on-device**, building on the existing
AVFoundation stitch. Edit state is **data, not baked pixels**; nothing renders until export.

## Context the implementer needs

- `Services/ReelExporter.swift` already does an on-device `AVMutableComposition` stitch + the async
  `AVAssetExportSession.export(to:as:)` + a `Box<T>: @unchecked Sendable` pattern + a PHAsset→`AVAsset`
  resolve, and shares **one** `makeComposition` for preview + export (decisions.md 2026-05-31, P3).
  **Reuse these patterns** — don't duplicate the PHAsset resolve.
- B1's `SessionMedia` (`Features/WorkoutTracker/SessionMedia.swift`) is the **source clip**: `localIdentifier`
  (PHAsset id), `kind` (photo/video). The editor opens from a tagged **video** in `SessionDetailView`'s gallery.
- All "basic CapCut" ops are first-class AVFoundation (RESEARCH §3.5): trim/split = time-range insertion;
  crop/transform/rotate = `AVMutableVideoCompositionLayerInstruction.setTransform` + `renderSize`; text =
  a `CALayer` tree via `AVVideoCompositionCoreAnimationTool`; speed = `scaleTimeRange`. The `renderSize`
  **closes the deferred mixed-orientation normalization gap** (project.md / decisions.md 2026-05-31).
- `HighlightEngine` stays platform-free (grep-verify). SwiftData `@Model`s register in the single
  `Core/SnappetCore.swift` `SnappetSchema.models` line, keyed by `UUID` FK (no `@Relationship`). Modules
  don't nest a `NavigationStack` — the editor is a **sheet** (which may own its own stack).

## Approach

1. **Non-destructive edit model** — `@Model ClipEdit` (`Features/WorkoutTracker/`): keyed to a source clip
   by `sessionMediaID: UUID` (+ denormalized `localIdentifier`), holding the edit list — `trimStart`/`trimEnd`
   (split = two adjacent-trim `ClipEdit`s, `splitOrder`), a normalized crop rect + an `OutputAspect`
   (9:16 / 1:1 / 16:9 / original), `speed` (0.25–4×), `textOverlays: [TextOverlay]`
   (`string`, normalized center `CGPoint`, `fontSize`, `colorHex`, `startSec`/`endSec`),
   `mutedOriginalAudio` + optional `musicTrackName`. Register in `SnappetSchema.models`.
2. **`VideoStudio` service** (`Services/`): `makeComposition(for: EditPlan) async throws -> sending
   (AVMutableComposition, AVVideoComposition?)` for BOTH preview (wrap in `AVPlayer`) and export — trimmed
   range, speed-scaled via `scaleTimeRange`, `renderSize` per the chosen aspect (mixed-orientation
   normalization), per-clip `setTransform` (crop/scale + the source's `preferredTransform`), and a `CALayer`
   tree of overlays via `AVVideoCompositionCoreAnimationTool`. Reuse `ReelExporter`'s PHAsset resolve +
   `Box`/`sending`. **Isolate the pure geometry/timing math** (trim→window, speed→duration, crop→transform,
   position→layer point, aspect→`renderSize`, split→two adjacent trims) into `ClipEditGeometry` so it is
   unit-tested with **no AVFoundation**. Snapshot the `@Model` into a `Sendable EditPlan` on the `@MainActor`
   caller so the non-Sendable model never crosses actors.
3. **Editor UI** (`Features/WorkoutTracker/ClipEditorView.swift`, a **sheet** owning its own
   `NavigationStack`): inline `VideoPlayer` over the live composition + controls — trim, split, crop/aspect,
   add/move/edit text overlay, speed, mute. Edits write to the `ClipEdit` and invalidate the preview
   (rebuild). Reached from a tagged video in `SessionDetailView`. Keep views thin — logic in
   `ClipEditorViewModel`.

## Output

- `ios/App/Snappet/Features/WorkoutTracker/ClipEditGeometry.swift` — the pure geometry/timing math.
- `ios/App/Snappet/Features/WorkoutTracker/ClipEdit.swift` — the `@Model` + `TextOverlay`.
- `ios/App/Snappet/Services/VideoStudio.swift` — composition builder + export + `EditPlan` snapshot.
- `ios/App/Snappet/Features/WorkoutTracker/ClipEditorViewModel.swift` — owns the edit + preview rebuild.
- `ios/App/Snappet/Features/WorkoutTracker/ClipEditorView.swift` — the sheet + controls (thin).
- `ios/App/Snappet/Features/WorkoutTracker/SessionDetailView.swift` — open the editor from a tagged video.
- `ios/App/Snappet/Core/SnappetCore.swift` — `ClipEdit.self` in `SnappetSchema.models` (one edit).
- `ios/App/Snappet/Core/AppModel.swift` — own + inject `VideoStudio`.
- `ios/App/SnappetTests/ClipEditGeometryTests.swift` — pure math unit tests.
- `pdd/context/decisions.md` — the B3 design + device-pending entry.

## Acceptance criteria

- [ ] `ClipEdit` registered in `SnappetSchema.models`; keyed by `sessionMediaID` FK (no `@Relationship`).
- [ ] `VideoStudio` shares one composition for preview + export; crop via layer transform, text via
      `AVVideoCompositionCoreAnimationTool`, speed via `scaleTimeRange`, `renderSize` = mixed-orientation norm.
- [ ] The pure math (trim→range w/ clamp+order, speed→duration, crop→transform, position→point, aspect→
      renderSize, split→two adjacent non-overlapping trims) is unit-tested in `SnappetTests` with no AVFoundation.
- [ ] Editor is a sheet with its own `NavigationStack`; reached from a tagged video; views thin.
- [ ] No platform import added to `HighlightEngine` (grep-verified).
- [ ] App + watch schemes build; `SnappetTests` + `WorkoutWalkthroughTests` green; `HighlightEngine` 18/18.

## Constraints

- On-device only; no backend/network/accounts. `PHVideoRequestOptions.isNetworkAccessAllowed = false`.
- SwiftData: additive `@Model` + one `SnappetSchema.models` line; UUID FK, no `@Relationship`.
- Swift 6 strict concurrency: `Box`/`sending` for AVFoundation values crossing actors; the `@Model` is
  snapshotted into a `Sendable EditPlan` on the `@MainActor` caller; export/preview are `async`.
- State verification honestly: the model + composition-building + the pure math + the editor UI are verified
  by build/tests; the actual **rendered output** (cropped, text-overlaid, speed-ramped video) needs real
  video on a device — the sim has no Photos/video. A clean build is **not** a verified rendered export.
  Export time/memory profiling is a device gate (PLAN "after B3").
