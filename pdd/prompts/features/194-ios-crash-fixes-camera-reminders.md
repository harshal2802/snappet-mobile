# Prompt: Fix two crashes — opening the camera, tapping a routine reminder

**File**: pdd/prompts/features/194-ios-crash-fixes-camera-reminders.md
**Created**: 2026-10-20
**Project type**: Native iOS bug fix (Swift / AVFoundation / UserNotifications) — code lands in this repo.
**Context**: `pdd/context/decisions.md`; the in-app camera is prompts 190–191

## Bugs

User (2026-10-19): "when i was using the app today during workout app was crashing while opening the camera from the
app". Five Snappet crash reports pulled off the phone (`devicectl device copy from --domain-type systemCrashLogs`):

1. **Camera** (3 reports, SIGABRT): `-[AVCaptureSession startRunning]` raised inside `CameraController.start(with:)`.
   `start` dispatched `startRunning` to a GLOBAL queue, then `SnappetCameraView.onAppear` called `apply()` on main →
   `beginConfiguration`. `startRunning` between begin/commit raises. Timing-dependent; the simulator's fake camera
   has no session, so tests couldn't see it.
2. **Routine reminder tap** (2 reports, SIGABRT): `RoutineReminders.userNotificationCenter(_:didReceive:) async`
   (nonisolated) — iOS completes the async form off-main, and the completion's
   `-[UIApplication _performBlockAfterCATransactionCommitSynchronizes:]` asserts the main thread.

## Fix

1. `CameraController`: ONE serial `sessionQueue` for every session change — input/output wiring, format / preset /
   stabilization (+ the zoom re-apply after a format change), start/stop running, start/stop recording, photo
   capture (Apple's AVCam pattern). Device discovery + capabilities stay on main (no session mutation).
2. `RoutineReminders`: the completion-handler delegate forms; values read off the (non-Sendable) response at once,
   handled on the main actor, the completion called on main. The tap → action decision is the pure
   `RoutineReminders.outcome(of:)`.

## Acceptance criteria

- [x] `RoutineReminderTapTests`: start / skip / open, snooze keeps the original id (+ tapping a snoozed one opens),
      other categories / unparseable / dismiss ignored.
- [x] Unit 2505 green; camera + reminder UI suites green.
- [ ] Device: open the camera repeatedly mid-workout (and switch modes/lenses at once) — no crash; tap a reminder.
