# Prompt: Racket pro camera, before recording — Apple Camera's layout for framing a match (prompt 255)

**File**: pdd/prompts/features/racket-sports/255-ios-racket-pro-camera.md
**Created**: 2026-11-14
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: GitHub issue [#448](https://github.com/harshal2802/snappet-mobile/issues/448) part 2, the "Before recording"
checklist (third of four jobs: player Watch → player Edit + Share → camera before recording → camera while recording).
Stacked on prompt 254 (`claude/racket-player-edit`).
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Boards (source of truth)**: `racket-wireframes/boards2/` — ProCamera, ProCameraZoom, ProCameraFocus, ProCameraLock,
ProCameraQuality, ProCameraOptions, ProCameraLooks, ProCameraDenied.

## Goal

Frame a match the way the Camera app frames a video: the live picture full screen, a status pill (ready, recording time
left at this quality, battery) and the quality label on top; lens buttons, a zoom dial and pinch; tap to focus with a
brightness slider, touch and hold for AE/AF lock; a Video quality page with honest time, size and heat; the mode strip
Game by game / Everything; a shutter that starts recording through today's start path; Options (framing overlays, who
serves first, what to show while playing, the Watch, live tracking "Not available yet", Looks, Compare quality); a
preview-only Looks strip; and the no-access state. Zoom, lens, focus / exposure lock and quality chosen here carry into the
recording.

## User decisions this prompt follows

- Wireframes are the source of truth; explicit user decisions override them. Capability labels tell the truth.
- A tap on the camera always means focus. Looks are presets for playback and shared copies only; the recorded file is
  never filtered; the look picked on the camera becomes the match's playback look ("Whole match").
- Rally detection is vision only; no BlurBall weights; never commit real footage or phone screenshots.
- Only the lenses, zoom and formats the phone really has are shown.
- The recording-time screens are the next job: they keep working unchanged.

## Approach

- **Pure** (`RacketProCamera.swift`, Foundation only, `RacketProCameraTests`): `RacketCameraCapabilities` (from a plain
  description of the discovered device: ultra-wide, switch-over factors, quality-crop factors, zoom limits, formats) →
  lens buttons; `RacketZoomDial` (log mapping position ↔ zoom, clamping, drag and pinch, the selected lens and its "1.4×"
  label, VoiceOver steps); `RacketCameraFormat` (HD · 30 / HD · 60 / 4K · 30 / 4K · 60, which formats a device supports,
  which device format to pick); `RacketQualityEstimate` (time and GB per hour from the bitrate table and free space, heat
  notes); `RacketCameraStatus` (the pill); `RacketFocusPoint` (a tap in the letterboxed portrait preview → the device's
  point of interest); `RacketExposureBias`; `RacketLevel` (tilt and the level threshold); `RacketLookPreview` (the
  live-preview approximation of each look); `RacketCameraSetup` (what carries into the recording).
- **Services** (`RacketRecorder`): discover the back virtual multi-camera device (triple → dual wide → dual → wide), apply
  the chosen format (active format + frame duration), zoom (ramped), focus / exposure at a point, lock, bias; report the
  capabilities; apply a carried `RacketCameraSetup` on configure. The fake (`-uiTestFakeCamera`) keeps the same state with
  a fake capability set (launch-argument overrides for the lens set, free space and battery).
- **Screens** (`RacketProCameraViews.swift`): the camera, the dial, the focus square and slider, the lock badge, the
  Video quality page, the Options sheet, the Looks strip, the denied state; framing overlays (grid, level via CoreMotion,
  court guide) drawn over the preview only.
- **Wiring**: the match's game cover opens on the pro camera in place of the camera check and Warmup (every Warmup choice
  moves to the mode strip or Options); Game by game → the existing start; Everything → the existing storage check → record
  everything, with the setup carried into the new recorder. The log stamps the frame rate and the look (additive).

## Acceptance criteria

- [ ] All eight boards reachable on the simulator (fake camera) and checked against their PNGs.
- [ ] Lens buttons, zoom range and formats come from the device; nothing the phone lacks is shown.
- [ ] Unit tests for every pure piece listed above.
- [ ] UI suite `RacketProCameraUITests`; the racket suites that pass through the camera updated and green.
- [ ] A device build passes; the camera suite walked on the phone (no recording saved).
- [ ] `decisions.md`, `project.md`, `docs/knowledge-graph/data.js` updated.

## Test plan

1. `SnappetTests` serial. 2. `RacketProCameraUITests`, then every racket suite that touches recording or the camera, one
at a time, app uninstalled first. 3. Board walk screenshots to `shots/pro-camera/`. 4. Device build; the camera suite on
the phone with the real camera, stopping before the shutter.
