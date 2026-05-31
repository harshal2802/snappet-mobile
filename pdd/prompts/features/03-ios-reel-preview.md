# Prompt: In-app reel preview before export (P3)

**File**: pdd/prompts/features/03-ios-reel-preview.md
**Created**: 2026-05-31
**Project type**: Native iOS feature (Swift / SwiftUI / AVKit).
**Chain**: `pdd/prompts/features/PLAN-ios-to-shippable.md` → P3
**Source**: [Snappet#60](https://github.com/harshal2802/Snappet/issues/60) §B (auto-generate-then-edit; see it before you commit).
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Let the user **watch the assembled reel in-app before exporting/sharing**. Today the only way to see
the result is to export an `.mp4` and open the share sheet — there's no preview, so editing
(pin/remove/reorder) is blind. An `AVMutableComposition` *is* an `AVAsset`, so we can preview the exact
cut with an `AVPlayer` **without** an export round-trip.

## Context the implementer needs

- `ReelExporter.export(_:)` builds an `AVMutableComposition` from the `ReelPlan` (resolving each
  segment's `PHAsset` → `AVAsset`, inserting trimmed ranges), then exports `.mp4`. The composition-
  building is exactly what a preview needs.
- Swift 6: `AVMutableComposition` is not `Sendable`. Use `sending` on the builder's return so the
  freshly-built composition can cross from the exporter (nonisolated) to the `@MainActor` view model.
- `ReelViewModel` is `@MainActor`; it can own an `AVPlayer` (also not Sendable, but stays on the main actor).

## Approach

- **`ReelExporter`**: extract `makeComposition(for plan: ReelPlan) async throws -> sending AVMutableComposition`
  (the existing build loop). `export` calls it, then runs the export session. No behavior change to export.
- **`ReelViewModel`**: add `previewPlayer: AVPlayer?` and `buildPreview() async` that builds the
  composition from the *current* kept highlights + pins + order and wraps it in an `AVPlayer`. Clear/
  rebuild it when the edit set changes meaningfully (at least: a "Preview" action rebuilds it).
- **`ReelView`**: in the ready content, a "Preview" control that builds + shows an inline `VideoPlayer`
  (AVKit) of the current cut; surface the no-video case gracefully (photo-only reels can't preview yet).

## Output

- `ReelExporter.swift` — `makeComposition(for:) async throws -> sending AVMutableComposition`; `export` reuses it.
- `ReelViewModel.swift` — `previewPlayer` + `buildPreview()` (+ invalidate on edits).
- `ReelView.swift` — inline `VideoPlayer` preview + a Preview button (import AVKit).
- `decisions.md` — note: preview reuses the composition (no export), `sending` crosses the boundary.

## Acceptance criteria

- [ ] User can preview the current cut in-app before exporting; pins/removes/reorder are reflected on rebuild.
- [ ] No export is needed to preview (composition is played directly).
- [ ] Photo-only / no-video reels degrade gracefully (clear message, no crash).
- [ ] Whole app type-checks vs iOS 18 SDK (Swift 6, 0 warnings); engine untouched; `swift test` green.

## Constraints

- On-device only. Keep `HighlightEngine` platform-free (this is all app-layer AVFoundation/AVKit).
- Type-check ≠ device run — playback itself is only verifiable on a device.
