# Prompt: Record a video clip while logging a timed set/attempt

**File**: pdd/prompts/features/98-ios-timed-set-record-clip.md
**Created**: 2026-06-23
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Live Workout Capture + Video Studio (#15) — session media tagging; the in-app capture half of "film however you like".
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

While **logging a timed set** (the count-up `TimedSetCover`), let the user open the camera, record a
video clip, and land **back on the same live set** when they're done — with the clip already attached to
that set. Today the only way to get a clip onto a set is to leave the app, film with the system Camera,
and either auto-discover the footage by capture-time window (full-Photos-access only) or hand-pick it from
the library after the fact. This closes that gap: capture is one tap inside the set you're timing, and the
recording is tied to exactly that set. The climb twin (`TimedAttemptCover`) gets the same affordance since
it's the direct parallel and shares the whole mechanism.

## Context the implementer needs

- `TimedSetCover` / `TimedAttemptCover` are full-screen `.fullScreenCover`s presented from
  `FreeformPlayerView`; they don't touch SwiftData — they time an effort and commit through a closure the
  parent turns into an `appendLog` (+ `SessionMedia` inserts live in the parent).
- The stopwatch (`StopwatchViewModel`) is **wall-clock-backed**, so presenting a child cover (the camera)
  over a timed cover keeps the set timer running — "come back to the set" needs no save/restore.
- `SessionMedia` stores only a Photos `localIdentifier` + a session-relative `offsetSec` (bytes stay in
  Photos). So an in-app recording must be **saved to Photos** to fit the model; the set tag is a
  `SessionMedia` row keyed to `(exerciseID, setIndex)` with `.manual` provenance (sticky vs the
  auto-reconciler, which only re-places `.auto` rows).
- There is **no in-app video recorder** yet. `SnappetScannerView` uses `AVCaptureSession` for QR metadata
  only; `MediaPicker` is the PHPicker. The Simulator has **no camera** → the real capture path is
  device-only.

## Approach

- **`Services/VideoRecorder.swift`** (new): a thin `UIImagePickerController(.camera, .video, movie-only)`
  representable (the recording analogue of `MediaPicker`) + the `RecordedClip` value (saved-asset id +
  `capturedAt` + duration) + a `static isAvailable` camera guard.
- **`Services/MediaLibraryService.swift`**: `saveVideoToPhotos` now `@discardableResult`-returns the new
  asset's `localIdentifier` (from its in-block placeholder); add `saveRecording(at:capturedAt:)` →
  reads duration via `AVURLAsset`, saves add-only, returns a `RecordedClip`. A `MutableBox` carries the id
  out of the `performChanges` block (the OUT sibling of the existing `Box`).
- **`Services/SessionMediaService.swift`**: a pure `candidate(for: RecordedClip, startedAt:)` → `Candidate`
  (always `.video`, offset clamped ≥ 0) — the tested funnel the attach path runs through.
- **`Features/WorkoutTracker/RecordClipButton.swift`** (new): the reusable in-cover control — opens the
  recorder, saves the recording to Photos immediately, accumulates `RecordedClip`s, shows an in-place
  "N clips will attach" confirmation, and surfaces a camera-unavailable notice on the Simulator.
  Parameterized (`idPrefix`/`attachNoun`) for the two covers.
- **The covers**: each gains the button + a `recordedClips` `@State`, and its commit closure carries the
  clips up (`TimedSetCover` on STOP & LOG; `TimedAttemptCover` on the outcome commit **and** the never-drop
  `onDisappear`, clearing `recordedClips` first so neither double-attaches).
- **`FreeformPlayerView`**: the two commit closures capture the landing `setIndex` **before** the append,
  then call a new `attachRecordedClips(_:toExerciseID:setIndex:)` that inserts `.manual` `SessionMedia`
  through `SessionMediaService.candidate(for:)`, deduped against existing session media.

## Output

- `ios/App/Snappet/Services/VideoRecorder.swift`, `ios/App/Snappet/Features/WorkoutTracker/RecordClipButton.swift` (new).
- `ios/App/Snappet/Services/MediaLibraryService.swift`, `ios/App/Snappet/Services/SessionMediaService.swift`.
- `ios/App/Snappet/Features/WorkoutTracker/TimedSetCover.swift`, `…/TimedAttemptCover.swift`, `…/FreeformPlayerView.swift`.
- `ios/App/Snappet/Resources/Info.plist` (`NSMicrophoneUsageDescription` + a broadened camera string).
- Tests: `ios/App/SnappetTests/RecordedClipAttachTests.swift`; a record-button case in `SnappetUITests/TimedStrengthSetTests.swift`.
- `docs/knowledge-graph/data.js`, `pdd/context/decisions.md`, `pdd/context/project.md`.

## Acceptance criteria

- [ ] The timed-set cover shows a "Record a clip" button (`timedSet.record`); on a real device it opens the
      camera, and finishing a recording returns to the still-running set with an "N clips will attach"
      confirmation.
- [ ] STOP & LOG attaches the recorded clip(s) to the just-logged set (a `.manual` `SessionMedia` at the
      new set's index); the climb attempt cover does the same on its outcome commit and its
      dismiss-after-stop path, without double-attaching.
- [ ] A recording is saved to the user's Photos library at record-time (not lost if the set isn't logged).
- [ ] On the Simulator (no camera), tapping Record surfaces the guard notice (`timedSet.recordNotice`); the
      button is never a silent no-op.
- [ ] App type-checks (Swift 6, 0 warnings); `RecordedClipAttachTests` + full `SnappetTests` green;
      `TimedStrengthSetTests` green.

## Constraints

- On-device only; no backend/network. Recordings live in the user's own Photos (add-only) — consistent with
  the `SessionMedia` "bytes stay in Photos" model and the privacy manifest.
- Keep the covers SwiftData-free; the `SessionMedia` insert stays in `FreeformPlayerView`.
- Camera capture is **device-only** — a type-check / Simulator run does NOT verify the record→save→attach
  flow. State that honestly.

## Test plan

1. `xcodebuild test … -only-testing:SnappetTests` (incl. `RecordedClipAttachTests`) + `TimedStrengthSetTests`
   — 0-warning build, suites green.
2. On a device, in a Quick Session: add a lifting exercise → Time this set → Record a clip → record → "Use
   Video" → confirm you're back on the running timer with "1 clip will attach" → STOP & LOG → the clip shows
   under the new set's `SetMediaStrip` and the video is in Photos. Repeat for a climb's Timed attempt.
