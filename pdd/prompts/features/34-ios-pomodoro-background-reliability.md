# Prompt: Pomodoro — background reliability, notifications, Live Activity

**File**: pdd/prompts/features/34-ios-pomodoro-background-reliability.md
**Created**: 2026-06-10
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: PLAN-ios-to-shippable.md → background reliability
**Source**: GitHub issue [#70](https://github.com/harshal2802/snappet-mobile/issues/70)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Fix the two core broken behaviors of the Pomodoro focus timer: (1) the timer is silently
destroyed when the user navigates away (it's `@State` on a `navigationDestination` SwiftUI
destroys on pop), and (2) phase completion is signaled only by a foreground haptic, so locking
the phone for the full 25-minute block — the whole point — means the user never learns the
phase ended. Add a Live Activity so the countdown is visible on the Lock Screen and Dynamic
Island throughout the session.

## Context the implementer needs

- `PomodoroRootView.swift:18` — `@State private var timer = PomodoroTimer()` is destroyed
  on pop; the timer resets to idle every time the user navigates back to the App Library.
- `PomodoroTimer.swift:99-144` — `completePhase()` fires only `UINotificationFeedbackGenerator`;
  the 1s RunLoop ticker is suspended when the app is backgrounded.
- Parallel fix already applied for Kilter: `KilterRootView.swift:33-36` + `AppModel.swift:59-64`
  show exactly the hoist pattern to copy.
- Notification pattern: `WorkoutNotifications.swift` — schedule at start, cancel on stop.
- Live Activity pattern: `KilterLiveActivityController.swift` + `KilterLiveActivity.swift` +
  `KilterActivityAttributes.swift` — the full controller + widget + shared attributes triad.

## Approach

1. **Hoist timer**: move `PomodoroTimer` out of `@State` on `PomodoroRootView` and into `AppModel`
   (new property `pomodoroTimer`). Add three pure callbacks to `PomodoroTimer`:
   `onPhaseStarted((PomodoroPhase, Date) -> Void)`, `onPaused((PomodoroPhase, Date) -> Void)`,
   `onReset(() -> Void)`. Wire them in `PomodoroRootView.onAppear`.
2. **Notifications**: add `PomodoroNotifications` service (copy of `WorkoutNotifications`),
   owned by `AppModel`. `schedulePhaseEnd(phase:at:)` + `cancel()` + pure `phaseEndContent(phase:)`.
3. **Live Activity**: add `PomodoroActivityAttributes` in `Shared/` (endDate + phase + paused),
   `PomodoroLiveActivityController` service in `Services/`, `PomodoroLiveActivity` widget in
   `SnappetWidgets/`. Register widget in `SnappetWidgetsBundle`.
4. **Re-entry chip**: add `FocusRunningChip` banner to `AppLibraryView` when the timer is running.

## Output

- NEW: `ios/App/Shared/PomodoroActivityAttributes.swift`
- NEW: `ios/App/Snappet/Services/PomodoroNotifications.swift`
- NEW: `ios/App/Snappet/Services/PomodoroLiveActivityController.swift`
- NEW: `ios/App/SnappetWidgets/PomodoroLiveActivity.swift`
- NEW: `ios/App/SnappetTests/PomodoroNotificationsTests.swift`
- NEW: `ios/App/SnappetTests/PomodoroTimerTests.swift`
- NEW: `ios/App/SnappetTests/PomodoroLiveActivityTests.swift`
- MODIFIED: `ios/App/Snappet/Features/Pomodoro/PomodoroTimer.swift` (callbacks + expose endDate)
- MODIFIED: `ios/App/Snappet/Core/AppModel.swift` (add pomodoroTimer, pomodoroNotifications, pomodoroLiveActivity)
- MODIFIED: `ios/App/Snappet/Features/Pomodoro/PomodoroRootView.swift` (hoist timer, wire callbacks)
- MODIFIED: `ios/App/Snappet/Features/AppLibrary/AppLibraryView.swift` (FocusRunningChip)
- MODIFIED: `ios/App/SnappetWidgets/SnappetWidgetsBundle.swift` (add PomodoroLiveActivity)
- MODIFIED: `docs/knowledge-graph/data.js`
- MODIFIED: `pdd/context/decisions.md`

## Acceptance criteria

- [ ] Navigating away and back resumes the running session with correct remaining time
- [ ] Locking the phone for a whole focus block produces a notification at phase end
- [ ] Pause/reset cancels the pending notification
- [ ] Live Activity shows phase + countdown on Lock Screen and Dynamic Island
- [ ] Timer logic stays pure and unit-tested without a simulator
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings)
- [ ] `decisions.md` updated

## Constraints

- `PomodoroTimer` must stay platform-free (no `UserNotifications`, `ActivityKit`, `UIKit` imports).
- Notification and Live Activity services are no-ops when unauthorized or framework unavailable.
- Device verification is honest: build proves shape; Lock Screen rendering is device-pending.

## Test plan

1. `swift test` in `ios/HighlightEngine` — must pass (no engine changes here, just a sanity gate).
2. `xcodebuild build` for the `Snappet` scheme — must type-check with 0 errors.
3. `SnappetTests` — `PomodoroNotificationsTests`, `PomodoroTimerTests`, `PomodoroLiveActivityTests` pass.
4. Device: start a focus block, navigate to App Library — chip appears; tap it → returns to timer running.
5. Device: start a focus block, lock the phone — notification fires when the 25-minute phase ends.
6. Device: pause → notification cancelled; reset → Live Activity dismissed.
