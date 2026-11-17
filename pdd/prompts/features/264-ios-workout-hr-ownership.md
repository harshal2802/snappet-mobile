# Prompt: Heart-rate source ownership — Watch end, Kilter, mid-session switch (prompt 264)

**File**: pdd/prompts/features/264-ios-workout-hr-ownership.md
**Created**: 2026-11-16
**Project type**: Native iOS + watchOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: the Workout Tracker state-machine review (findings F6, F7, F8), after prompt 263.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md` (no new field, no new raw value; one new wire kind in `Shared/`)

## Goal

The review found three ways the one live heart-rate source (`LiveMetricsCoordinator`) ends up owned by the wrong
session, or by nobody, without the user knowing. The user's decisions are final:

- **F6** Ending the workout on the Watch never reaches the phone: the phone keeps showing a frozen bpm and records no
  more heart rate. Decision: the phone **keeps its session running** (never auto-finish or delete anything) and the live
  player shows a clear, dismissible "Watch ended" state with a way to carry on.
- **F7** Starting a gym session while a Kilter board session owns the source takes it over (clears its buffer, and
  ending Kilter later steals the gym's samples and stops the Watch). Decision: **refuse** the gym start while a Kilter
  session is live, with a plain message; nothing about the board session changes.
- **F8** Switching the source in Settings mid-session points the session at a source that was never started (every
  sample at t = 0). Decision: **disable** the switch while any session is live, with a line saying why.

## Context the implementer needs

- Wire: `Shared/LiveWorkoutMessage.swift` (phone ↔ watch). Watch: `WorkoutWatchManager` (`end()`), `WatchConnectivityLink`,
  `WatchWorkoutView` (End button). Phone: `AppleWatchMetricsSource` (ignored `.stop` from the watch), `LiveMetricsCoordinator`.
- Gym start paths: `WorkoutTrackerModule.swift` — `startWorkout(from:)`, `startFreeform`, `startPlannedSession`,
  `replaceActiveAndStart`, `startQuickLog` (new-session branch). `resume` is not a start.
- Kilter: `KilterSessionManager` (`KilterBoardController.swift`) — `current`, `recover` (`KilterSessionRecovery.plan`).
- Settings picker: `HeartRateSourcePicker.swift` (Watch row, band rows, "Prefer band", Forget swipe all change the
  active source).

## Approach

One pure file `HeartRateOwnership.swift` (no SwiftUI / UIKit / HealthKit), styled like `LiveSessionSafety.swift`:

| Rule | Function | Used by |
|---|---|---|
| Take a Watch "ended" only for the session being recorded (late queued copy from an earlier session dropped) (F6) | `WatchEnded.accepts` | `AppleWatchMetricsSource.watchEnded` |
| What the player shows: none / notice / chip (after Keep going) (F6) | `WatchEnded.display` | `LiveMetricsCoordinator.watchEndedDisplay`, player |
| Refuse a new gym session while a board session is live (F7) | `GymStartGate.refusal` | gym start paths |
| Lock the source while any session is live (F8) | `HRSourceLock.reason` | `HeartRateSourcePicker` |

- New wire kind `ended(startedAt:)` (watch → phone). The Watch sends it on End from the wrist (`endFromWrist`) and when
  its session fails; a phone-initiated stop sends nothing back. An older phone ignores the kind.
- The phone: clears `latestHR` (banner / Live Activity / player lose the frozen bpm), keeps the HR buffer (finish flush),
  keeps `isSessionActive` and its paused state, drops the Watch out of `workoutRunning`. A sample queued before the end
  that lands after it is buffered but not shown as live.
- `KilterSessionManager.isLive(in:)`: in-memory session, or an open one recovery would adopt (read-only).
- UI hook `-uiTestWatchEnded`: plays the Watch's part through the real decode/handle path (one 128 bpm sample, then the
  `.ended` payload).

## Output

- `ios/App/Snappet/Features/WorkoutTracker/HeartRateOwnership.swift` (pure).
- Changes: `Shared/LiveWorkoutMessage.swift`, `SnappetWatch/WorkoutWatchManager.swift`, `WatchConnectivityLink.swift`,
  `WatchWorkoutView.swift`, `Services/AppleWatchMetricsSource.swift`, `Services/LiveMetricsCoordinator.swift`,
  `FreeformPlayerView.swift`, `WorkoutTrackerModule.swift`, `HeartRateSourcePicker.swift`, `KilterBoardController.swift`.
- Unit: `SnappetTests/HeartRateOwnershipTests.swift`. UI: `SnappetUITests/HeartRateOwnershipUITests.swift`.

## Acceptance criteria

- [ ] End on the Watch reaches the phone; the phone session keeps running; the player shows "Watch ended" with "Keep
      going", then a small chip; no stale bpm anywhere; nothing is finished or deleted.
- [ ] Quick Start / a routine's Start Workout / planned start / Log it now / Discard & start new while a Kilter session is
      live show "A board session is running" and start nothing; the board session stays live; after ending it the start works.
- [ ] The HR source picker's rows, band preference and Forget are disabled while a gym, board or metrics session is
      live, with "You can't change the heart-rate source while a session is live. Finish the session first, then switch."
- [ ] `decisions.md`, `project.md`, `docs/knowledge-graph/data.js` updated.

## Constraints

Simulator only for tests; a real Watch is device-pending. Plain wording, no em dashes in UI strings; existing ids and
tests keep working. `HighlightEngine` untouched.

## Test plan

1. `SnappetTests` (all), including `HeartRateOwnershipTests` and the Watch relay tests (`LiveWorkoutTests`,
   `WatchWorkoutRelayStateTests`, `MetricsSourceTests`).
2. `HeartRateOwnershipUITests`, plus `WorkoutWalkthroughTests`, `WorkoutLinkUITests`, `WorkoutPauseBackgroundTests`,
   `LiveSessionSafetyUITests`, the Kilter session suites and the Settings suites.
3. `SnappetWatch` scheme builds.
