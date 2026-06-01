# Prompt: Pomodoro — session history, stats chart & persisted settings

**File**: pdd/prompts/features/12-ios-pomodoro-history.md
**Created**: 2026-05-31
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: suite feature-completeness pass (P9 follow-up); one of six parallel mini-app increments.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md` (§"Adding a mini-app"), `pdd/context/decisions.md`.

## Goal

Make the Pomodoro mini-app feel complete by surfacing the focus history it already persists, adding a
7-day focus-minutes chart, persisting the user's timer settings across launches, and giving completion
a haptic. Today the app drift-free-times focus/break cycles and writes a `PomodoroSession` per completed
focus block, but the only visible stat is "today", settings reset on relaunch, and there's no feedback
when a phase ends.

## Context the implementer needs

- Folder: `ios/App/Snappet/Features/Pomodoro/` — `PomodoroRootView.swift`, `PomodoroTimer.swift`
  (drift-free engine), plus the inline `PomodoroModule`, `PomodoroSession` `@Model`, and settings.
- `PomodoroSession` (`@Model`) is already registered in `Core/SnappetCore.swift` `SnappetSchema.models`
  and stores `minutes` + `completedAt`. **Do not add a new model** — history reads existing rows.
- The module is pushed into the App Library's `NavigationStack`; do **not** add a nested
  `NavigationStack` (conventions §"Adding a mini-app"). Use `NavigationLink`/`.navigationDestination`
  for the history screen; the settings sheet may carry its own stack.
- Usage is logged via `@Environment(SnappetCore.self)` → `core.log(module: "pomodoro", action: "session", …)`.

## Approach

- **History screen** — new `PomodoroHistoryView.swift`: query `PomodoroSession` sorted by `completedAt`
  desc, grouped by day (`Section` per day with that day's session count + total minutes). Reachable via a
  toolbar/`NavigationLink` ("History") from `PomodoroRootView`.
- **7-day chart** — a Swift Charts `BarMark` of focus-minutes per day for the last 7 days, shown on the
  root (compact) and/or atop history. Aggregate in a small `@MainActor` helper or computed property; no
  business logic in the view body.
- **Persist settings** — back the focus/break-length settings with `@AppStorage` (or persist the existing
  settings object) so they survive relaunch.
- **Haptic** — fire a `UINotificationFeedbackGenerator`/`UIImpactFeedbackGenerator` on phase completion.
- Add `.accessibilityIdentifier(...)` to: Start (`pomodoro.start`), Pause (`pomodoro.pause`),
  Reset (`pomodoro.reset`), settings button (`pomodoro.settings`), history link (`pomodoro.history`),
  and the timer label (`pomodoro.timeRemaining`).

## Output

- New `Features/Pomodoro/PomodoroHistoryView.swift`; edits to `PomodoroRootView.swift` (chart, history
  link, identifiers) and the settings to use `@AppStorage`; haptic on completion. New UI test
  `SnappetUITests/PomodoroUITests.swift`. This prompt asset; a `decisions.md` line if a non-obvious
  choice is made.

## Acceptance criteria

- [ ] Completing a focus block adds a `PomodoroSession`; the History screen shows it grouped under its day.
- [ ] Root shows a 7-day focus-minutes bar chart that updates as sessions are logged.
- [ ] Changing focus/break lengths persists across an app relaunch.
- [ ] A haptic fires when a phase completes.
- [ ] Start/Pause/Reset/settings/history/timer carry stable `accessibilityIdentifier`s.
- [ ] `xcodegen generate` + `xcodebuild build-for-testing` for the iPhone 17 Pro sim → builds clean
      (Swift 6, 0 warnings); `PomodoroUITests` compiles.
- [ ] No nested `NavigationStack`; no platform imports added to `HighlightEngine`.

## Constraints

- On-device only; no new dependencies (Swift Charts is system). Verify honestly: build ≠ device run.

## Test plan

1. `cd ios/App && xcodegen generate && xcodebuild -scheme Snappet -sdk iphonesimulator -destination 'id=F1A2B6B8-C609-47F8-8D55-44D94C5577B4' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build-for-testing` → succeeds.
2. `PomodoroUITests`: open Pomodoro → start a short focus → let it complete → open History → assert a row
   exists; change a setting, relaunch, assert it persisted.
