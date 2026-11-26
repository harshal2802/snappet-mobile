# Studio overlay reference (prompt 307)

What today's Studio export draws for text, stickers, climb tags and the heart-rate tile, captured
on a phone. Prompts 310 and 311 move that drawing into the Studio compositor; their output is
compared with these frames, loosely (the two renderers will not agree pixel for pixel).

- **Captured** 2026-11-26 on an iPhone 13 Pro Max (iPhone14,3, iOS 27.2.1), Debug build of
  `studio-v2` at `25a7d0c8`, with Settings → Developer → Studio render check → "Capture overlay
  reference" (prompt 304).
- **Renderer**: `AVVideoCompositionCoreAnimationTool`, the export path before prompt 310.
- **Files**: 11 frames (540×960 PNG) and `manifest.json`, exactly as the phone wrote them. The
  scenes are defined in `ios/App/Snappet/Features/WorkoutTracker/StudioOverlayReference.swift`.

| Scene | Frames | Shows |
|---|---|---|
| `ref-text` | 5, 15, 27 | Bold "REP PR"; "Second go" italic on a yellow highlight, turned 10°, at 80 %, from 0.3 s to 0.8 s |
| `ref-sticker` | 10 | **Wrong, see below** |
| `ref-climb-tag` | 10 | "Pinch Me · V5 · 40°" on a dark chip |
| `ref-hr-tile` | 3, 15, 27 | Glass hero tile, "152 BPM", zone-coloured chart |
| `ref-hr-tile-transition` | 10, 21, 35 | The tile across a 0.6 s dissolve between two clips |

## Known wrong: `ref-sticker-f010.png`

The scene has a star sticker and an orange flame sticker. The export burned each as a solid
black box (right place, size and rotation; no symbol, no colour). That is a bug in the export,
also in users' exported videos, not the look to match. It is listed in
`StudioOverlayReference.knownWrongFrames`, so comparisons skip it. Prompt 308 fixes the export;
after it, a new capture on a phone replaces this frame (and `manifest.json`) and empties that
set.

## Replacing the reference

Capture on a phone (the simulator draws no letters, and its manifest says it is not a
reference), pull the 12 files from the app's `tmp/studio-overlay-reference` folder, copy them
here, look at every PNG before committing, and say in the prompt why they changed.
`StudioOverlayReferenceCaptureTests` checks the folder is one whole phone capture.
