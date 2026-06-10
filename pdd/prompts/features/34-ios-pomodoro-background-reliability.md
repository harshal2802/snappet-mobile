# Prompt: Pomodoro background reliability + Live Activity

**File**: pdd/prompts/features/34-ios-pomodoro-background-reliability.md
**Created**: 2026-06-10
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: GitHub issue #70 (2026-06-10 product review)
**Source**: GitHub issue #70 — Pomodoro background reliability + Live Activity
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Fix the two core reliability gaps of the Pomodoro focus timer: (1) the timer lived in `@State` on
`PomodoroRootView`, a `navigationDestination` SwiftUI destroys on pop — so navigating back to the
App Library silently killed a running session; (2) phase completion was signalled only by a haptic
from the in-view foreground ticker, so locking the phone for the full 25-minute block meant the
user never saw the phase-end alert. Adds a Live Activity (Lock Screen + Dynamic Island) for the
same "timer visible without the app" UX the Workout and Kilter modules already have.

## Context the implementer needs

- `PomodoroRootView.swift:18` — `@State private var timer = PomodoroTimer()`, destroyed on pop
  (issue confirmed by the Kilter 2026-06-07 decision: same bug class, same root cause).
- `PomodoroTimer.swift:99–144` — RunLoop ticker; `completePhase()` fires only a haptic; no
  `UserNotifications` / ActivityKit anywhere in the Pomodoro module.
- **Copy pattern**: `WorkoutNotifications.swift` (schedule-at-start UNNotification);
  `KilterRootView.swift:33–36` (hoist-to-AppModel fix for stale-on-pop); `KilterLiveActivityController.swift`
  + `KilterLiveActivity.swift` (dedicated Live Activity controller + widget renderer).
- `PomodoroActivityAttributes` lives in `ios/App/Shared/` (like `KilterActivityAttributes`) so the
  app target and the widget extension share one contract.

## Approach

1. **Hoist timer to AppModel** — add `let pomodoroTimer = PomodoroTimer()` alongside the existing
   `kilterSessions`. `PomodoroRootView` reads it via `@Environment(AppModel.self)` instead of
   `@State`. No structural change to the timer itself.

2. **Phase-complete notifications** — new `PomodoroNotifications` service in `Services/` (mirrors
   `WorkoutNotifications`). Scheduled when a phase starts, cancelled on pause/reset. Pure
   `phaseCompleteContent` is unit-tested without a device.

3. **Live Activity** — `PomodoroActivityAttributes` in `Shared/` (phase label + `endDate` for
   `Text(timerInterval:countsDown:true)`), `PomodoroLiveActivityController` in `Services/`,
   `PomodoroLiveActivity` renderer in `SnappetWidgets/`. Bundle registers the third widget.

4. **Re-entry chip** — `FocusRunningChip` shown in `AppLibraryView` when `app.pomodoroTimer.isRunning`,
   tapping pushes `ModuleRoute(id: "pomodoro")` onto the shared `SuiteRouter`.

## Output

New files:
- `ios/App/Shared/PomodoroActivityAttributes.swift`
- `ios/App/Snappet/Services/PomodoroNotifications.swift`
- `ios/App/Snappet/Services/PomodoroLiveActivityController.swift`
- `ios/App/SnappetWidgets/PomodoroLiveActivity.swift`
- `ios/App/SnappetTests/PomodoroNotificationsTests.swift`
- `ios/App/SnappetTests/PomodoroTimerTests.swift`

Modified files:
- `ios/App/Snappet/Core/AppModel.swift` — add `pomodoroTimer`, `pomodoroNotifications`, `pomodoroLiveActivity`
- `ios/App/Snappet/Features/Pomodoro/PomodoroRootView.swift` — remove `@State timer`, wire new services
- `ios/App/Snappet/Features/Pomodoro/PomodoroTimer.swift` — expose `phaseEndDate`
- `ios/App/Snappet/Features/AppLibrary/AppLibraryView.swift` — add `FocusRunningChip`
- `ios/App/SnappetWidgets/SnappetWidgetsBundle.swift` — add `PomodoroLiveActivity()`
- `docs/knowledge-graph/data.js` — add new nodes + links
- `pdd/context/decisions.md` — record the hoisting decision

## Acceptance criteria

- [ ] Navigating away from Pomodoro and back resumes the running session with correct remaining time
- [ ] Locking the phone for a whole focus block produces a notification at phase end
- [ ] Pause/reset cancels the pending notification
- [ ] Live Activity shows phase + countdown on Lock Screen and Dynamic Island
- [ ] Re-entry chip visible on App Library when timer is running
- [ ] Timer logic stays pure and unit-tested without a simulator
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings)
- [ ] `decisions.md` updated

## Constraints

- `HighlightEngine` untouched (no platform import added).
- Live Activity rendering is device-pending verification (same class as Kilter's).
- No backend/network — local `UserNotifications` + `ActivityKit` only.

## Test plan

1. `swift test` from `ios/HighlightEngine` — engine tests unaffected.
2. `PomodoroNotificationsTests` and `PomodoroTimerTests` in `SnappetTests` — pure-logic, no device.
3. Device/sim: start a focus block, navigate to Apps tab, verify chip is visible and tapping
   returns to the running timer; lock the phone for the block duration; receive the notification.
