# Prompt: Golden frames for the Studio compositor, and a render check to run on a phone

**File**: pdd/prompts/features/studio-review/304-ios-studio-golden-frames-and-self-check.md
**Created**: 2026-11-25
**Project type**: iOS
**Chain**: `PLAN.md` → P1. Built on `studio-v2` after prompt 303.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Problem

The next phases of the plan move text, climb tags and the heart-rate tile into the compositor,
and then change the data model under it. Each of them needs two things that did not exist.

1. **A gate that says "the rendered frame did not change unless we meant it to."**
   `StudioCompositorRenderTests` renders real frames, but it checks a handful of pixels for "is
   this red". A layer moved by ten pixels, a frame shown one frame late, or a crop that is a
   little off passes.
2. **A way to check rendering on a real phone with one tap.** Every Studio prompt since 294 ends
   with a list of things owed on a device, and each needs a project set up by hand.

## Change

Nothing the compositor draws was changed.

### Golden frames (unit tests, simulator)

- **The fixture is written in code** (`StudioGoldenScenes.swift`, `StudioGoldenRenderer.makeFixture`).
  `StudioGoldenPattern` describes a frame: four colour quarters, a black mark in the top-left
  corner, and a white block that moves right by a thirtieth of the width every frame (6 pixels
  at 180 wide). The quarters show orientation and crop. The block shows which source frame is on
  screen. Four sources, 1 s each at 30 frames a second, each with a 440 Hz tone: two 180×320
  with different colours, one 320×180, and one 320×180 with a quarter-turn `preferredTransform`.
  H.264 with fixed settings. A fixed heart-rate series (`StudioGoldenScene.heartRate`, 40
  samples) is there for prompt 306; nothing uses it yet.
- **Scenes** (`StudioGoldenScene.all`): a small project each, and the output frames to compare.

  | Scene | What it holds | Frames |
  |---|---|---|
  | `cut` | two clips; the last frame before the cut and the first after | 4 |
  | `trim-speed` | a trimmed clip at 2×, then a trimmed clip at 0.5× | 4 |
  | `crop` | a landscape clip cropped onto a 9:16 canvas | 2 |
  | `base-frame` | crop + the half-height base frame, white background | 1 |
  | `base-frame-blur` | a portrait clip in a cell of a square canvas, blurred background | 1 |
  | `filters` | mono, noir, fade, vivid (1 and 0.4), warm, cool, adjust alone, warm + adjust | 9 |
  | `transition-…` ×5 | dissolve, fade through black, slide left, slide right, zoom in: the first, middle and last frame of the overlap, and the first frame after it | 20 |
  | `pip` | a picture-in-picture turned 15°, fading from 20 % to 100 %, ending mid-timeline: the frame before it, its first, two in between, its last, the frame after | 6 |
  | `rotated` | the rotated source, whole and cropped | 3 |
  | `ken-burns` | zoom keyframes 1× → 1.6× | 3 |
  | `combined` | a filter, a dissolve and a picture-in-picture at once | 3 |

  15 scenes, **56 frames**, 290 KB of PNGs in `ios/App/SnappetTests/GoldenFrames/`.
- **Two paths, one set of images** (`StudioGoldenRenderer.check`). Each scene is rendered
  through the **export** — `StudioComposer.assemble`, then `StudioComposer.export` to a real
  file, frames read from the file — and through the **preview** — the same `assemble` call with
  `forPlayback`, frames drawn from the video composition the editor gives its `AVPlayerItem`.
  Both are compared with the same golden images. The images are recorded from the export.
  A separate test checks that the two compositions have the same instructions, layer for layer.
- **The comparison** (`StudioGoldenCompare`, pure). Brightness is compared per pixel; colour is
  compared after averaging over 8 × 8 pixels; a frame fails when too many pixels differ, or when
  too many differ inside one 16 × 16 square. Why it is not a plain per-channel comparison, and
  the measured numbers, are in `decisions.md` (2026-11-25). On a failure the test attaches the
  rendered frame, a difference picture (differing pixels in magenta) and the golden image, and
  prints the counts and the worst square.
- **Placeholders.** `testText`, `testStickers`, `testClimbTags` (prompt 305),
  `testHeartRateTile` and `testHeartRateTileAcrossATransition` (prompt 306) are `XCTSkip`. They
  have matching skipped scenes in the list. The simulator cannot draw the Core Animation tool's
  text offline, so there is nothing to compare until the compositor draws them.
- **`StudioComposer.export`** was split: the part that runs the export session is now
  `export(composition:videoComposition:audioMix:quality:progress:)`, and the old function ends
  by calling it. The tests and the self-check call the second half, so their file is written by
  the Studio's own code.

### Studio render check (Debug builds only)

Settings (Home's avatar) → **Developer** → **Studio render check**. The section and all the
code behind it are inside `#if DEBUG`.

- **Run the check** writes the fixture videos on the phone, renders every scene through the
  export and the preview, and compares the frames with the same golden images (a Debug build
  copies them into the app; a Release build has none). Nothing is read from or saved to Photos.
- Each scene shows **pass**, **fail** or **skipped**. A scene opens a page with, for every
  frame, the golden image, the rendered one and the difference picture.
- **Timed export**: 20 s at 1080×1920 — five clips with a filter each, four 1.25 s transitions,
  a picture-in-picture for 16 s. It shows the export time, the speed against real time, the
  peak memory (sampled every 50 ms) and the file size. A switch turns it off.
- **Copy report** puts a plain-text summary on the clipboard: device, system, tolerances, one
  line per scene, the failing frames' numbers, the timed export.
- On a phone the comparison uses looser limits than on the simulator. They are a first guess;
  see "Owed on device".

Pure and unit-tested: the comparison, the scene list and the fixture pattern, the limits, a
scene's pass / fail from its frames, the summary and the report text (`StudioSelfCheck`). The
screen, the video writing and the rendering are the thin part.

### Also changed

- `ios/App/project.yml`: a build script copies the golden images into a Debug app; the
  `GoldenFrames` folder is left out of the test bundle.
- `scripts/ci-ui-shard.py`: a `studio` area (the Studio's files and the golden images →
  `StudioSelfCheckUITests`, `LiveWorkoutStudioWalkthroughTests`). Before this, a change to
  `Services/Studio*` selected no UI class. The check for "every UI class has an area" needed it.
- `.gitignore`: the record marker.

## How to re-record

A golden image changes only when the picture is meant to change, in the same PR, with the
reason written in that PR's prompt.

1. `touch ios/App/SnappetTests/GoldenFrames/.record`
2. Run `-only-testing:SnappetTests/StudioGoldenFrameTests`. Every scene's export frames are
   written as the new images. The run **fails** (`testRecordModeIsOff`, and the test that
   compares the app's copies), so a recording is never taken for a pass.
3. `rm ios/App/SnappetTests/GoldenFrames/.record`
4. Run the class again. It must pass.
5. Look at every PNG that `git status` lists before committing it.

To add a scene: add it to `StudioGoldenScene.all`, add a one-line test to
`StudioGoldenFrameTests`, add its id to `testEverySceneHasATest`, record. To fill in a
placeholder: give the scene its clips and frames in place of `pendingReason`, and replace the
`XCTSkip` with `assertScene`.

The marker is a file because `xcodebuild` does not pass the shell's environment to a hosted
unit test.

## Tests

- `StudioGoldenCompareTests` (17): identical images; noise inside and outside the limits; a
  block moved by 3 pixels; a missing block and where the worst square is; a small patch in one
  place fails although it is under the frame allowance; the same number of pixels spread out
  passes; too many spread out fails; a one-pixel line of another colour with the same
  brightness passes and an area of it fails; a different size; a square cut by the edge; a strip
  across two squares; an image smaller than a square; the difference picture; the summary line;
  a PNG round trip.
- `StudioSelfCheckPlanTests` (16): where the block is in a given frame; a frame's pixels; the
  sources; scene ids and file names; the list covers every filter and every transition kind,
  trim + speed, both base-frame backgrounds, zoom keyframes, the rotated source and a
  picture-in-picture with rotation, keyframes and an early end; every frame is inside its
  scene; scene lengths; the placeholders and their reasons; the heart-rate series; the limits
  get looser in order; **every limit still fails a block one frame out of place and a missing
  block**; pass / fail from frames; the summary; the timing lines; the report text.
- `StudioGoldenFrameTests` (28, 5 skipped): the 15 scenes on both paths; the placeholders; every
  scene has a test; record mode is off; the folder holds exactly the images the scenes name; the
  app carries byte-identical copies; preview and export compositions have the same
  instructions; writing a source twice gives the same pixels; a source file shows the pattern
  (and does not pass as the next frame), the rotated file comes out upright, every source has
  sound and is 1 s long; the timed export's code on a small scene (4 s at 180×320) returns a
  time, a memory peak and a file size.
- `StudioSelfCheckUITests` (1): opens Settings → Developer → Studio render check on the
  simulator, switches the timed export off, runs the check, and asserts every scene that is not
  a placeholder reports pass, the placeholders report skipped, "Copy report" works, and a scene
  opens its frames. The 20 s export at 1080×1920 is not run there: it took about three minutes
  on the simulator and the number means nothing on one.

Run times and results are in the PR.

## Found, not fixed

Every golden image was looked at against what the scene should show (block position from the
frame number, quarter colours, orientation, crop, cell, transition progress). **No rendering
bug was found.**

Two things that are true today and are recorded in the images as they are:

- **Photo clips are not rendered.** `makeComposition` leaves them out. There is a skipped
  scene, `photo-clip`, and no support was added.
- **A crop on a canvas of another shape fills the canvas** (aspect fill, cut at the sides), in
  `crop` and in the second clip of `rotated`. That is what `ClipEditGeometry.cropTransform` is
  written to do; it is noted because the images now pin it.

One fault of this job's own, found by the tests and fixed before the commit: the fixture writer
could stop for good when the last video frame went in before the last sound (the writer was
waiting for an input it had not been told was finished).

## Owed on device

Nothing here was run on a phone. The app compiles for a device.

1. **Run the check on the phone** (Debug build → Settings → Developer → Studio render check).
   Expected: 15 pass, 6 skipped. The device limits are a guess. If a scene fails, open it and
   look at the difference picture: thin lines along edges mean the limit is too tight for this
   phone's encoder (send the report; the limit is then set from the numbers); a block, a shifted
   edge or a missing layer is a real difference between the phone and the simulator.
2. **The fixture on a hardware encoder**: 180×320 H.264 files are written by the phone's
   encoder. If it refuses that size the check reports "The test video could not be written".
3. **The timed export's numbers** on the phone: export time, peak memory. These are the first
   real numbers for the single compositor (prompt 300, "Owed on device" 3 and 6). Run it twice;
   the second run should not be slower or use more memory.
4. **The pictures on the scene pages** are sharp (not smoothed) and the three are the same size.
5. **Copy report** pastes into another app.
