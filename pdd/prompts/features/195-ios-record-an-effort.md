# Prompt: "Record a set / an attempt" — recording IS logging the effort

**File**: pdd/prompts/features/195-ios-record-an-effort.md
**Created**: 2026-10-20
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: the in-app camera (190–191, 194); builds on 191's `CameraContext` stop-and-log + `ClipSetClaim`
**Context**: `pdd/context/decisions.md`

## Goal

User (2026-10-20, after verifying the crash fixes): "record a clip should be record an attempt and it should update
to sets". On an exercise's page, recording is logging an effort, not just attaching footage.

## Approach

- The page's record button reads **Record a set** / **Record an attempt** / **Record a leg**
  (`QuickSessionPager.recordTitle`); the camera's tag chip "Bench Press · set 3" and its button **Stop & log set** /
  **Stop attempt** (`CameraContext.logLabel`, shown with "Stop when I log the set" on).
- `FreeformPlayerView.logRecordedEffort`: files the just-saved clips to the exercise first (so the claim sees them
  whichever `onChange` ran), then:
  - lift → `appendLog(SetLog(reps × weight from quickAddSeed, durationSec = the clip's length))`;
  - hold / run / other → a set with the clip's duration;
  - climb → `RecordedAttemptOutcomeSheet` ("How did it go?" — the page's `OutcomeGridView`; dismissing or "Save as
    attempt" logs a plain attempt, never dropping the effort) → `logAttempt(status, duration)`.
  The new effort claims the clip (`claimFilmedClips`, prompt 191).
- **Done** without logging is unchanged: the clip waits on the exercise for its next logged set.
- Fake-camera detection also honours `SNAPPET_FAKE_CAMERA=1` (a UI-test launch intermittently didn't see the arg).

## Acceptance criteria

- [x] `SnappetCameraUITests.testRecordASetLogsTheSetWithItsClip` — "Record a set" → chip "· set 1" → record →
      Stop & log set → a set row.
- [x] `testRecordAnAttemptAsksHowItWent` — "Record an attempt" → Stop attempt → How did it go? → Sent → attempt row.
- [ ] Device: the filmed set/attempt shows its clip under it; the set's duration = the clip's length.
