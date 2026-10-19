# Prompt: The camera knows the set — tag chip, live HR, stop & log, clips never lost

**File**: pdd/prompts/features/191-ios-camera-snappet-layer.md
**Created**: 2026-10-19
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: C2 of the in-app camera (190, #382); wireframes `docs/ux-research/in-app-camera/wireframes.html` (screens
1–4: the "Blue arete · attempt 3" chip, ♥ HR, "Stop when I log the set", "auto-stops when you log the attempt")
**Context**: `pdd/context/decisions.md`

## Goal

User (2026-10-19): "do you think if we record a video should it automatically get tagged to the activity or
workout?" — it mostly was (a timed set / attempt's clips attach to it on STOP & LOG; a page recording to the
exercise). This makes it visible, controllable and complete.

## Approach

- `CameraContext` (title · detail · in-camera log label · logged count) passed by `RecordClipButton` to
  `SnappetCameraView`:
  - **Tag chip** top-left — "Bench Press · set 3" / "Blue arete · attempt 2" / "Bench Press · next set"; tap to
    toggle "Not tagged · Photos only" (the clip is saved, not attached).
  - **♥ live HR** top-right (`app.liveWorkout.latestHR`).
  - **Stop & log set / Stop attempt** next to Done (with "Stop when I log the set" on): ends the clip, waits for it to
    save, closes the camera, then the cover commits (timed set: STOP & LOG; attempt: STOP → outcome grid).
  - A set logged elsewhere (the watch) while filming from an exercise page ends the clip (`loggedCount` rises).
  - Tray row "Stop when I log the set".
- **Never dropped**: "Peek canvas" before logging a timed set / before STOP on an attempt hands its clips up
  (`onLeave`) → attached to the exercise with no set yet.
- **Claimed by the set they show**: pure `ClipSetClaim` — when a set is logged (`appendLog`), the exercise's
  manually-attached, set-less clips filmed since the previous set (5 s grace) move to it. Covers both page recordings
  and clips left by a closed cover.

## Acceptance criteria

- [x] `ClipSetClaimTests`: next set claims what was filmed since the previous; first set claims all before it; a
      clip after the set waits; grace; no completion → nothing; context label.
- [x] `SnappetCameraUITests.testStopAndLogFromTheCameraAndTheTagChip`: chip "… · set 1", toggle untagged and back,
      tray toggle, record → Stop & log set → camera closes, set logged.
- [ ] Device: page recording then Log set → the clip shows under that set; Peek canvas keeps clips; watch log stops
      a page recording; HR chip with a watch/band.
