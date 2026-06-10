# Prompt: Pomodoro background reliability — persist timer, schedule notifications, add Live Activity

**File**: pdd/prompts/features/12-pomodoro-background-reliability.md
**Created**: 2026-06-10
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: GitHub issue #70
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Make the Pomodoro timer survive navigation and deliver a notification when a phase ends in the
background, then add a Lock Screen + Dynamic Island Live Activity. The two core Pomodoro behaviors
are broken: (1) the timer is `@State` on a `navigationDestination` view, so popping to the Apps
grid silently kills the session; (2) completion fires only a haptic from the in-view foreground
ticker, so locking the phone for the full 25-minute block means the user never learns the phase
ended. Both failures make the app useless as a background focus aid.

## Context the implementer needs

- `PomodoroTimer` (`Features/Pomodoro/PomodoroTimer.swift`): drift-free wall-clock engine (stores
  `endDate`, derives `remaining`). Currently `@State` on `PomodoroRootView`, destroyed on pop.
- Fix pattern: `KilterSessionManager` is owned by `AppModel` (not @State on `KilterRootView`) —
  same fix class, same solution (decisions.md 2026-06-07).
- Notification pattern: `WorkoutNotifications.scheduleRestComplete` — schedule at start, cancel on
  pause/reset; pure `restCompleteContent` is unit-tested.
- Live Activity pattern: `KilterActivityAttributes` (Shared/) + `KilterLiveActivityController`
  (Services/) + `KilterLiveActivity` (SnappetWidgets/) — three-file stack for the Kilter activity.

## Approach

1. **Hoist timer to AppModel**: add `pomodoroTimer`, `pomodoroNotifications`,
   `pomodoroLiveActivityController` to `AppModel`. `PomodoroRootView` reads the timer via
   `@Environment(AppModel.self)`, matching the `KilterRootView` → `app.kilterSessions` pattern.
2. **Expose `phaseEndDate`** from `PomodoroTimer` (currently `private var endDate`); add
   `onPhaseStarted: ((PomodoroPhase, Date) -> Void)?` fired from `start()` and `completePhase()`
   so services schedule against the wall-clock deadline without polling.
3. **Notifications**: `PomodoroNotifications` (Services/) schedules a `UNNotification` at
   `phaseEndDate` on every `onPhaseStarted` call; cleared on pause/reset; tested via pure
   `phaseCompleteContent(phase:)` without a device.
4. **Live Activity**: `PomodoroActivityAttributes` (Shared/), `PomodoroLiveActivityController`
   (Services/), `PomodoroLiveActivity` widget (SnappetWidgets/). The Lock Screen / Dynamic Island
   render a `Text(timerInterval: now...phaseEndDate, countsDown: true)` countdown off the wall
   clock — zero background CPU, correct across backgrounding.
5. **Re-entry banner**: `PomodoroFocusBanner` shown in `AppLibraryView` (the Apps-grid root)
   whenever `app.pomodoroTimer.isRunning`, so the user can tap to return to the timer.

## Output

- `ios/App/Shared/PomodoroActivityAttributes.swift` — ActivityKit contract
- `ios/App/Snappet/Services/PomodoroNotifications.swift` — UNNotification service
- `ios/App/Snappet/Services/PomodoroLiveActivityController.swift` — ActivityKit manager
- `ios/App/SnappetWidgets/PomodoroLiveActivity.swift` — Lock Screen + Dynamic Island widget
- `ios/App/SnappetTests/PomodoroNotificationsTests.swift` — pure unit tests
- Modified: `PomodoroTimer.swift`, `AppModel.swift`, `PomodoroRootView.swift`,
  `AppLibraryView.swift`, `SnappetWidgetsBundle.swift`, `decisions.md`, `data.js`

## Acceptance criteria

- [ ] Navigating away from Pomodoro and back resumes the running session with correct remaining time.
- [ ] Locking the phone for a full focus block delivers a notification at phase end.
- [ ] Pause/reset cancels the pending notification.
- [ ] Live Activity shows phase + countdown on Lock Screen and Dynamic Island.
- [ ] A "focus running" banner appears in the Apps grid while the timer is running.
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).
- [ ] `PomodoroNotificationsTests` passes with `SnappetTests` (no device needed).
- [ ] `decisions.md` updated with the hoist rationale.
- [ ] `docs/knowledge-graph/data.js` updated with new service + widget nodes.

## Constraints

- `PomodoroTimer` must remain platform-free (no UIKit/ActivityKit/UserNotifications imports).
  Platform I/O stays in Services/.
- Live Activity rendering needs a device for final verification (documented in decisions.md).

## Test plan

1. `swift test` on `HighlightEngine` (no change expected — no engine touch).
2. `SnappetTests` suite: `PomodoroNotificationsTests` covers `phaseCompleteContent` — no device.
3. Device/simulator (deferred): navigate away while timer runs → return → correct time;
   full-phase lock-screen notification; Live Activity Lock Screen + Dynamic Island countdown.
