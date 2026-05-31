# Prompt: Render photo highlights as Ken-Burns stills in the reel (P8)

**File**: pdd/prompts/features/08-ios-photo-kenburns.md
**Created**: 2026-05-31
**Project type**: Native iOS feature (Swift / AVFoundation).
**Chain**: `pdd/prompts/features/PLAN-ios-to-shippable.md` → P8 (closes a v0.1 deferral)
**Source**: [Snappet#60](https://github.com/harshal2802/Snappet/issues/60) §5 (on-device reel assembly).
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Photos are currently **silently dropped** from the reel: `ReelExporter` filters to `kind == .video`
and only stitches video, so a photo-heavy (or photo-only) workout yields a short or empty reel even
though the engine + `ReelPlanner` already select photo highlights and reserve `photoStill` seconds for
them. Render each photo highlight as a short **Ken-Burns** (slow zoom/pan) video clip so photos appear
in both the in-app preview and the exported `.mp4`.

## Context the implementer needs

- `ReelPlan.Segment` already carries photo segments (`kind == .photo`, `duration == 0`, shown for
  `ReelPlan.photoStill` seconds). The gap is purely in the **app layer** (`ReelExporter`); the engine
  stays untouched.
- `ReelExporter.makeComposition(for:) async throws -> sending AVMutableComposition` builds the
  composition for both preview (P3) and export — so fixing it here fixes both at once.
- A still image can't be inserted into an `AVMutableCompositionTrack` directly; render it to a short
  H.264 clip first (AVAssetWriter + pixel-buffer adaptor), then insert that clip like any video.

## Approach

- **New `PhotoClipRenderer` service**: `renderClip(assetId:duration:size:) async -> URL?` — fetch the
  `PHAsset` image via `PHImageManager`, then write a `duration`-second clip with `AVAssetWriter`,
  drawing each frame with a slow interpolated zoom (≈1.0→1.1) + slight pan (Ken-Burns), aspect-filled
  to a fixed portrait `size` (1080×1920). Returns `nil` on failure (skip that photo, don't fail the reel).
- **`ReelExporter.makeComposition`**: iterate `plan.segments` **in order** (not filtered). Video →
  insert trimmed range as today. Photo → render a Ken-Burns clip and insert its full range. Keep audio
  for videos; photo clips are silent. Throw only if the composition ends up empty.

## Output

- `Services/PhotoClipRenderer.swift` (new).
- `Services/ReelExporter.swift` — interleave photo clips into `makeComposition`; update the empty guard.
- `decisions.md` — note: photos rendered to temp Ken-Burns clips; fixed portrait render size (mixed-
  orientation normalization deferred).

## Acceptance criteria

- [ ] Photo highlights appear in the assembled reel (preview + export), not dropped.
- [ ] A photo-only reel exports successfully (no longer throws `noVideoSegments`).
- [ ] Engine untouched; `swift test` still green (18); whole app type-checks vs iOS 18 SDK (Swift 6, 0 warnings).
- [ ] Full `xcodebuild` for the simulator still succeeds.

## Constraints

- On-device only; `HighlightEngine` stays platform-free. Keep Swift 6 concurrency clean (non-Sendable
  AVFoundation objects stay within nonisolated async scope).
- Honest verification: compile + build are provable here; the actual Ken-Burns *visual* needs a device/sim run.
