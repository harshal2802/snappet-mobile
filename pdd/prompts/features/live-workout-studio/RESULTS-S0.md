# S0 spike RESULTS — on-device studio export profiling

**Created**: 2026-06-04
**Device**: "MrRobot" — iPhone 13 Pro Max (iPhone14,3), iOS, free Personal Team signing.
**Harness**: `SnappetTests/StudioComposerProfilingTests` — synthesizes a 1080x1920 H.264 clip on-device
(`AVAssetWriter`, no Photos needed), builds a 4-clip / ~16 s timeline via the new
`StudioComposer.assemble(resolved:aspect:)` seam, and exports it. Device-only (skips on the simulator).

## Verdict: **GO** — the export path works on-device and is fast; S2+ is unblocked.

### What the device measured (after the fixes below)
| Path | Result | Time (1080x1920) |
|---|---|---|
| **Multi-clip stitch** (passthrough, no `videoComposition`) | works | ~0.05-0.10 s to remux 16 s (effectively free) |
| **Transform/effects** (`HighestQuality` + our `AVMutableVideoComposition`) | **works** | **~0.76 s for a 4 s clip (~0.2x realtime)** -> a 16 s timeline ~3 s |

Compute is NOT the constraint — transcode + transform runs at ~0.2x realtime with headroom for the S2+
effects (filters/transitions/keyframes ride this same path). The design's worry about export time/memory
is a non-issue at this scale.

### The bug hunt (the spike earned its keep)
The transform export initially failed `AVFoundationError -11838` ("operation not supported", underlying
`OSStatus -16976`) at validation (0.00 s) for EVERY preset (`HighestQuality`/`HEVC`/`1920x1080`), while
passthrough worked. Ruled out, one device run each: preset; source pixel format (32ARGB->32BGRA); color
metadata (added ITU-R 709 tags); `AVMutableVideoComposition()` vs `videoComposition(withPropertiesOf:)`;
and clip count (1 vs 4 — both failed). **Root cause: an empty audio track.** `StudioComposer.assemble`
added an audio track UP FRONT; a source with NO audio (the synthetic clip — and real audio-less videos)
left it 0-duration, which the on-device videoComposition export rejects (passthrough tolerates it).

### Fixes applied (`StudioComposer`)
1. **Lazy audio track** — create it only when a clip actually has audio (the real fix).
2. **One layer instruction per track** — was one per clip on the same track (a malformed
   `AVVideoComposition`); now one instruction with a per-clip `setTransform(at:)`.
3. **`videoComposition(withPropertiesOf:)`** as the base (carries color/format) instead of a bare init.
4. Refactor: a Photos-decoupled `assemble(resolved:aspect:)` seam so the export is device-testable
   without a Photos library.

**Correction to the earlier read**: `VideoStudio` (the B3 clip editor) ALREADY creates its audio track
lazily, so it does NOT have this bug — the clip-editor export is fine. Only `StudioComposer` added the
empty track.

### Status of the spike
`StudioComposerProfilingTests` is committed and PASSES on-device: it exports a 4-clip stitch AND the
transform/videoComposition path, asserting both succeed and finish well under the bound — a standing
on-device perf guard for the studio export. (Skips on the simulator, where export timing is meaningless.)

### Next (S2+ is GO)
Build the custom `AVVideoCompositing` for filters/LUTs -> transitions -> keyframed overlays, profiling
each on-device via this spike. No export-mechanism blocker remains.
