# Prompt: Shared workout stopwatch primitive (count-up / count-down target)

**File**: pdd/prompts/features/62-ios-stopwatch-core.md
**Created**: 2026-06-15
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Workout-with-timer initiative — **PR 1 of 6** (the shared stopwatch that the timed-set PR and the climb-attempt PR both consume). Ideated + architected 2026-06-15 on this branch.
**Source**: In-repo ideation + architecture plan — Gym Tracker "Workout with timer" (timed sets · repeat-set loop · free-flow climb sessions · tracking-type search), 2026-06-15.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Build the one timer primitive the whole "Workout with timer" feature stands on: a reusable,
**wall-clock-backed stopwatch** with a count-up mode (press Start → it runs → press Stop → it hands
back the elapsed seconds) and an optional count-down **target** (arm e.g. 0:45 → it counts down → a
haptic fires at 0). Two upcoming PRs depend on it — timed sets (`SetKind.duration`, PR 2) and per-climb
attempts (PR 5) — so it is built and unit-tested **once, in isolation, with no callers**, to de-risk
both. The hard part is correctness across pause/resume and backgrounding; the app already solves that
twice with a wall-clock pattern, and this PR distills it into a pure core + a thin reusable view.

## Context the implementer needs

- **Two existing timers set the pattern — match them, don't invent.**
  - *Count-up*: `FreeformPlayerView.timerHeader` renders overall elapsed with
    `Text(timerInterval: session.startedAt...Date.distantFuture, countsDown: false)` — it self-updates
    off the system clock with zero background CPU (`FreeformPlayerView.swift:84-95`).
  - *Count-down*: `WorkoutPlayerView`'s rest timer recomputes remaining from
    `restEndDate.timeIntervalSinceNow` on a ~200 ms loop, **re-syncs on `scenePhase == .active`**,
    freezes on pause by dropping the wall-clock anchor, and draws a 220 pt `Circle().trim` arc that
    **snaps instead of animating under `accessibilityReduceMotion`**.
  - The rule both encode and this PR must keep: **the displayed value is always recomputed from `Date`
    — never accumulated from a tick counter** (no drift, survives backgrounding).
- **Reuse the one duration formatter.** `SetMeasure.formatDuration(_:)` already renders seconds as
  `"M:SS"` / `"H:MM:SS"` (`SetMeasure.swift:83`). Use it; do **not** add a second formatter (the
  codebase deliberately funnels every duration string through one place).
- **One device-only line.** `Haptics.success()` is the app's haptic edge (`FreeformPlayerView.swift:204`).
  The only device-dependent behavior here is firing it once when a count-down reaches 0 — keep it at a
  thin edge so the pure core and the tests need no device.
- **No callers, no model change in this PR.** `SetLog.durationSec` already persists captured durations;
  this PR does not touch `WorkoutModels`, any logging flow, `WorkoutPlayerView`, or `FreeformPlayerView`.
  It ships the primitive + its tests + a `#Preview`, verifiable in isolation. PRs 2 and 5 wire it in
  (and add the knowledge-graph caller edges then).

## Approach

1. **Pure timing core — `Features/WorkoutTracker/StopwatchTiming.swift`** (no SwiftUI / SwiftData;
   `Sendable` + `Equatable`; the `SetMeasure` idiom — pure logic at a thin edge, unit-tested without a
   device):
   - `enum StopwatchMode: Equatable, Sendable { case countUp; case countDown(targetSec: TimeInterval) }`.
   - A pure reader — given `(startedAt: Date?, accumulated: TimeInterval, now: Date, mode: StopwatchMode)`
     — returning a `StopwatchReading { elapsed; remaining: TimeInterval?; reachedZero: Bool }` where:
     - `elapsed = max(0, accumulated + (startedAt.map { now.timeIntervalSince($0) } ?? 0))`;
     - `.countUp` → `remaining = nil`, `reachedZero = false`;
     - `.countDown(t)` → `remaining = max(0, t - elapsed)`, `reachedZero = elapsed >= t`.
   - A pause helper `freeze(startedAt:accumulated:now:) -> TimeInterval` returning
     `accumulated + now.timeIntervalSince(startedAt)`, so resume re-anchors with a fresh `startedAt` and
     no time is lost or double-counted (the `WorkoutPlayerView` pause idiom, generalized).
2. **Reusable component — `Features/WorkoutTracker/StopwatchView.swift`** + an
   `@Observable @MainActor StopwatchViewModel` (conventions.md: the VM owns state, the view is thin):
   - VM state: `mode`, `startedAt: Date?`, `accumulatedSec: TimeInterval`, `isRunning`, and a cancellable
     ~200 ms refresh `Task` (digit refresh + the count-down→0 haptic edge **only** — the elapsed value
     always comes from `StopwatchTiming`). API: `start()`, `stop() -> TimeInterval` (returns the captured
     elapsed), `reset()`, `arm(target: TimeInterval?)`.
   - View: count-up = large monospaced-digit `Text` (prefer `Text(timerInterval:countsDown:)` for the
     zero-CPU self-update where the layout allows); count-down = the 220 pt `Circle().trim` arc (mirror
     `WorkoutPlayerView`'s rest screen) + remaining digits, snapping under `accessibilityReduceMotion`.
     A primary **Start ▶ / Stop ■** button tinted `SnappetColor.workout`. Reconcile on
     `scenePhase == .active` by recomputing from `startedAt`; cancel the task on disappear. Fire
     `Haptics.success()` exactly once on the count-down→`reachedZero` transition (guarded so it's inert
     in tests / previews).
   - A `#Preview` driving both modes so the component is verifiable on the simulator with no caller.

## Output

- New: `ios/App/Snappet/Features/WorkoutTracker/StopwatchTiming.swift`,
  `ios/App/Snappet/Features/WorkoutTracker/StopwatchView.swift`.
- Tests: `ios/App/SnappetTests/StopwatchTimingTests.swift` (grouped by `// MARK:`).
- `docs/knowledge-graph/data.js`: add a `model` node `wt-stopwatch-timing` (file `StopwatchTiming.swift`)
  and a `component` node `wt-stopwatch` (file `StopwatchView.swift`) — both `group: "workout-log"`,
  `category: "fitness"`, `platform: "ios"`, tagged pure/tested + reusable; the descs note it has **no
  callers yet** (PRs 2/5 wire the edges). No new `links` this PR.
- `pdd/context/decisions.md`: a 2026-06-15 entry — build the stopwatch as a tested primitive first (two
  consumers), the wall-clock / no-tick-accumulator rule, reuse `SetMeasure.formatDuration`, haptic as the
  only device edge.

## Acceptance criteria

- [ ] `StopwatchTiming` computes `elapsed` correctly across a simulated pause→resume (no time lost or
      double-counted); `.countDown` `remaining` clamps at 0 and `reachedZero` flips exactly once at/under
      the target; `.countUp` has `remaining == nil`.
- [ ] `StopwatchView` renders both modes (a `#Preview` shows count-up + count-down); Start/Stop returns
      the elapsed seconds; the count-down fires one success haptic at 0.
- [ ] The displayed time is recomputed from `Date` and stays accurate across backgrounding
      (`scenePhase` reconcile) — no tick-accumulator anywhere.
- [ ] No caller is wired; `WorkoutModels`/`SetLog`, `WorkoutPlayerView`, and `FreeformPlayerView` are
      untouched.
- [ ] Duration strings reuse `SetMeasure.formatDuration` (no second formatter added).
- [ ] Logic is covered in `SnappetTests` without a simulator; the app type-checks against the iOS 18 SDK
      (Swift 6, 0 warnings); `HighlightEngine` is untouched (no platform imports added).
- [ ] `docs/knowledge-graph/data.js` and `pdd/context/decisions.md` updated in this change.

## Constraints

- On-device only; no backend / network / accounts.
- **Primitive only — no callers this PR.** Do not modify the device-verified `WorkoutPlayerView` or
  `FreeformPlayerView`; PRs 2 and 5 consume the component.
- Truth is recomputed from `Date`; the ~200 ms task drives the digit refresh and the count-down haptic
  only, never the elapsed value.
- Honest verification: a clean type-check ≠ a device run. The orchestrator runs the simulator suite;
  this change ships `xcodegen generate`-verified plus the pure `StopwatchTimingTests`.

## Test plan

1. `cd ios/App && xcodegen generate`, then
   `xcodebuild test -scheme Snappet -only-testing:SnappetTests/StopwatchTimingTests
   -destination 'platform=iOS Simulator,name=iPhone 16 Pro'` (orchestrator).
2. By eye on the sim via the `#Preview`: count-up runs and Stop captures the elapsed; arm a ~3 s target →
   it counts down → haptic + `reachedZero` at 0; background then foreground mid-run → the time stays
   wall-accurate.
