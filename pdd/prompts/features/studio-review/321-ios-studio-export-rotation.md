# Prompt: A turned overlay turns the same way in the exported video as in the editor

**File**: pdd/prompts/features/studio-review/321-ios-studio-export-rotation.md
**Created**: 2026-11-26
**Project type**: iOS
**Chain**: a bug found in prompt 307's overlay reference on a phone, while reviewing prompt 308.
Built on `studio-v2` (after #499).
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## What changes for the user

Nothing a user can do today: the Studio has no control that turns an overlay (nothing in the app
sets `rotationDegrees`; it is 0 unless it comes from a decoded project or a test scene — found by
the review of this PR). When a turn control is added, a turned sticker, text line or climb tag
will come out of the export the same way the editor shows it. Before this fix the file turned it
the other way, as the overlay reference's test scenes show.

## Problem

Prompt 307's reference frame `ref-text-f015.png` (iPhone 13 Pro Max, iOS 27.2.1): the line "Second
go" has `rotationDegrees: 10`. In the exported frame its highlight box rises to the right
(turned counter-clockwise). The editor draws the same overlay with
`.rotationEffect(.degrees(10))` (`StudioOverlayCanvas`), which turns it clockwise: it falls to the
right. This was so since overlays could be turned; it is not new in `studio-v2`.

## Cause

`StudioOverlays` turned a sticker layer and a text / climb-tag container with
`CATransform3DMakeRotation(+degrees)`. The export's layer tree
(`AVVideoCompositionCoreAnimationTool`) has its origin at the bottom left with y up
(`ClipEditGeometry.layerPoint` flips y for this reason). In that space a positive angle turns
counter-clockwise on screen. SwiftUI's positive angle is clockwise on screen. So the same number
turned the two ways.

## Change

- `StudioOverlays.overlayRotation(degrees:)` (new, internal): `CATransform3DMakeRotation(-degrees)`.
  `rotationDegrees` is the preview's angle (positive = clockwise on screen); the layer tree is y up,
  so the export turns by the negative angle.
- `stickerLayer` and `styledTextLayer` (text and climb tag) use it. They were the only two
  rotations in the Core Animation export.

### Every other turned thing, checked

- **Picture-in-picture** is turned by the compositor (`StudioCompositor`, `StudioRenderPlan.rotation`)
  in a top-left, y-down space, so a positive angle is clockwise there, as in the preview. The `pip`
  golden frames (turned 15°) show the picture falling to the right. Unchanged.
- **The heart-rate tile**, the Clips share's title block and the reel scorebug are never turned.
- `ReelExporter` and "Share with heart rate" build their overlays with
  `StudioOverlays.makeAnimationTool`, so a turned caption on those paths gets the fix too.

## Tests

`StudioOverlayRotationTests` (new):

- `testPositiveDegreesTurnClockwiseOnScreen` (pure): `overlayRotation(degrees: 90)` takes (1, 0)
  to (0, −1) in the y-up layer space, which is down on screen: clockwise. −90 goes the other way.
- `testTurnedOverlaysTurnTheWayThePreviewDoes`: exports one frame with a wide sticker
  (`rectangle.fill`, +30°), a text line on an orange highlight (+20°) and a climb tag with its dark
  default highlight (−20°) over the test video, on the simulator through the real export. Each
  overlay's pixels (where the frame differs from the bare clip) must have an x–y correlation of
  the turn's sign (y down: positive = clockwise) and at least 0.1 in size. The simulator draws the
  sticker's bitmap and the highlight boxes (not the letters), which is enough. Measured: sticker
  +0.19, text +0.48, climb tag −0.81. With the old sign put back for one run: −0.19, −0.82, +0.81,
  and the test fails (with the pure test: Executed 2 tests, with 5 failures).

`StudioStickerExportTests` (prompt 308): its `point(_:local:turn:)` helper encoded the old export
direction; it now turns the way the preview does, and the `ref-sticker` checks (the flame at −20°)
are measured on the corrected frame. (Those checks are loose enough to pass either way: they are
about black boxes, not the turn. The turn is `StudioOverlayRotationTests`'s job.)

No golden image changed (the golden scenes have no Core Animation overlays; `pip` is the
compositor). `StudioOverlayReference` scenes and `GoldenFrames/OverlayReference/` are not touched.

### Runs (iPhone 17 Pro simulator, iOS 26.5)

- `StudioOverlayRotationTests` + `StudioStickerExportTests`: Executed 7 tests, with 0 failures.
  With the old sign put back: Executed 7 tests, with 5 failures (all in
  `StudioOverlayRotationTests`).
- Full unit suite (`SnappetTests`, every golden-frame test unchanged): Executed 3782 tests, with
  11 tests skipped and 0 failures.
- UI: `LiveWorkoutStudioWalkthroughTests` and `StudioHRTimingUITests` passed;
  `StudioSelfCheckUITests` failed once on its 6 s wait for a scene's frames screen to open
  (after every scene had passed; nothing in it uses the Core Animation overlays) and passed when
  run again alone: Executed 1 test, with 0 failures.
- Device compile (`generic/platform=iOS`, Debug): BUILD SUCCEEDED.

## Not done

- Prompt 307's reference frames for text and stickers (`ref-text-f015.png`,
  `ref-sticker-f010.png`) were captured with the
  old direction. They must be captured again on a phone with this build and replaced, with this
  prompt as the reason. The change is intended.
- Videos already exported or baked keep the old turn; nothing can repair them.

## Owed on device

1. Install this build on the phone.
2. Settings → Developer → Studio render check → "Capture overlay reference" again. In the text
   frames "Second go" now falls to the right (turned clockwise), and in the sticker frame the
   flame leans to the left (turned counter-clockwise), as the editor shows them. The text and
   sticker frames change on purpose; share them so prompt 307's reference can be replaced.
3. (Not possible yet: the editor has no turn control. When one is added, export and "Save to
   original" a turned text line, sticker and climb tag and compare with the editor.)

## Review follow-up (2026-11-26)

- The Studio has no control that sets `rotationDegrees`; "What changes for the user" and "Owed on
  device" say so.
- `ref-text-f015.png` is added to `StudioOverlayReference.knownWrongFrames` and the overlay
  reference README (frames 5 and 27 do not show the turned line).
