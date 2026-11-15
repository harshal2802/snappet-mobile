# Prompt: Racket pro camera, while recording — the Camera app's recording layout and what happens when something goes wrong (prompt 256)

**File**: pdd/prompts/features/racket-sports/256-ios-racket-pro-camera-recording.md
**Created**: 2026-11-14
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: GitHub issue [#448](https://github.com/harshal2802/snappet-mobile/issues/448) part 2, the "While recording"
checklist (fourth of four jobs). Stacked on prompt 255 (`claude/racket-pro-camera`).
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Boards (source of truth)**: `racket-wireframes/boards2/` — ProCameraRecording, ProCameraEverything, ProCameraStop,
ProCameraDim, ProCameraBreak, ProCameraDrill, ProCameraWarm, ProCameraHot, ProCameraInterrupted, ProCameraSpace,
ProCameraLandscape.

## Goal

Record on the same camera that framed the match: the game and score, a red timer, the quality locked; lenses, zoom, tap to
focus and AE/AF lock still working; DIM / CAMERA / STATS; Tag, a one-tap stop square and Mark. Stop opens the score sheet,
which can undo the stop ("That was a mistake, keep playing game 1"). The break sits on the camera with the lens and quality
unlocked; record everything gets "New game starts"; a drill block gets its timer; warm, too hot, interrupted, low space /
battery / Watch off each have one honest state; the camera lays out sideways.

## User decisions this prompt follows

- Wireframes are the source of truth; explicit user decisions override them. Labels tell the truth.
- A tap on the camera is always focus. The record button is tap to start, tap to stop; stopping opens the score sheet,
  which carries "That was a mistake, keep playing".
- A quality change never happens mid-file. Nothing records into the video but the picture (overlays are preview only).
- Rally detection is vision only; no BlurBall weights; no real footage committed.

## Approach

- **Pure** (`RacketProCameraRecording.swift`, `RacketProCameraRecordingTests`): timer / header copy, `RacketCameraBanner`
  (which banner for which thermal / interruption / space inputs, with priorities), `RacketInterruptionCopy` (per reason,
  auto-resume), `RacketCameraTrouble` (the status pill's troubles), `RacketSpaceGuard` (warn and stop thresholds),
  `RacketPendingFormat` ("HD · 30 from next game"), `RacketCameraOrientation` (sideways layout and tap mapping). The flow's
  `cancelScore` returns `.resumeCapture`; the machine resumes after heat only when cooled.
- **Services**: the recorder reports the end of an interruption, simulates heat and calls for the fake camera, reports
  charging, and turns the preview with the interface orientation.
- **Screens**: `RacketCameraLive` (what a recording screen hands the camera) drawn by `RacketProCameraView`; the game cover,
  the record-everything cover and the drill cover build it; the score sheet follows ProCameraStop.

## Acceptance criteria

- [ ] All 11 boards reachable on the simulator and checked against their PNGs.
- [ ] Stop → sheet → keep playing keeps the game, its score and rallies, and recording.
- [ ] Unit tests for every pure decision above; UI suite `RacketProCameraRecordingUITests`; every racket UI suite green.
- [ ] Device build passes.
- [ ] `decisions.md`, `project.md`, `docs/knowledge-graph/data.js` updated.

## Test plan

1. `SnappetTests` serial. 2. Every `Racket*UITests` suite one at a time, app uninstalled first. 3. Board screenshots to
`shots/pro-camera-recording/`. 4. Device build (the phone id, else generic iOS). 5. On the phone when reachable: part A's
`testReportsWhatThisCameraHas`.
