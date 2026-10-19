# Prompt: The in-app camera — like the iPhone Camera, built for sets

**File**: pdd/prompts/features/190-ios-in-app-camera.md
**Created**: 2026-10-19
**Project type**: Native iOS feature (Swift / SwiftUI + AVFoundation) — code lands in this repo.
**Chain**: wireframes `docs/ux-research/in-app-camera/wireframes.html` (user picks: everything shown · photos too ·
last-used settings); C1 of 2 — 191 adds the Snappet layer (what it tags to, live HR, stop-when-I-log, tagging gaps)
**Context**: `pdd/context/decisions.md`

## Goal

User (2026-10-15): "when using camera to record the video from the app the video quality is coming out to be
blurry" → (2026-10-19) "can you make the camera more feature rich and let users pick different features in it like
the way iphone camera does it".

Root cause of the blur: `VideoRecorder` (a `UIImagePickerController`) never set `videoQuality`, so it recorded at the
picker's `.typeMedium` default (~480×360). It had been left unset out of caution after a device crash that was really
`setCameraCaptureMode:`. Replaced wholesale by a custom camera rather than patched (user: fold the fix in).

## Approach

- Pure `CameraSettings` / `CameraCapabilities` / `CameraLogic` (Features/Camera): mode (SLO-MO · VIDEO · PHOTO),
  resolution · fps, slo-mo rate, stabilization, countdown, grid, remember; capabilities from the device's formats +
  lens switch-over points; `resolve` clamps a pick the phone can't do; the chip halves (HD↔4K, 24→30→60 / 120↔240);
  lens labels ".5 / 1× / 3" with the live zoom; the timer; remembered settings (`camera.settings`).
- `CameraController` (Services, AVFoundation): the back virtual multi-lens device (zoom glides across lenses) or the
  front camera; movie output (+ audio) and photo output (also mid-clip); applies format / frame duration /
  stabilization (cinematic-extended → cinematic) / torch / zoom (display = device × `displayVideoZoomFactorMultiplier`)
  / focus+exposure at a point or locked; `RotationCoordinator` so a clip records the way the phone is held. Main-actor;
  only start/stop-running off-main (the `SnappetQRScannerController` pattern). `-uiTestFakeCamera` = no session,
  `CameraCapabilities.sample`.
- `SnappetCameraView`: the wireframe's screens 1–4 — top bar (torch · chip · countdown · ⌃), settings tray, lenses,
  pinch zoom, tap focus / long-press AE/AF LOCK, grid, modes, shutter, still mid-clip, countdown overlay, recording
  timer, capture count, Done; keeps the screen awake. Stays open for several captures.
- `RecordClipButton` presents it; photos save via `MediaLibraryService.savePhoto` and attach as `.photo`
  (`RecordedClip.isPhoto`). `VideoRecorder` deleted (`RecordedClip` moved to Features/Camera). DEBUG prints each
  saved recording's resolution (`[Camera] saved 1920x1080 3.7s`) for device checks.

## Acceptance criteria

- [x] `CameraSettingsTests`: capabilities from formats; clamping; chip cycling; countdown; lens labels + active
      lens + zoom clamp; remembered vs not; timer.
- [x] `SnappetCameraUITests` (fake camera): chip HD·30 → 60 → 4K·60, lenses, tray (3 s countdown, grid), countdown →
      recording timer + still + Done disabled, PHOTO hides the chip + counts, Done back to the set; settings remembered.
- [x] Device (MrRobot, 2026-10-19): user — "camera works fine"; two clips saved at 1920×1080 (was ~480×360).
- [ ] Device: slo-mo plays as slo-mo in Photos; 4K60; front camera; landscape-held clip orientation.
