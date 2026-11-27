# Studio overlay reference (prompt 307)

What today's Studio export draws for text, stickers, climb tags and the heart-rate tile, captured
on a phone. Prompts 310 and 311 move that drawing into the Studio compositor; their output is
compared with these frames, loosely (the two renderers will not agree pixel for pixel).

- **Captured** 2026-11-26 on an iPhone 13 Pro Max (iPhone14,3, iOS 27.2.1), Debug build of
  `studio-v2` at `25a7d0c8`, with Settings → Developer → Studio render check → "Capture overlay
  reference" (prompt 304).
- **Renderer**: `AVVideoCompositionCoreAnimationTool`, the export path before prompt 310 (the
  manifest's `renderer` string, "before prompt 305", was written when that move was planned as 305).
- **Files**: 11 frames (540×960 PNG) and `manifest.json`, exactly as the phone wrote them. The
  scenes are defined in `ios/App/Snappet/Features/WorkoutTracker/StudioOverlayReference.swift`.

| Scene | Frames | Shows |
|---|---|---|
| `ref-text` | 5, 15, 27 | Bold "REP PR"; "Second go" italic on a yellow highlight, turned 10°, at 80 %, from 0.3 s to 0.8 s |
| `ref-sticker` | 10 | **Wrong, see below** |
| `ref-climb-tag` | 10 | "Pinch Me · V5 · 40°" on a dark chip. One line only: the capture passes the tag's raw text, while the editor adds an "Attempt 2" line before a real export, so a two-line chip has no reference |
| `ref-hr-tile` | 3, 15, 27 | Glass hero tile, "152 BPM", zone-coloured chart |
| `ref-hr-tile-transition` | 10, 21, 35 | The tile across a 0.6 s dissolve between two clips; frame 21 is **wrong, see below** |

## Known wrong: `ref-sticker-f010.png`

The scene has a star sticker and an orange flame sticker. The export burned each as a solid
black box (right place, size and rotation; no symbol, no colour). That is a bug in the export,
also in users' exported videos, not the look to match. It is listed in
`StudioOverlayReference.knownWrongFrames`, so comparisons skip it. Prompt 308 fixes the export;
after it, a new capture on a phone replaces this frame (and `manifest.json`) and removes it from
that set.

## Known wrong: `ref-hr-tile-transition-f021.png`

Frame 21 is 0.7 s, exactly where the first clip's tile hands over to the second's. Both tiles'
time windows include that instant, so both are drawn: the glass is darker and the chart has two
markers. Any other frame shows one tile; in a real export this is one frame at most. The Core
Animation path that does this is replaced by prompt 311, which must draw exactly one tile on that
frame, so this frame stays listed in `StudioOverlayReference.knownWrongFrames`; frames 10 and 35
are the reference for the tile through a dissolve.

## Replacing the reference

Capture on a phone (the simulator draws no letters, and its manifest says it is not a
reference), pull the 12 files from the app's `tmp/studio-overlay-reference` folder, copy them
here, look at every PNG before committing, and say in the prompt why they changed.
`StudioOverlayReferenceCaptureTests` checks the folder is one whole phone capture.
