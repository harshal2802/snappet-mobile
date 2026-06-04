# S0 spike RESULTS — on-device studio export profiling

**Created**: 2026-06-04
**Device**: "MrRobot" — iPhone 13 Pro Max (iPhone14,3), iOS, free Personal Team signing.
**Harness**: `SnappetTests/StudioComposerProfilingTests` — synthesizes a 1080×1920 H.264 clip on-device
(`AVAssetWriter`, no Photos needed), builds a 4-clip / ~16 s timeline via the new
`StudioComposer.assemble(resolved:aspect:)` seam, and exports it. Device-only (skips on the simulator).

## Verdict: **CONDITIONAL GO** — compute is ample; the effects-export path is **broken on-device** and must be fixed before S2+.

### What the device measured
| Path | Result | Time (16 s / 4-clip / 1080×1920) |
|---|---|---|
| **Multi-clip stitch** (passthrough, no `videoComposition`) | ✅ **works** | **~0.08–0.10 s** (remux — effectively free) |
| **Transform/effects** (any transcode preset **+ our `AVMutableVideoComposition`**) | ❌ **fails** | n/a — `AVFoundationErrorDomain -11838` "operation not supported", underlying `OSStatus -16976`, at validation (0.00 s) |

Presets tried for the transform path, all failing identically: `HighestQuality`, `HEVCHighestQuality`,
`1920x1080`. The failure is the **`AVMutableVideoComposition` itself**, not the preset, source pixel
format (32ARGB→32BGRA made no difference), or render size (1080×1920 is valid).

### Two real bugs the spike surfaced
1. **Fixed here**: `StudioComposer.assemble` created **one layer instruction per clip, all for the same
   single video track, in one instruction** — a malformed `AVVideoComposition`. Now uses **one** layer
   instruction with a per-clip `setTransform(at:)` (piecewise-constant transform across the cuts).
2. **Open (the gate)**: even after fix #1, applying the hand-built `AVMutableVideoComposition` is rejected
   by the on-device encoder (-11838). **The same `AVMutableVideoComposition()` + manual-instruction
   pattern ships in `VideoStudio` (the B3 clip editor), which was never device-tested — so clip-editor
   *export* is almost certainly broken on real hardware too.**

### Implications for the plan
- **Capacity is not the constraint.** A 16 s multi-clip stitch remuxes in ~0.1 s; the device has plenty
  of headroom for transcode + effects. The design's worry was export time/memory — that's a non-issue at
  this scale.
- **The export *mechanism* is the constraint.** Before building S2+ (filters/transitions/keyframes — all
  ride the transcode-with-`videoComposition` path), the video-composition export must be made to work
  on-device. Likely fixes to try (next task, device-verified via this same spike — flip it from skip to a
  timing assertion):
  1. Base the composition on `AVMutableVideoComposition(propertiesOf:)` and layer transforms onto its
     instructions, rather than a bare `AVMutableVideoComposition()`.
  2. If that still fails, move to a **custom `AVVideoCompositing`** (the S2 compositor anyway) and/or an
     `AVAssetReader`/`AVAssetWriter` export pipeline for full control.
  3. Apply the same fix to `VideoStudio` so the shipped clip editor exports on a device.

### Status of the spike
`StudioComposerProfilingTests` is committed and **green**: it asserts the stitch baseline exports
on-device and **skips** with a diagnostic on the videoComposition gap. When the export is fixed it starts
asserting the transform export time — turning this S0 into a standing on-device perf guard.
