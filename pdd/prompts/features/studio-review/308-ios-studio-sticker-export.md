# Prompt: Stickers burn into an exported video as the symbol, not a black box

**File**: pdd/prompts/features/studio-review/308-ios-studio-sticker-export.md
**Created**: 2026-11-26
**Project type**: iOS
**Chain**: a bug found by prompt 304's overlay reference on a phone; done alongside prompt 307
(which commits that reference). Built on `studio-v2`.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## What changes for the user

A sticker added in the Studio (a star, a flame, any symbol) is in the exported or baked video as
that symbol, in the colour picked for it, the way the editor shows it. Before this, a phone's
export burned every sticker in as a solid black rectangle of the right size, place and turn.

## Problem

On 2026-11-26 the debug "Studio render check" → "Capture overlay reference" was run on an
iPhone 13 Pro Max (iOS 27.2.1). It renders fixed scenes through today's Studio export, where the
Core Animation tool draws the overlays. Text, the climb tag and the heart-rate tile came out
right. The `ref-sticker` scene (`StudioOverlayReference`: `star.fill` in the default white at
(0.3, 0.3); `flame.fill` in #FF9500 at scale 2, turned −20°, at (0.7, 0.7)) came out as two solid
black boxes: frame 10 has a 115 × 115 black square centred on (162, 288) and a 230 × 230 black
square, turned, centred on (378, 672). No star or flame shape, no colour. (The small black square
in the top-left corner is the test video's own corner mark.) The preview
(`StudioOverlayCanvas`, `Image(systemName:)` + `.foregroundStyle`) draws both right.

## Cause

`StudioOverlays.stickerLayer` set

```swift
layer.contents = UIImage(systemName: name, withConfiguration: config)?
    .withTintColor(color, renderingMode: .alwaysOriginal).cgImage
```

A symbol image is drawn by UIKit from its vector data; the tint is applied only when UIKit draws
the image. Its `.cgImage` is the untinted template raster: black ink. On top of that, in the
export the raster's transparent pixels came out black too, so each sticker was a solid black
rectangle the size of the symbol's aspect-fit box (the flame's is taller than wide, as in the
phone's frame). The measurements are in "Evidence".

## Change

- `StudioOverlays.stickerImage(symbol:colorHex:pointSize:scale:)` (new, internal): draws the
  tinted symbol with `UIGraphicsImageRenderer` into a bitmap we own: `opaque = false`,
  `preferredRange = .standard` (8-bit sRGB, the colour space the text layers' colours are in),
  `scale = 2` (as the text layers' `contentsScale`). An unknown symbol name draws `circle.fill`,
  which the old doc comment promised and the old code did not do (it drew nothing).
- `stickerLayer` hands that bitmap to the layer, with `contentsScale` = the bitmap's scale, and
  sizes the layer to the symbol's own size and aspect, centred on the overlay's position. Before,
  the layer was a `side × side` square and `resizeAspect` shrank the symbol to fit it; the
  preview draws the symbol at its own size at the same point size, so the export is now a little
  closer to the preview (a symbol is not square).

### Every place that hands an image to an export layer

Searched `Services/`, `Features/Reel/`, `Features/Feed/` (`ClipHROverlay`, `ClipShareService`),
`ReelExporter` and `StudioComposer` for `.contents =`, `.cgImage`, `UIImage(systemName:`,
`UIImage(named:` and `withTintColor`. `stickerLayer` was the only layer given an image. The heart-
rate tile, the climb tag, text, the Clips share's title block and the reel scorebug are text,
shape and gradient layers. The reel exporter and "Share with heart rate" go through
`StudioOverlays.makeAnimationTool` too, so a sticker on either path gets the same fix.

## Evidence

Measured on the iPhone 17 Pro simulator (iOS 26.5), `StudioStickerExportTests`:

- **The simulator shows the same bug.** With the old line put back for one run, the exported
  `ref-sticker` frame 10 was the phone's picture, box for box: 12 571 of 13 225 pixels of the
  star's box and 41 336 of 53 361 of the flame's turned box near black, the star's middle
  (0, 0, 0), each star-box corner (0, 0, 0) where the video is (199, 61, 61). The export test
  failed with 8 assertions. So the old memory note ("the simulator's Core Animation tool draws
  shapes but no glyphs") does not hide stickers: the tool draws a layer's bitmap there.
- **The old raster** (`flame.fill`, 230 pt, tinted #FF9500, `.alwaysOriginal`): 581 × 746 px at
  3×, 8 bits, premultiplied RGBA, sRGB; 282 075 opaque pixels, mean colour **(0, 0, 0)**. The
  tint is not in it.
- **After the fix**, the same frame shows a white star at upper left and an orange flame at lower
  right over the four coloured quarters, nothing black but the test video's corner mark. All three
  tests pass.

## Tests

`StudioStickerExportTests` (new):

- `testStickerImageIsTheTintedSymbolOnATransparentBackground`: the bitmap for `flame.fill` in
  #FF9500 has transparent corners, covers more than a quarter of its box, and every opaque pixel
  is orange (±6); an unreadable colour falls back to white; an unknown name still gives a bitmap.
- `testExportedStickerFrameShowsTheSymbolsNotBlackBoxes`: renders `ref-sticker` frame 10 through
  `StudioComposer.export` on the simulator (the golden-frame harness's `StudioGoldenRenderer`) and
  the bare clip's same frame. The star's middle is white and the flame's body orange (±30); the
  four corners of each OLD black box show the bare video (±24); fewer than 0.5 % of the pixels in
  each old box are near black.
- `testOldPathCGImageForTheRecord`: prints what the old path's `.cgImage` is (no assertion).

No golden scene was added. The golden images are compared with a tolerance meant for whole frames
and the simulator's golden scenes have no overlays drawn by the Core Animation tool; a pixel test
says exactly what is wrong. No golden image changed. `StudioOverlayReference` and
`GoldenFrames/OverlayReference/` are prompt 307's and are not touched.

### Runs (iPhone 17 Pro simulator, iOS 26.5)

- `StudioStickerExportTests` with the old line put back: Executed 3 tests, with 8 failures. With
  the fix: Executed 3 tests, with 0 failures.
- Full unit suite (`SnappetTests`, every golden-frame test unchanged): Executed 3776 tests, with
  11 tests skipped and 0 failures.
- UI: `StudioSelfCheckUITests`, `LiveWorkoutStudioWalkthroughTests`, `StudioHRTimingUITests`:
  Executed 3 tests, with 0 failures.
- Device compile (`generic/platform=iOS`, Debug): BUILD SUCCEEDED, no warnings in `StudioOverlays.swift`.

## Not done

- The phone's `ref-sticker-f010.png` reference (prompt 307) shows the bug. It must be captured
  again on a phone with this build and committed in place of the old one, with that reason.

## Owed on device

1. Install this build on the phone.
2. Settings → Developer → Studio render check → "Capture overlay reference" again. The
   `ref-sticker` frame shows a white star at upper left and a large orange flame, turned a little
   clockwise, at lower right, with the coloured quarters of the test video around them (no black
   boxes). Share the files so the reference can be replaced (prompt 307's folder).
3. Add a sticker (any colour, turned and scaled) to a real clip in the Studio, export as a new
   video and compare with the editor's preview: same symbol, same colour, same place and turn.
4. "Save to original" the same edit: the baked clip shows the sticker, not a black box.
