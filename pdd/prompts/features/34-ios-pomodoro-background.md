# Prompt: Pomodoro background survival — timer hoist, notifications, Live Activity

**File**: pdd/prompts/features/34-ios-pomodoro-background.md
**Created**: 2026-06-10
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Source**: GitHub issue [#70](https://github.com/harshal2802/snappet-mobile/issues/70)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Fix the two core reliability gaps in the Pomodoro mini-app:

1. **Navigation bug**: `PomodoroTimer` is `@State` on `PomodoroRootView`, which is a
   `navigationDestination` SwiftUI destroys on pop. Navigating back to the Apps grid —
   exactly what the suite encourages — silently kills the running session.

2. **Background notification**: phase completion fires only a haptic from the in-view
   foreground ticker. Locking the phone for a full focus block means the user never learns
   the phase ended. A scheduled `UNCalendarNotificationTrigger` reaches the user regardless
   of app state.

Also adds a **Live Activity** (Lock Screen + Dynamic Island phase-label + countdown) so
the running session is visible at a glance, and a **re-entry banner** in the App Library
so the user can easily return to the running timer.

## Context the implementer needs

- `PomodoroRootView.swift:18` — `@State private var timer = PomodoroTimer()`, destroyed on pop.
- `PomodoroTimer.swift:99–114` — `completePhase()` fires only `UINotificationFeedbackGenerator`;
  no `UserNotifications`/ActivityKit/scenePhase anywhere in `Features/Pomodoro`.
- `KilterRootView.swift:33–36` — documents the exact same `@State`-on-`navigationDestination`
  bug class and the fix: hoist to `AppModel`.
- `WorkoutNotifications.swift:31–36` — schedule-at-start pattern; schedules at phase **start**,
  fires at phase **end**, cancels on pause/reset. `UNCalendarNotificationTrigger` survives
  suspension; a `RunLoop` timer does not.
- `LiveActivityController.swift` + `KilterLiveActivityController.swift` — the Live Activity
  pattern: `Activity<Attributes>` inside an `Any` box, `nonisolated(unsafe)` for the detached
  async update, `@available(iOS 16.1, *)` guards.
- `Shared/KilterActivityAttributes.swift` + `Shared/WorkoutActivityAttributes.swift` — how the
  shared contract is structured: static attributes (fixed for activity lifetime) and `ContentState`
  (pushed on each update). Compiled into both app + widget via `project.yml`'s `Shared/` path.

## Approach

1. **Hoist timer to `AppModel`** (`let pomodoroTimer = PomodoroTimer()`) and remove
   `@State` from `PomodoroRootView`. Add `onPhaseDidStart(phase, endDate)` and
   `onTimerDidStop` callbacks to `PomodoroTimer`. Wire them in `AppModel.init()` to the
   two new services. The view-local `onFocusCompleted` callback stays on the view
   (it needs `modelContext`); it survives the pop because the closure captures the
   context by reference and remains set on the timer until the view next appears.

2. **Notifications** — new `PomodoroNotifications` service (mirrors `WorkoutNotifications`).
   `schedulePhaseEnd(phase:at:)` uses a `UNCalendarNotificationTrigger` for absolute
   wall-clock firing. `clear()` removes pending + delivered alerts. Pure `phaseEndContent`
   is unit-tested.

3. **Live Activity** — `PomodoroActivityAttributes` in `Shared/` (compiled into app + widget).
   `ContentState` carries `phaseEndDate: Date` (countdown target), `phaseLabel: String`,
   `paused: Bool`. `PomodoroLiveActivityController` in `Services/`. `PomodoroLiveActivity`
   widget in `SnappetWidgets/`; added to `SnappetWidgetsBundle`. The countdown uses
   `Text(timerInterval: now...state.phaseEndDate, countsDown: true)` — OS-ticked, no CPU.

4. **Re-entry banner** — `PomodoroFocusBanner` private struct in `AppLibraryView`, visible
   when `app.pomodoroTimer.isRunning`. Taps push `ModuleRoute(id: "pomodoro")` onto the
   shared `SuiteRouter`. `AppLibraryView` gains `@Environment(AppModel.self)`.

## Output

- `ios/App/Shared/PomodoroActivityAttributes.swift` — Live Activity contract.
- `ios/App/Snappet/Services/PomodoroNotifications.swift` — notification service.
- `ios/App/Snappet/Services/PomodoroLiveActivityController.swift` — Live Activity controller.
- `ios/App/SnappetWidgets/PomodoroLiveActivity.swift` — widget renderer.
- `ios/App/Snappet/Features/Pomodoro/PomodoroTimer.swift` — add callbacks.
- `ios/App/Snappet/Core/AppModel.swift` — hoist timer + services, `init()` wires callbacks.
- `ios/App/Snappet/Features/Pomodoro/PomodoroRootView.swift` — reference AppModel timer.
- `ios/App/Snappet/Features/AppLibrary/AppLibraryView.swift` — `PomodoroFocusBanner`.
- `ios/App/SnappetWidgets/SnappetWidgetsBundle.swift` — add `PomodoroLiveActivity()`.
- `ios/App/SnappetTests/PomodoroNotificationsTests.swift` — pure content builder tests.
- `ios/App/SnappetTests/PomodoroTimerTests.swift` — pure engine tests.
- `docs/knowledge-graph/data.js` — new nodes + edges.
- `pdd/context/decisions.md` — decision record.

## Acceptance criteria

- [ ] Navigating away and back resumes the running session with correct remaining time.
- [ ] Locking the phone for a whole focus block produces a notification at phase end.
- [ ] Pause/reset cancels the pending notification.
- [ ] Live Activity shows phase + countdown on Lock Screen and Dynamic Island.
- [ ] Timer logic stays pure and unit-tested without a simulator.
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).
- [ ] `decisions.md` updated.
- [ ] Knowledge graph updated.

## Constraints

- `PomodoroTimer` must stay pure — no `ActivityKit` / `UserNotifications` imports.
- `PomodoroActivityAttributes` goes in `ios/App/Shared/` (same rule as all activity contracts).
- Service callbacks must follow the `WorkoutNotifications`/`KilterLiveActivityController` patterns.
- `HighlightEngine` must not be touched.

## Test plan

1. `cd ios/HighlightEngine && swift test` — engine tests unaffected (no change).
2. `cd ios/App && xcodebuild test -scheme Snappet -destination '...'` — `PomodoroNotificationsTests`
   and `PomodoroTimerTests` pass without a simulator.
3. Device: start timer → navigate to App Library → `PomodoroFocusBanner` appears.
4. Device: tap banner → navigates back to Pomodoro with correct remaining time.
5. Device: start timer → lock phone → wait for phase end → notification fires.
6. Device: start timer → pause → pending notification is cancelled.
7. Device: start timer → verify Live Activity countdown on Lock Screen + Dynamic Island.
8. Device: phase auto-transitions → Live Activity updates to new phase + new countdown.
