# Prompt: Five broken links and stale states in the workout tracker (prompt 265)

**File**: pdd/prompts/features/265-ios-workout-broken-links.md
**Created**: 2026-11-16
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo (phone, Watch, widget).
**Chain**: the Workout Tracker state-machine review (findings F10, F11, F12, F13, F15), after prompt 263.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md` (no new field, no new raw value)

## Goal

The read-only review of the workout tracker's state machines found five places where a link goes nowhere or a state
goes stale. Fix all five in one PR, each as a pure, unit-tested rule with a thin edge on top. Verify each claim on
today's main first (#458 and #459 changed nearby code).

- **F10** After a phone app kill mid-match the Watch keeps the racket face with no way back (the phone only sends
  `.clear` from `detach` in the same process; Watch taps for that match are dropped silently).
- **F11** A rally scan running in the background is not stopped when its session is deleted; the job keeps reading and
  writing `session.exercises` of a deleted SwiftData model.
- **F12** A planned session's Start (the smart planner) silently resumes the running workout and drops the plan.
- **F13** A reminder's "Start now" for a deleted or empty routine does nothing, with no message.
- **F15** Tapping the workout Live Activity doesn't open the workout (no `widgetURL`).

## Context the implementer needs

- `RootShell.dispatch` is the one place Siri / Shortcuts actions and `snappet://` workout links navigate; #459 made it
  refuse `.finishSession` while a racket cover is open (`RacketLiveCovers`), because `router.open(module:)` replaces
  the stack and tears the player down with every cover on it. Opening the workout must follow the same rule.
- `WorkoutHomeView` (`WorkoutTrackerModule.swift`) owns the player (`playing`), `startPlannedSession`, and the
  `pendingRoutineStart` consumer; `WorkoutPlanView` is pushed above it.
- Racket on the Watch: `RacketWatchRelay` (phone), `RacketWatchModel` (Watch), wire `Shared/RacketWatchMessage.swift`.
  Snapshots carry a rising `revision` (seeded from the clock, so it keeps rising across relaunches).
- `RacketScanCenter` holds `Job`s with a `RacketVideoStore` (session + context) and writes scan records to the log.
- `SessionCascade.deleteWorkoutSession` is the one delete path (History, session detail, Finish discard, Discard &
  start new, watch-import reconcile).

## Approach

One pure file `WorkoutBrokenLinks.swift` (no SwiftUI / UIKit / Photos), plus the Watch rules in `Shared/`:

| Finding | Rule | Used by |
|---|---|---|
| F10 | `RacketWatchFreshness` (Shared): admit only snapshots newer than the last clear; `clearAll(through:)` drops a face not newer than it; a tap with no answer in 15 s leaves the face. `RacketWatchClearRule`: when the phone broadcasts; a tap for an unshown match gets `.clear` | `RacketWatchModel`, `RacketWatchRelay` |
| F11 | `RacketScanSessionDrop.plan` — the session's scans leave the queue, its running one is cancelled | `RacketScanCenter.forgetSession` from `SessionCascade` |
| F12 | `PlannedStart.decide(running:)` — Start while a workout runs asks: Go to running workout / Cancel | `WorkoutPlanView` |
| F13 | `ReminderStart.outcome(routine:)` — a gone / empty routine says so; land on the dashboard | `WorkoutHomeView` |
| F15 | `WorkoutOpenLink.decide(playerOpen:openCover:)` — stay over an open player or racket cover, else open | `RootShell.dispatch(.openWorkout)` |

- **F10 wire**: new message `RacketWatchMessage.clearAll(through: Int)` (kind `clearAll`). The phone sends it at
  WatchConnectivity activation when nothing is attached (a relaunch), and when a session ends (finish via
  `WorkoutSessionFinisher`, discard / delete via `SessionCascade`) unless another session's screen is attached. A tap
  for a match the phone shows nothing for is answered with `.clear`; a tap that changed nothing re-sends the snapshot
  after 1 s, so "no answer" really means the phone is gone. The Watch leaves on its own after 15 s without an answer.
- **F11**: `Job` remembers its session id; `forgetSession` removes jobs without writing and cancels the running one;
  every write / record read / result for a deleted session is dropped (`deletedSessionIDs`; an enqueue for a session
  takes its id back out, so a restored backup can scan again).
- **F12**: the planner shows the alert itself (it is on top of the stack). "Go to running workout" resumes the player
  over the planner; the plan's state lives in the planner, which stays pushed. No "discard and start" here: it would
  delete the running workout's work.
- **F15**: `snappet://workout` parses to `WorkoutLinkAction.open` → `PendingAppAction.openWorkout` →
  `AppActionRouter` (`workout-log`, `resumeWorkout`) → `pendingWorkoutResume`. `SuiteRouter.workoutPlayerOpen` is set
  by `WorkoutHomeView` from its `playing` and cleared by `open(module:)`. The widget sets `widgetURL` on the Lock
  Screen view and the Dynamic Island (`WorkoutActivityAttributes.openURL`).

## Output

- New: `Snappet/Features/WorkoutTracker/WorkoutBrokenLinks.swift`, `Shared/RacketWatchFreshness.swift`,
  `SnappetTests/WorkoutBrokenLinksTests.swift`, `SnappetUITests/WorkoutBrokenLinksUITests.swift`.
- Changed: `Shared/RacketWatchMessage.swift`, `Shared/AppActionInbox.swift`, `Shared/WorkoutActivityAttributes.swift`,
  `SnappetWatch/RacketWatchModel.swift`, `SnappetWidgets/WorkoutLiveActivity.swift`, `Services/RacketWatchRelay.swift`,
  `Services/AppleWatchMetricsSource.swift`, `Services/RacketScanCenter.swift`, `SessionCascade.swift`,
  `WorkoutSessionFinisher.swift`, `WorkoutTrackerModule.swift`, `WorkoutPlanView.swift`, `WorkoutIntentService.swift`,
  `AppActionRouter.swift`, `RootShell.swift` (plus the `-uiTestReminderStart missing|empty` hook), `SuiteRouter.swift`.

## Acceptance criteria

- [ ] F10: a racket face on the Watch goes away when the phone relaunches, when its session ends, when a tap reaches a
      phone with no screen for it, and on its own 15 s after an unanswered tap; a late queued snapshot can't bring it
      back; another session's live face is never cleared.
- [ ] F11: deleting a session (every path) takes its scans out of the queue and cancels the running one; nothing is
      written to the deleted session afterwards.
- [ ] F12: Start on a plan while a workout runs shows "A workout is already running" with Go to running workout /
      Cancel; neither loses the plan; nothing is resumed or replaced silently.
- [ ] F13: Start now for a deleted routine says "Routine not found", for an empty one "Nothing to start", and lands on
      the workout dashboard.
- [ ] F15: the Live Activity tap opens the running workout's player; over an open player or racket recording / drill /
      game screen it changes nothing (the recording keeps going).
- [ ] `decisions.md`, `project.md`, `docs/knowledge-graph/data.js` updated; the Watch app and widget build.

## Constraints

Simulator only (the real Watch and a real Live Activity tap are device-pending); wording plain, no em dashes in UI
strings; existing ids and tests keep working; nothing deletes or silently discards the user's work.

## Test plan

1. `SnappetTests` (all), including `WorkoutBrokenLinksTests`.
2. `WorkoutBrokenLinksUITests` (F12, F13 with `-uiTestReminderStart`, F15 by opening the link in the running app, with
   the fake camera for the recording case), plus `WorkoutWalkthroughTests`, `WorkoutLinkUITests`,
   `LiveSessionSafetyUITests`, `RacketVideosUITests`, `RacketTaggingUITests`, `WorkoutPlanFlowTests`,
   `RoutineScheduleUITests`.
