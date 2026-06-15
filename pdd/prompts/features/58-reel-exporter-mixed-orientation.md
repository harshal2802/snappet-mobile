# Prompt: Fix ReelExporter mixed-orientation export crash (AVFoundation -11800 / OSStatus -12902)

**File**: pdd/prompts/features/58-reel-exporter-mixed-orientation.md
**Created**: 2026-06-15
**Project type**: Native iOS bug fix (Swift / AVFoundation) — code lands in this repo.
**Chain**: P1 flagship reel validation (project.md)
**Source**: GitHub issue [#139](https://github.com/harshal2802/snappet-mobile/issues/139)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Fix the `AVFoundationErrorDomain -11800 / NSOSStatusErrorDomain -12902` crash that fires when
exporting a Workout Reel whose segments have mixed orientations or differing `naturalSize` values.
`ReelExporter` stitched clips into a single composition track and called
`AVAssetExportPresetHighestQuality` with **no `AVVideoComposition`** — VideoToolbox can't resolve
one output format when the track contains segments with different geometry, producing `-12902`.
`VideoStudio` already solved this (the mixed-orientation normalization documented in decisions.md
2026-05-31, B3). This prompt closes the same gap in the flagship reel exporter.

## Context the implementer needs

- **`ReelExporter.makeComposition`** (ios/App/Snappet/Services/ReelExporter.swift) builds a
  single `AVMutableCompositionTrack` from multiple source segments; each source asset may have a
  different `naturalSize` and `preferredTransform`. Without an `AVVideoComposition` specifying a
  fixed `renderSize`, VideoToolbox hits the `-12902` "can't determine one format" error.
- **`VideoStudio.build`** (ios/App/Snappet/Services/VideoStudio.swift) already has the fix: it
  builds an `AVMutableVideoComposition` with `renderSize = orientedSize(naturalSize, preferred)`
  and a per-clip `setTransform(preferred.concatenating(crop), at: .zero)` — the mixed-orientation
  normalization. `ReelExporter` needs the same treatment but across *multiple* segments (piecewise
  `setTransform` per segment start time).
- **`ClipEditGeometry.fitTransform`** (Features/WorkoutTracker/ClipEditGeometry.swift) already
  provides the aspect-fit (contain, min-scale) transform from an oriented source size into a rect —
  exactly what each reel segment needs to letterbox/pillarbox into the canvas.
- **`ReelViewModel.buildPreview`** wraps the composition in `AVPlayer(playerItem: AVPlayerItem(asset:))`
  without setting `videoComposition`. After this fix, it must apply the returned composition to
  `AVPlayerItem.videoComposition` so preview matches export.

## Approach

1. **`ReelExporter.makeComposition`** — change return type to
   `sending (AVMutableComposition, AVVideoComposition)`. While iterating segments, load each
   source track's `naturalSize` and `preferredTransform` alongside the existing
   `insertTimeRange` call. Record `(prefT, natSize, segmentStart)` tuples in order. After the
   loop, determine `canvas` = first segment's oriented size; build one
   `AVMutableVideoCompositionInstruction` covering the full composition duration with one
   `AVMutableVideoCompositionLayerInstruction` that calls `setTransform(prefT.concatenating(fit), at: start)`
   for each segment, where `fit = ClipEditGeometry.fitTransform(sourceSize: orientedSize, into: canvasRect)`.
2. **`ReelExporter.export`** — destructure the tuple, set `session.videoComposition`, wrap the
   `session.export` call in `do/catch` and `os_log` the AVFoundation domain/code/underlying for
   field diagnosis.
3. **`ReelViewModel.buildPreview`** — destructure the tuple, set `item.videoComposition` on the
   `AVPlayerItem` so preview orientation matches export.

## Output

- `ios/App/Snappet/Services/ReelExporter.swift` — makeComposition returns tuple, orientation
  normalisation, piecewise setTransform, os_log on export failure.
- `ios/App/Snappet/Features/Reel/ReelViewModel.swift` — buildPreview applies videoComposition.
- `ios/App/SnappetTests/ReelExporterOrientationTests.swift` — new: pure CGAffineTransform /
  ClipEditGeometry geometry tests (no device): orientedSize algebra, letterbox/pillarbox scale +
  offset, combined preferred+fit bounding-box invariant.
- `pdd/context/decisions.md` — record the piecewise-setTransform decision.

## Acceptance criteria

- [x] Mixed-orientation reel exports successfully on device (verified on a Dance reel, MrRobot).
- [x] Preview orientation matches the exported reel (`AVPlayerItem.videoComposition` applied).
- [x] Engine `swift test` green (HighlightEngine not touched); app unit suite green.
- [x] Export errors `os_log` AVFoundation domain/code/underlying for field diagnosis.
- [x] `decisions.md` updated.

## Constraints

- On-device only; no backend. `HighlightEngine` not touched (no platform imports added).
- Canvas = first segment's oriented size (simplest stable anchor; all later segments letterbox in).
- Photo segments (from `PhotoClipRenderer`) treated identically to video: load their rendered
  track's `naturalSize`/`preferredTransform` for the layer instruction.

## Test plan

1. `cd ios/HighlightEngine && swift test` — engine unaffected, should be green.
2. New `ReelExporterOrientationTests` run via
   `xcodebuild test -scheme Snappet -destination 'platform=iOS Simulator,name=iPhone 16 Pro'`
   (pure math, no device required).
3. On-device: build a reel mixing a portrait and a landscape clip → export → verify no crash and
   correct framing (letterbox/pillarbox). Preview the reel before exporting to confirm preview
   matches export orientation.
