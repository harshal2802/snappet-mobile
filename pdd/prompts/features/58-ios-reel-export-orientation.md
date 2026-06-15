# Prompt: Flagship reel export — normalize mixed-orientation footage (P1 device-validation fix)

**File**: pdd/prompts/features/58-ios-reel-export-orientation.md
**Created**: 2026-06-15
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: PLAN-ios-to-shippable.md → P1 (flagship first real-device validation)
**Source**: GitHub issue [#139](https://github.com/harshal2802/snappet-mobile/issues/139)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

The flagship reel flow's **first real-device validation** (the long-standing P1, run 2026-06-15 on a
physical iPhone) surfaced a hard failure: exporting an auto-generated Workout Reel that mixes clip
dimensions/orientations dies with `AVFoundationErrorDomain -11800` / underlying
`NSOSStatusErrorDomain -12902` ("Export didn't finish"). On the simulator there's no real footage, so
this never reproduced. This fixes it so the headline payoff — share/save the reel — actually works on
device.

## Context the implementer needs

- `ios/App/Snappet/Services/ReelExporter.swift` builds an `AVMutableComposition` by concatenating each
  segment's source video track into **one** composition video track, then exports with
  `AVAssetExportPresetHighestQuality` and **no `AVVideoComposition`**. When the segments differ in
  `naturalSize` / `preferredTransform` (e.g. one portrait + one landscape clip), the exporter cannot
  resolve a single output format → VideoToolbox returns `-12902`. (In-app preview via `AVPlayer`
  tolerated this — only the stricter export path failed, which is why preview "worked".)
- `ios/App/Snappet/Services/VideoStudio.swift` already does the right thing for the single-clip Studio
  editor: it builds an `AVMutableVideoComposition` with a `renderSize` + a per-clip `setTransform`
  (`preferredTransform` then crop/scale). The flagship exporter never got the equivalent — this is the
  "mixed-orientation normalization (a unifying `AVVideoComposition`) still deferred" note in project.md.
- `makeComposition(for:)` is reused by **three** callers: `ReelViewModel.buildPreview`,
  `SessionHighlightViewModel`, and `ReelExporter.export`. Changing its return type touches all three.

## Approach

- Change `ReelExporter.makeComposition` to return `(AVMutableComposition, AVVideoComposition?)`. While
  inserting segments, capture each one's `start` on the timeline, oriented size, and `preferredTransform`.
- Build a single `AVMutableVideoComposition`: `renderSize` = the **first** segment's oriented size
  (rounded to even dims so the encoder is happy) — a same-orientation reel keeps native resolution; one
  `AVMutableVideoCompositionInstruction` over the whole duration with a piecewise `setTransform` per
  segment that **orients** (`preferredTransform`) then **aspect-fits/centers** (letterbox) into the
  canvas. No distortion; a differently-oriented clip letterboxes.
- Set the video composition on `session.videoComposition` (export) AND on `AVPlayerItem.videoComposition`
  in both preview callers, so preview matches the saved file (and mixed-orientation clips render upright).
- Surface the real AVFoundation error: on export failure, `os_log` the domain/code/underlying via an
  `OSLog.Logger` (developer/Console only — the user-facing message stays the clean
  `error.localizedDescription`). This is what made the `-12902` diagnosable on device.
- **`HighlightEngine` is untouched** — this is entirely the Services/ + view-model platform edge.

## Output

- `ReelExporter.swift`: tuple return + `SegmentLayout` capture + `makeVideoComposition` / `orientedSize`
  / `fitTransform` helpers + `os_log` on failure.
- `ReelViewModel.swift`, `SessionHighlightViewModel.swift`: consume the tuple, set
  `AVPlayerItem.videoComposition`.

## Acceptance criteria

- [x] A mixed-orientation auto reel **exports successfully on device** (verified on a Dance reel, MrRobot 2026-06-15).
- [x] Preview orientation matches the exported reel.
- [x] Export failures log the AVFoundation domain/code/underlying (Console); user message stays clean.
- [x] Engine `swift test` green; app unit suite green; type-checks Swift 6.
- [x] No platform imports added to `HighlightEngine`.

## Constraints

- On-device only; no backend. The export render is device/footage-dependent — the off-device gate is the
  unit suite + build; real-footage success is a **device-verified** result (recorded in decisions.md).

## Test plan

1. `cd ios/HighlightEngine && swift test` (must stay green — engine untouched).
2. App unit suite on device/sim; `xcodebuild build` for the device.
3. On device: open a reel mixing portrait + landscape clips, **Share reel** → exports + share sheet
   appears; preview renders upright. (Done 2026-06-15.)
