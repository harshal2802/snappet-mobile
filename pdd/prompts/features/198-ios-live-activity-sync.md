# Prompt: Fix — the Lock Screen never shows a session that has ended

**File**: pdd/prompts/features/198-ios-live-activity-sync.md
**Created**: 2026-10-20
**Project type**: Native iOS bug fix (Swift / ActivityKit) — code lands in this repo.
**Context**: `pdd/context/decisions.md`

## Bug

User (2026-10-19): "notification bar is not always in synced with app. sometimes even when i stop the session
notification bar shows the session is on".

Cause (code read; every in-app end path does call `end()` — the finisher, discard, the festival night, Kilter's
`end(sessionID:)`): `LiveActivityController` only knew the activity it started in the CURRENT run of the app, and
`end()` was a no-op without it. iOS keeps a Live Activity after the app is gone — a crash (three camera crashes that
day), the system closing it in the background, a relaunch. The next launch's resume then requested a SECOND
activity, and finishing ended only that one: the old one stayed on the Lock Screen saying the session was on.

## Fix

- Pure `LiveActivityReconcile.plan(running:activeSessionStartedAt:)`: keep the activity whose `startedAt` matches the
  session actually running (to the second), end every other; no session running → end all.
- `LiveActivityController` + `KilterLiveActivityController`:
  - `reconcile(activeSessionStartedAt:)` over ALL `Activity<…Attributes>.activities` — adopt the kept one (a
    relaunch lost the handle, not the activity), end the rest;
  - `start` reconciles first and ADOPTS the session's own activity instead of requesting a duplicate;
  - `end()` ends every workout / board activity, including orphans.
- `RootShell` reconciles at launch and on every return to the foreground from the store (the running
  `WorkoutSession` — `completedAt == nil` — and the running `KilterSession` — `endedAt == nil`).

## Acceptance criteria

- [x] `LiveActivityReconcileTests`: none running → end all; keep the session's, end the orphan; a resume adopts;
      nothing to do.
- [x] Unit 2520 green; session-lifecycle UI suites green.
- [ ] Device: start a session, force-quit Snappet, reopen and finish → no activity left; resume after a force-quit
      shows ONE activity.
