# Prompt: One Studio compositor renders filters, transitions and picture-in-picture together

**File**: pdd/prompts/features/studio-review/300-ios-studio-single-compositor.md
**Created**: 2026-11-23
**Project type**: iOS
**Chain**: from the 2026-11 Studio code review; built on prompt 299; closes open items of prompts 295 and 297
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Problem

`StudioComposer.assemble` built the video one of three ways, and each way dropped something. All
of it was confirmed by reading the code on `2d8defff`. None was reproduced on a device.

| The project has… | Path taken | What was dropped |
|---|---|---|
| a transition, no filter, no picture-in-picture | two tracks, opacity / transform ramps | added music; each clip's volume; speed on the audio |
| a filter or a manual adjust, no picture-in-picture | Core Image handler (`applyingCIFiltersWithHandler`, deprecated) | the crop (the whole clip filled the frame); the base frame; transitions |
| anything else, picture-in-picture included | one track, layer instructions | filters and adjust when a picture-in-picture was present; transitions |

More, found while confirming:

1. The transition path was chosen when **any** stored transition was not a cut, including one on
   the last clip and one keyed to a clip hidden by "Edit this clip". Such a project exported
   without its music although no transition played (prompt 297, open item 1).
2. The editor's timeline (`StudioGeometry.timeline`) shortens the output by every transition. The
   filter path and the layer path ignored transitions, so the preview and the file were longer
   than the timeline the editor drew.
3. On the transition path the audio of all clips went on one track at overlapped times, without
   the speed change. It was not a cross-fade; later clips' sound was pushed out of place.
4. "Fade through black" was rendered as a dissolve. A slide or a zoom moved only the clip on the
   second track, so the same transition looked different for odd and even clips.
5. A picture-in-picture's opacity keyframes were stored and never rendered. Its opacity slider
   did not change the preview at all, because the edit never rebuilt the preview.
6. A crop was ignored while a base frame was set.
7. The canvas background (black / white / blur) and a clip's Ken-Burns scale keyframes are in the
   model and were never rendered. Neither has a control in the editor today.
8. With two picture-in-picture clips the first one was drawn on top; the editor canvas draws the
   later one on top.

One claim in the job text was not exact: the filter path was not taken for every filtered
project, only when there was no picture-in-picture. The table above is what the code did.

## Change

There is one path.

- **`StudioRenderPlan`** (new, `Features/WorkoutTracker`, Foundation and CoreGraphics only). From
  the rendered clips, their source lengths and sizes, the stored transitions, the overlays and the
  canvas it gives:
  - where each clip sits on the output, taken from `StudioGeometry.timeline`, so the render and
    the editor cannot disagree; the source range to insert; the video track it goes on (one track
    for cuts, two with transitions); its volume and its audio fade ranges;
  - each picture-in-picture window, cut to the end of the timeline and to the length of its source;
  - **segments**, back to back from zero to the end. Each lists its layers: the main clip, the
    incoming clip during a transition (kind and progress range), and the picture-in-picture
    layers, with every parameter needed to draw them;
  - the per-frame rules as pure functions: what each transition kind does to the outgoing and the
    incoming clip at a given progress, the picture-in-picture opacity, the Ken-Burns scale.

  A transition applies only where the timeline gives two clips an overlap. One stored on the last
  clip, or keyed to a clip that is not in the rendered list, changes nothing.
- **`StudioCompositor`** (new, `Services`) is a custom `AVVideoCompositing` class with its own
  instruction type, `StudioCompositionInstruction`. It draws a segment with Core Image through one
  shared Metal-backed `CIContext`: background, main clip (orientation, crop or base frame,
  Ken-Burns scale, filter, adjust), incoming clip, picture-in-picture layers. It decides nothing.
  Each instruction asks only for the tracks its segment draws. Queued frames are cancelled when
  AVFoundation asks. No mutable shared state, so it is `Sendable` under Swift 6.
- **`StudioComposer.assemble`** reads the sources, makes the plan, puts the clips on tracks and
  emits one instruction per segment. The three old paths are deleted, and with them the last use
  of the deprecated `init(asset:applyingCIFiltersWithHandler:)`. `makeComposition`, `assemble` and
  `export` keep their signatures; `assemble` gained `background:` with a default, and
  `makeComposition` passes the project's. Export progress, cancel and file cleanup (prompt 298)
  are unchanged.
- **Audio, in every case**: each clip's own sound at its volume (speed applied), a linear
  cross-fade over each transition, and the added music.
- **Colour**: output is SDR BT.709, as before. HDR and wide-colour sources are converted to SDR by
  AVFoundation before the compositor sees them.
- **Core Animation tool** (`StudioOverlays`: text, climb tags, HR tile) is unchanged and still
  export-only. It draws over the compositor's frames.
- **`ClipBakePlan.rendersMusic` is removed.** Music is always in the render, so a whole-project
  bake always removes it and a scoped bake always records it on the baked clip.
- **Picture-in-picture opacity in the preview**: `setOverlayOpacity` stores the value live during
  a slider drag and `endGesture` rebuilds the preview once. Outside a drag it is a normal edit,
  which rebuilds. Text and tags are unchanged (the canvas draws them).

### What looks different from before

- A crop is kept when the clip has a filter, and when a base frame is set (the cropped part is
  fitted into the cell).
- "Fade through black" goes to black in the middle.
- Slide left / right: the incoming clip pushes the outgoing one off. Zoom in: the incoming clip
  always grows over the outgoing one. Both are the same for every pair of clips now.
- A dissolve is blended by Core Image in linear light, so its middle is a little brighter than
  the old opacity ramp.
- With two picture-in-picture clips the later one is on top, as on the canvas.
- A project with a filter and no picture-in-picture used the source frame rate; every project now
  renders at 30 frames a second, as the other two paths did.
- A project with a stored `white` or `blur` background, or Ken-Burns keyframes, now shows them.
  The editor cannot set either, so no existing project should have them.

### Open items of earlier prompts that this closes

- **297, open 1**: a stored transition that does not apply no longer chooses a path, and the
  music is mixed.
- **297, open 5**: a picture-in-picture window is cut to the timeline in the plan; the 0.1 s
  minimum that could lengthen the output is gone.
- **294 / 295**: the "music the transition path did not mix" case is gone (`rendersMusic`).

Not closed: **295, items 1 and 2** (a mixed timeline of baked and unbaked clips still gets
project-wide picture-in-picture, music and the base frame over the baked clip). The plan now has
a per-clip place to gate them, but the gate itself is not built here.

## Not done

- **Photo clips** are still left out of the render.
- **Unresolved assets** are skipped exactly as before; availability is another job's.
- **Picture-in-picture keyframe button**: `addOverlayKeyframeAtPlayhead` still does not rebuild
  the preview, so a new keyframe on a picture-in-picture shows after the next rebuild. It is in
  the view model outside the two functions this job may touch.
- **Picture-in-picture audio** is not mixed (it was not before).
- **Music fade-in / fade-out** fields are stored and not applied (they were not before).
- **No passthrough**: a project with no effects is also drawn frame by frame through Core Image.
  The old layer path used AVFoundation's own compositor for it. See the device list.

## Tests

`StudioRenderPlanTests` (pure, no AVFoundation): cuts; trim and speed; every transition kind
(segments, two tracks, audio fades); overlap limited by the shorter clip; three clips; a short
middle clip; an unused trailing transition and one keyed to a clip not rendered; a scoped list; a
transition + filter + picture-in-picture together, with a window that cuts the transition in
two; picture-in-picture windows against the end of the timeline and the source length; overlay
order; base-frame and crop placement; Ken-Burns time base; every pose; empty and zero-length
input. Every plan's length equals `StudioGeometry.totalDuration`.

`StudioCompositorRenderTests` (simulator, synthetic 180×320 solid-colour videos written with
`AVAssetWriter`, frames read with `AVAssetImageGenerator`, pixel colours asserted):

- a mono-filtered clip is grey while a picture-in-picture is present, and red without the filter;
- the middle of a dissolve is a blend while a filter and a picture-in-picture are present;
- slide left, slide right, zoom in and fade through black at their middle;
- picture-in-picture opacity keyframes change its alpha over time; a fixed 0.5 is a steady blend;
- the base frame puts the clip in its cell over a white background;
- a crop is kept on a filtered clip;
- a clip with a 90° `preferredTransform` comes out upright;
- the composition length and the instruction ranges match the plan; each instruction asks for
  one track, two during the dissolve;
- music is mixed with a transition, and with only an unused transition on the last clip;
- two clips with sound cross-fade over the transition at their own volumes;
- a real `AVAssetExportSession` file of a transition + filter + picture-in-picture + music +
  text: right length, blended middle, picture-in-picture, the text's highlight chip drawn by the
  Core Animation tool over the compositor's frames, and an audio track that is not silent;
- a picture-in-picture opacity drag rebuilds the preview once, at the end; a text drag never.

`ClipBakePlanTests`: the two tests that covered `rendersMusic` now assert that music is removed
or recorded with any combination.

### What the simulator could not show

- **Glyphs.** The simulator's offline Core Animation renderer draws solid layers (also animated
  ones — the chip above is gated by the same opacity animation as the text) but not layers that
  need a bitmap, so text glyphs, stickers and the HR tile's numbers are not in a simulator file.
  With AVFoundation's own compositor the same tool crashes the simulator process inside
  `CARenderer` (IOSurface creation), so this could not be compared with the old path there.
- **Speed, heat, memory.** A simulator has no meaning for them.
- **Photos assets, HDR sources, real camera orientation metadata.**

## Owed on device

Nothing here was run on a phone.

1. **Text, climb tag and HR tile in an export** of a project with a filter + a transition + a
   picture-in-picture: all three are drawn, at the right place and time, over the picture.
2. The same project in the **preview**: filter, transition and picture-in-picture all show, and
   the preview ends where the timeline ends.
3. **Export time** at 1080p and at 4K for a filter + a transition + a picture-in-picture, against
   a project with no effects, and against the numbers in `StudioComposerProfilingTests` (a 16 s,
   four-clip 1080×1920 export took about 2.6–3 s on an iPhone 13 Pro Max before this change).
4. **Preview smoothness** at 1080p and 4K with the same project: dropped frames while playing,
   and how long a scrub takes to show a frame.
5. **Heat**: export a two-minute 4K project twice in a row; note the thermal state and whether
   the second export is slower.
6. **Memory** during that export and during preview (peak in Xcode's gauge); no growth from one
   export to the next.
7. A project with **no effects**: export time and preview feel against the last build (it is no
   longer handled by AVFoundation's own compositor).
8. An **HDR** clip (iPhone default): colours look as they did, not washed out or blown.
9. Clips filmed in **all four orientations**, and a front-camera clip: upright, not mirrored.
10. Each **transition kind** once, by eye; **audio** across a dissolve (no click, no doubled
    sound) and with a clip at half volume; music present in each case.
11. **Picture-in-picture opacity**: drag the slider — the preview updates once when the finger
    lifts; add two keyframes — the export fades.
12. **Crop + filter**, and **crop + base frame**: the cropped part is what shows.
13. Cancel an export half way (prompt 298): it stops promptly and leaves no file.
14. A **bake** ("Save to original") of a clip with music and a dissolve between split parts: the
    music is in the baked clip and gone from the project.
