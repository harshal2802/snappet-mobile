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

3. *(found while building the gate)* **Every Studio export and preview was too bright.** An
   unedited clip came out of the Studio with its mid-tones about 18 levels (of 255) lighter
   than the clip itself. It has been so since prompt 300 put every frame through the
   compositor.

## Change

### Fixed: the Studio no longer brightens a clip

- **What a person sees**: a clip, a reel or a preview from the Studio has the same brightness
  and colours as the clips it was made from. Before, mid-tones were lifted (grey 120 came out
  as 139; a red of 199, 61, 61 as 209, 81, 82).
- **Why**: Core Image reads a BT.709 video frame with the colour space Core Media gives it
  (`CGColorSpace.coreMedia709`, a plain 1.961 gamma). `StudioCompositor` wrote its result with
  `CGColorSpace.itur_709`, which has another curve. Reading with one curve and writing with the
  other moves every mid-tone.
- **The fix** (`StudioCompositor.render`): the frame is written with the colour space the
  **output buffer's own tags** describe (`colorSpace(of:)`, from the buffer's primaries,
  transfer function and matrix), with `coreMedia709` when a buffer has none. The buffer's tags
  are not touched, so the file is still tagged BT.709.
- **Measured** on the simulator, the Studio's frame against the same frame of the source file
  decoded directly (`StudioPassThroughTests`):

  | | Region mean colour | Largest single-pixel brightness |
  |---|---|---|
  | Before | 22.3 – 23.6 off, everywhere | 27 |
  | After | at most 5.6 (at edges between two colours; the centres of the quarters are equal) | 15 |

- **Blending.** Layers are now mixed in the output's encoded values, not in Core Image's linear
  light: each layer is converted to the output space before it is laid over the others. A
  dissolve at its middle and a picture-in-picture at 50 % are then the plain average of the two
  pictures' video values. That is what the app did before prompt 300, when AVFoundation's
  opacity ramps did the mixing. Filters still run in linear light, as before. A layer is
  brought into the range 0…1 before it is converted: a decoded frame can hold values a little
  under 0 (a fully saturated colour), and those spoil the mix — the existing test
  `testExportedFileHasTheBlendTheTextAndTheMusic` (pure red to pure blue) caught a dissolve with
  no blue in it before the clamp went in. See `decisions.md`.
- **HDR and wide-colour clips.** They reach the compositor already converted to SDR BT.709 by
  AVFoundation (`supportsHDRSourceFrames` and `supportsWideColorSourceFrames` stay off), so the
  same fix applies to them and nothing else about them changed. Two tests write such a clip
  (Display P3 H.264; 10-bit HEVC with HLG) and compare the Studio's frame with a direct decode:
  P3 is within 6.8 in a region's mean, HLG within 12.1 (two different tone-mapping routes). The
  export is still SDR; HDR output is not part of this.

**Every golden image changed** in the second commit of this PR, for these reasons together:
the brightness fix (every frame), the encoded-value blending (dissolve, fade, picture-in-picture
frames), the fixture now storing the values a BT.709 file keeps for the pattern's colours (the
first set showed grey 120 as 131), and the transition scenes sampling six frames, not four.

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
  | `transition-…` ×5 | dissolve, fade through black, slide left, slide right, zoom in: the first frame of the overlap, a quarter, the middle, three quarters, the last, and the first frame after it | 30 |
  | `pip` | a picture-in-picture turned 15°, fading from 20 % to 100 %, ending mid-timeline: the frame before it, its first, two in between, its last, the frame after | 6 |
  | `rotated` | the rotated source, whole and cropped | 3 |
  | `ken-burns` | zoom keyframes 1× → 1.6× | 3 |
  | `combined` | a filter, a dissolve and a picture-in-picture at once | 3 |

  15 scenes, **66 frames**, 464 KB of PNGs in `ios/App/SnappetTests/GoldenFrames/`. The
  quarter and three-quarter frames are there so a transition drawn with another easing fails.
- **Two paths, one set of images** (`StudioGoldenRenderer.check`). Each scene is rendered
  through the **export** — `StudioComposer.assemble`, then `StudioComposer.export` to a real
  file, frames read from the file — and through the **preview** — the same `assemble` call with
  `forPlayback`, frames drawn from the video composition the editor gives its `AVPlayerItem`.
  Both are compared with the same golden images. The images are recorded from the export.
  A separate test checks that the two compositions have the same instructions, layer for layer.
- **The comparison** (`StudioGoldenCompare`, pure). Brightness is compared per pixel; colour is
  compared after averaging over 8 × 8 pixels; a frame fails when too many pixels differ, or when
  too many differ inside one 16 × 16 square, **or when the mean colour of any 16 × 16 square is
  off by more than a few levels** (3 on the simulator's export). The last rule is what catches
  a filter that was not applied, a wrong strength, a wrong opacity or a faint glass tile: none
  of those moves any single pixel far. Why it is not a plain per-channel comparison, and
  the measured numbers, are in `decisions.md` (2026-11-25). On a failure the test attaches the
  rendered frame, a difference picture (differing pixels in magenta, squares whose mean is off
  outlined in yellow) and the golden image, and prints the counts and the worst square.
- **The fixture stores video values.** The pattern's colours are sRGB numbers. The writer
  stores `StudioGoldenPattern.videoValue(forSRGB:)` and tags each frame BT.709, so a file that
  is decoded and shown as sRGB gives the pattern's own numbers back (199, 61, 61 for 200, 60,
  60).
- **Placeholders.** `testText`, `testStickers`, `testClimbTags` (prompt 305),
  `testHeartRateTile`, `testHeartRateTileAcrossATransition` (prompt 306) and `testPhotoClip` are
  `XCTSkip`. They have matching skipped scenes in the list, and `testEverySceneHasATest` pins
  their ids and reasons. In an offline export on the simulator the Core Animation tool draws
  layer shapes (backgrounds, rounded boxes) but no letters and no symbols — see "Found" — so
  there is nothing to compare until the compositor draws them.
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
  line per scene, **the largest measured difference of every scene on each path** (brightness,
  colour, share of the frame, share of one square, region mean), the failing frames' numbers,
  the timed export.
- On a phone the comparison uses looser limits than on the simulator. **They are a first guess
  and too loose to be a gate** (a region mean of 8 lets a filter at the wrong strength pass).
  The report says so, and the measured lines are what the limits are to be set from after the
  first phone run; see "Owed on device".
- **Capture overlay reference** renders five fixed scenes through today's export — text, a
  sticker, a climb tag, the heart-rate tile over strong colours, and the tile across a
  transition, all at 540×960 — and saves 11 PNG frames and a `manifest.json` (machine, device,
  system, renderer, a note for each frame) in the app's temporary folder, with a share button.
  These are the "before" pictures for prompts 305 and 306, and they must come from a phone: the
  screen says that on the simulator they are not a reference. They are 540×960, three times the
  other scenes, so that text and a 1-pixel shift of a small element are well inside what the
  comparison can see.
- The memory baseline of the timed export is read before its test video is written. Folders
  left in the temporary directory by a run that was killed are removed when the screen opens.

Pure and unit-tested: the comparison, the scene list and the fixture pattern, the limits, a
scene's pass / fail from its frames, the summary and the report text (`StudioSelfCheck`), the
overlay reference's scenes, file names and manifest (`StudioOverlayReference`). The
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
   written as the new images. **Every golden test fails** while the marker is there (each scene
   test after writing its images, and the others at once), so a recording is never taken for a
   pass.
3. `rm ios/App/SnappetTests/GoldenFrames/.record`
4. Run the class again. It must pass.
5. Look at every PNG that `git status` lists before committing it.

To add a scene: add it to `StudioGoldenScene.all`, add a one-line test to
`StudioGoldenFrameTests`, add its id to `testEverySceneHasATest`, record. To fill in a
placeholder: give the scene its clips and frames in place of `pendingReason`, and replace the
`XCTSkip` with `assertScene`.

The marker is a file because `xcodebuild` does not pass the shell's environment to a hosted
unit test.

A re-record because the machine changed (a new Xcode, macOS or simulator runtime) is a PR of
its own that **touches no Studio source file**: only the PNGs and its prompt. CI runs Xcode 26.5
on `macos-26`; the images in this PR were recorded with Xcode 27.2 on the iOS 26.5 simulator.
The first commit's images passed on CI unchanged.

## Tests

- `StudioPassThroughTests` (5): an unedited clip through the Studio's export and preview against
  the same frame decoded directly — two portrait sources, the rotated one, a Display P3 clip, an
  HLG clip; and the tolerance itself fails a frame 18 levels brighter and one 7 levels brighter.
- `StudioGoldenMutationTests` (9): a deliberately wrong render must fail against the golden
  image at the simulator's export tolerance (and at the preview's, except where noted). The
  number is the region mean difference it produces, against an allowance of 3 (export) and 6
  (preview): warm filter dropped (14.3); cool dropped (13.4); warm at 0.7 for 1 (5.2, export
  only); warm + adjust at 1 for 0.7 (4.2, export only); the filter dropped from under an adjust
  (9.1); the cool filter dropped from the second clip of `combined` (11.2 – 13.6); a
  picture-in-picture a tenth too opaque and a tenth too faint (8.1 – 18.2); a dissolve drawn
  with smoothstep easing, at a quarter and three quarters (17.4 – 18.9); and the control: the
  same rewritten instructions with nothing changed draw the golden frame.
- `StudioOverlayReferenceCaptureTests` (1): the capture runs on the simulator and writes its 11
  frames and the manifest.
- `StudioGoldenCompareTests` (27): the region mean (a small shift everywhere, noise, signed per
  channel, a square cut by the edge, the yellow outline); **at the simulator's own export and
  preview limits**: a little noise passes, and these fail on both — a colour-only change of 8
  levels, a missing 40×12 box, a missing 24×10 tag, a solid box 1 pixel and 2 pixels out of
  place, a missing 12 % white glass tile; and, as before: identical images; noise inside and outside the limits; a
  block moved by 3 pixels; a missing block and where the worst square is; a small patch in one
  place fails although it is under the frame allowance; the same number of pixels spread out
  passes; too many spread out fails; a one-pixel line of another colour with the same
  brightness passes and an area of it fails; a different size; a square cut by the edge; a strip
  across two squares; an image smaller than a square; the difference picture; the summary line;
  a PNG round trip.
- `StudioSelfCheckPlanTests` (19): the measured lines and the device note in the report, the
  worst numbers of a scene, the overlay reference's scenes and manifest; where the block is in a given frame; a frame's pixels; the
  sources; scene ids and file names; the list covers every filter and every transition kind,
  trim + speed, both base-frame backgrounds, zoom keyframes, the rotated source and a
  picture-in-picture with rotation, keyframes and an early end; every frame is inside its
  scene; scene lengths; the placeholders and their reasons; the heart-rate series; the limits
  get looser in order; **every limit still fails a block one frame out of place and a missing
  block**; pass / fail from frames; the summary; the timing lines; the report text.
- `StudioGoldenFrameTests` (33, 6 skipped): **the Studio's own entry points** — `combined` and
  `base-frame` through `StudioComposer.export(_ snapshot:)` (the fixture files stand in for
  Photos assets), and `pip` through `makeComposition(forPlayback:)` on a real `AVPlayerItem`,
  frames taken from the player after a seek; the pattern's video values; leftover fixture
  folders are removed; the 15 scenes on both paths; the placeholders; every
  scene has a test; record mode is off; the folder holds exactly the images the scenes name; the
  app carries byte-identical copies; preview and export compositions have the same
  instructions; writing a source twice gives the same pixels; a source file shows the pattern
  (and does not pass as the next frame), the rotated file comes out upright, every source has
  sound and is 1 s long; the timed export's code on a small scene (4 s at 180×320) returns a
  time, a memory peak and a file size.
- `StudioSelfCheckUITests` (1): opens Settings → Developer → Studio render check on the
  simulator, switches the timed export off, runs the check, and asserts every scene that is not
  a placeholder reports pass, the placeholders report skipped, "Copy report" works, a scene
  opens its frames, and "Capture overlay reference" saves 12 files and says they are not a
  reference on the simulator. The 20 s export at 1080×1920 is not run there: it took about three minutes
  on the simulator and the number means nothing on one.

Run times and results are in the PR.

## Found

**Found and fixed: the brightening above.** The first commit of this PR said "no rendering bug
was found". That was wrong: its images were checked for position, orientation, crop and
timing, and the colours were not compared with the source. The review that followed found the
lift, the pass-through tests confirmed it in the real compositor, and the first set of images
had it recorded in every frame.

**The gate had holes, now closed.** With the first commit's comparison a filter that was not
applied, a wrong filter strength, a wrong opacity and a dissolve at the wrong progress all
passed. The region-mean rule and the mutation tests are the answer.

**Core Animation tool on the simulator** (checked, not assumed): in an offline export with the
custom compositor it does draw layer shapes — a caption with a highlight background changed
15 % of the frame's pixels, all of it the box — but it draws no glyphs (plain text over the
clip changed 66 pixels of 518,400), and an SF Symbol sticker comes out as a white rounded
shape, not a star. So the simulator cannot give the "before" pictures for text, tags or the
heart-rate tile; the capture action is there to get them from a phone.

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

0. **A clip exported from the Studio looks like the clip.** Export an unedited clip and a reel
   with a dissolve; compare with the originals in Photos. They must not be lighter. (This is the
   fix; it was measured on the simulator only.) Also one HDR clip from the phone's camera: the
   export is SDR and must not look washed out or dark next to the clip in Photos.
1. **Run the check on the phone** (Debug build → Settings → Developer → Studio render check).
   Expected: 15 pass, 6 skipped. Tap **Copy report** and send it whatever the result. **The
   device limits must be tightened from the report's "measured" lines** before the device check
   counts as a gate: each set to the largest measured value plus a small margin, as was done for
   the simulator. If a scene fails, open it and look at the difference picture: thin lines along
   edges mean the limit is too tight for this phone's encoder; a block, a shifted edge, a
   yellow-outlined square or a missing layer is a real difference between the phone and the
   simulator.
1a. **Capture overlay reference** on the phone, then share the files (AirDrop or Files) so they
   can be committed as the "before" pictures for prompts 305 and 306. Check that the text, the
   star sticker, the climb tag and the heart-rate tile are in the pictures.
2. **The fixture on a hardware encoder**: 180×320 H.264 files are written by the phone's
   encoder. If it refuses that size the check reports "The test video could not be written".
3. **The timed export's numbers** on the phone: export time, peak memory. These are the first
   real numbers for the single compositor (prompt 300, "Owed on device" 3 and 6). Run it twice;
   the second run should not be slower or use more memory.
4. **The pictures on the scene pages** are sharp (not smoothed) and the three are the same size.
5. **Copy report** pastes into another app.
