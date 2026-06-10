# Prompt: Pomodoro survives navigation + alerts in the background + Live Activity

**File**: pdd/prompts/features/35-ios-pomodoro-background-reliability.md
**Created**: 2026-06-10
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Product-review roadmap [#100](https://github.com/harshal2802/snappet-mobile/issues/100) → Wave 1
**Source**: GitHub issue [#70](https://github.com/harshal2802/snappet-mobile/issues/70)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

The two core behaviors of a focus timer are broken. (1) The running `PomodoroTimer` is
`@State` on a navigationDestination, so popping back to the Apps grid silently kills the
session. (2) Completion is signaled only by a haptic from the in-view foreground ticker,
so locking the phone for the 25-minute block — the whole point of the technique — means
the user never learns the phase ended. Fix both by reusing the suite's proven patterns,
and add a Lock Screen / Dynamic Island countdown.

## Context the implementer needs

- The engine (`PomodoroTimer`) is already wall-clock-correct (absolute `endDate`,
  `remaining` derived per tick) — nothing about the math changes.
- In-repo solutions to copy, not invent:
  - **Hoist to `AppModel`** — the documented fix for this exact stale-on-pop bug class
    (`KilterSessionManager`, decisions.md 2026-06-07).
  - **Schedule-at-start local notification** — `Services/WorkoutNotifications.swift`
    (a foreground countdown is suspended in the background; a scheduled `UNNotification`
    is not). Pure, testable copy builder.
  - **Live Activity** — `Shared/KilterActivityAttributes.swift` +
    `Services/KilterLiveActivityController.swift` + `SnappetWidgets/KilterLiveActivity.swift`;
    a third, separate attributes type keeps the contracts from muddying
    (decisions.md 2026-06-06). `Text(timerInterval:)` / `ProgressView(timerInterval:)`
    tick on the OS wall clock with zero background CPU.
- `SuiteRouter` is still `@State` on `AppLibraryView` (the shell hoist belongs to #71), so
  the in-app "focus running" re-entry chip is scoped to the Apps tab's NavigationStack —
  an overlay visible in the App Library and inside every pushed module except Pomodoro
  itself (visibility flag set by `PomodoroRootView` on appear/disappear).

## Approach

- `PomodoroTimer` gains one seam: `onScheduleChanged: ((PomodoroPhase, Date?) -> Void)?`,
  fired on start (endDate), pause/reset (nil), and phase auto-advance (next endDate).
  `endDate` becomes `private(set)`.
- `AppModel` owns `pomodoro` (the timer), `pomodoroNotifications`, and
  `pomodoroLiveActivity`, wiring the seam in `init`: endDate → request auth (best-effort)
  + schedule the phase-end notification + start/update the Live Activity; nil → clear +
  end. Plus `pomodoroScreenVisible` for the chip.
- New `Services/PomodoroNotifications.swift` (mirrors `WorkoutNotifications`: stable id,
  replace-don't-stack, no-op when unauthorized; pure `phaseEndContent(endedPhase:)`).
- New `Shared/PomodoroActivityAttributes.swift` (ContentState: `isFocus`,
  `phaseStartedAt`, `endDate`) + `Services/PomodoroLiveActivityController.swift`
  (start-or-update / end; no HR throttle needed — updates only on phase edges) +
  `SnappetWidgets/PomodoroLiveActivity.swift` (Lock Screen + Dynamic Island countdown,
  tomato/green phase tint) registered in the bundle.
- `PomodoroRootView` drops its `@State` timer for `app.pomodoro`; existing
  appear-wiring (`onFocusCompleted`, `applyDurations`) stays in the view.
- `AppLibraryView` gains the bottom-overlay chip (phase + ticking remaining + tap →
  `router.push(ModuleRoute(id: "pomodoro"))`).

## Output

- Modified: `PomodoroTimer.swift`, `PomodoroRootView.swift`, `AppModel.swift`,
  `AppLibraryView.swift`, `SnappetWidgetsBundle.swift`.
- New: `Services/PomodoroNotifications.swift`, `Services/PomodoroLiveActivityController.swift`,
  `Shared/PomodoroActivityAttributes.swift`, `SnappetWidgets/PomodoroLiveActivity.swift`.
- Tests: `SnappetTests/PomodoroScheduleTests.swift` (seam fires with the right endDate on
  start, nil on pause/reset; survives applyDurations; notification copy truth table).
  `PomodoroUITests.testTimerSurvivesNavigation` (start → back to grid → reopen → still
  running).
- `docs/knowledge-graph/data.js`: nodes for the two services + widget + chip, wired to
  `m-pomodoro` / `applibrary`.
- `pdd/context/decisions.md` entry.

## Acceptance criteria

- [ ] Navigating away and back resumes the running session with correct remaining time.
- [ ] A scheduled phase-end notification exists from the moment a phase starts; pause and
      reset cancel it (verified by the seam's unit tests + notification copy tests).
- [ ] Live Activity starts/updates/ends with the timer (render is device-pending, like
      Kilter's — state the honesty).
- [ ] The chip appears anywhere in the Apps stack while focus runs (except on the
      Pomodoro screen) and taps back into the module.
- [ ] Timer logic stays pure and unit-tested without a device.
- [ ] App type-checks against the iOS 18 SDK (Swift 6, 0 warnings).

## Constraints

- On-device only; no backend. Lock Screen / Dynamic Island **render** verification needs
  a physical device — do not claim it from a clean build.

## Test plan

1. `xcodegen generate` + full `SnappetTests` on the simulator (new `PomodoroScheduleTests`).
2. `PomodoroUITests` (existing + `testTimerSurvivesNavigation`).
3. Device-pending: lock-screen notification arrival at phase end; Live Activity render.
