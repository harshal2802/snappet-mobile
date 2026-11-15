# Prompt: Racket rally video — a bigger picture, controls like the Watch player, and Rotate (prompt 257)

**File**: pdd/prompts/features/racket-sports/257-ios-racket-rally-video-controls.md
**Created**: 2026-11-15
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: device feedback on the tag sheet, after prompt 256. Stacked on `claude/racket-pro-camera-recording`.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md` (unchanged; one additive Optional on the racket recording log)

## Goal

The user, reviewing a rally on the tag sheet ("Unsure 1 of 30"): "video look so small on this page and there are no
controls". The clip (`RacketRallyVideo`, a fixed 190 pt box) was a portrait picture pillarboxed in a wide black box,
about a quarter of it, with only a Pause pill; and the scene in it was sideways (the footage was stored with the wrong
turn). Make the picture big, give it the Watch player's controls, and let the viewer turn a recording.

## Context the implementer needs

- `RacketRallyVideo` (was in `RacketTagViews.swift`) is used by the tag sheet, the serve / wall / let detail sheets (tag
  sheet and Edit), and Shots. The fix sheet draws `RacketVideoSurface` directly. All play through `RacketPlayback`.
- The Watch player (`RacketPlayerWatch.swift` pure, `RacketWatchPlayerViews.swift`) has the proven pieces: the speed
  text, `RacketPlayerZoom` (clamp), `RacketPlayerFit`, `RacketPlayerGestureSurface` (tap, pinch, pan).
- `RacketVideoOrientation.swift` already holds the per-part orientation maths (prompt 250).

## Approach

1. **Box shape.** The box takes the picture's own shape: full width, height = width / displayed aspect, capped
   (`RacketVideoTurn.box`). The tag sheet's cap is about 55 % of the screen and never so tall that the controls under the
   picture plus "Who won" and its buttons leave the first screen (`tagSheetCap`, from the sheet's measured height). The
   detail sheets, Edit's detail sheets and Fix cap at 280 pt, Shots at 320. 16:9 placeholder until the size is known.
2. **Controls** (`RacketRallyVideoViews.swift`, a thin view over `RacketRallyVideoModel`): tap the picture to play / pause
   with a brief centre glyph; Play/Pause, Replay, speed (1× → 0.5× → 0.25×, kept while the sheet is open), Rotate,
   full screen. Under it a scrub bar over the looped stretch (rally padded 1 s, the rally highlighted; drag pauses and the
   frame follows; release loops on from there) and "−3 s" / "+3 s" that widen the loop (clamped to the part), with the
   time and length. Full screen: the same controls, pinch-zoom and pan with the Watch player's clamp, Done.
   Identifiers `racket.rallyVideo.*` (full screen `racket.rallyVideo.full.*`), labels, 44 pt targets.
3. **Rotate.** A quarter turn per tap, kept for the recording in `RacketRecordingLog.quarterTurns` (additive Optional; nil
   = as saved). `RacketPlayback.quarterTurns` carries it; `RacketVideoSurface`, the Watch player and Edit draw the layer
   turned (`RacketTurned`), so the tag / fix / timeline / split / Watch / Edit screens honour it. Shared copies, AI clips
   and the Watch player's filmstrip thumbnails are not turned (a composition change — later).
4. Nothing else on the tag sheet changes.

Pure: `RacketRallyVideoControls.swift` (`RacketRallyLoop`, `RacketRallyVideoSpeed`, `RacketRallyVideoTap`) and
`RacketVideoTurn` in `RacketVideoOrientation.swift`.

## Acceptance criteria

- [ ] A portrait clip shows in a portrait box with no side bars; a landscape clip is full width 16:9.
- [ ] Tap, Play/Pause, Replay, speed, scrub, −3 s / +3 s, full screen + zoom + Done, Rotate kept after closing and
      reopening the sheet — each covered by `RacketRallyVideoUITests`.
- [ ] "Who won" stays on the first screen of the tag sheet on a 6.1" phone with a portrait clip.
- [ ] Unit tests for the pure pieces (`RacketRallyVideoControlsTests`); `RacketTaggingUITests`, `RacketPlayerUITests`,
      `RacketEditUITests`, `RacketVideosUITests` green; device build passes.
- [ ] `decisions.md`, `project.md`, `docs/knowledge-graph/data.js` updated.

## Constraints

- No real footage committed (the synthetic bundled clips are reused). Rally detection stays vision only.
- Simulator-only verification; the phone run is the user's.

## Test plan

1. `SnappetTests`. 2. `RacketRallyVideoUITests`, `RacketTaggingUITests`, `RacketPlayerUITests`, `RacketEditUITests`,
`RacketVideosUITests` one at a time, app uninstalled first. 3. Screenshots (portrait, landscape, full screen, rotated) to
`shots/tag-video/` with `TEST_RUNNER_RACKET_SHOTS`. 4. `build-for-testing` for `generic/platform=iOS`.
