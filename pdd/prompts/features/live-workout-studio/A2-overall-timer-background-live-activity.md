# Prompt: A2 — Overall workout timer + background Live Activity

**File**: pdd/prompts/features/live-workout-studio/A2-overall-timer-background-live-activity.md
**Created**: 2026-06-01
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: `pdd/prompts/features/live-workout-studio/PLAN.md` → Track A → **A2** (depends on A1).
**Source**: GitHub issue [#15](https://github.com/harshal2802/snappet-mobile/issues/15) (initiative umbrella);
RESEARCH.md §3.2.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
(esp. the two 2026-06-01 entries).

## Goal

Give a running WorkoutTracker session (1) an **overall workout timer** and (2) a **Live Activity**
(Lock Screen + Dynamic Island) showing the overall timer + live HR + current exercise, plus correct
**background behavior**. This solves the user's "the routine can't run in the background" + "there is no
overall timer" asks (RESEARCH.md §3.2 #1/#2), and makes live HR visible without the app foregrounded.
The overall timer is correct across backgrounding with **no background CPU** because it is rendered off
the wall clock from `session.startedAt` — the same end-`Date` philosophy the existing rest timer uses.

## Context the implementer needs

- A1 already added a live HR source (`AppModel.liveWorkout: LiveWorkoutService` — `latestHR`, `energy`,
  `connectionState`, `samples`) and the session lifecycle lives in `WorkoutHomeView`
  (`startWorkout`/`replaceActiveAndStart`/`resume`/`finishWorkout`), which already calls
  `app.liveWorkout.start/stop`. The Live Activity lifecycle is **co-located** there.
- `WorkoutSession.startedAt` is the authoritative session start (the rest timer already drives off a
  target end `Date`; `scenePhase`-corrects on foreground).
- `HighlightEngine` stays platform-free — A2 adds **no** engine import.
- The watch target + `Shared/` are wired in `project.yml`; the Widget Extension target is added the same
  way (sources path + embed in the app). `Shared/` is compiled into both producer and renderer so the
  Live Activity contract can't drift (mirrors `LiveWorkoutMessage`).

## Approach

1. **Overall timer (in-player):** add an elapsed-time header to `WorkoutPlayerView` =
   `Text(timerInterval: session.startedAt...distantFuture)` (self-updating, wall-clock-correct across
   backgrounding, no background CPU). Render it alongside the per-set rest timer, clearly labelled
   "Total" vs the rest circle. Give it `accessibilityIdentifier("overallWorkoutTimer")`.
2. **Live Activity (ActivityKit):** new Widget Extension target `SnappetWidgets` (in `project.yml`,
   embedded in the app, iOS 18 deployment). `WorkoutActivityAttributes: ActivityAttributes` in `Shared/`
   with static `routineName` and a `ContentState { startedAt: Date; hrBpm: Int?; exerciseName: String;
   setProgress: String }`. Build the Lock Screen view + Dynamic Island (compact / minimal / expanded)
   showing the overall timer, ❤️ HR (or "—"), and current exercise/set.
3. **`LiveActivityController` service** (`Services/`, guarded `#if canImport(ActivityKit)`):
   `start(routineName:startedAt:…)`, `update(…)` / `update(_ snapshot:)`, `end()`. iOS-only; no-ops where
   ActivityKit/Live Activities are unavailable or unauthorized (`areActivitiesEnabled`). Add
   `NSSupportsLiveActivities = YES` to the app Info.plist.
4. **Wire it up:** start the activity when a session starts/resumes (alongside `app.liveWorkout.start`),
   end it in `finishWorkout` (alongside `stop()`), and update it as HR changes (observe
   `LiveWorkoutService.latestHR`) and as the player advances exercises/sets (player `.onChange`).
   A pure `WorkoutLiveSnapshot` (platform-free) is the single source of truth the player and the
   controller both read, so the mapping is unit-testable without ActivityKit.

## Output

- `ios/App/Shared/WorkoutActivityAttributes.swift` — the shared `ActivityAttributes`/`ContentState`.
- `ios/App/SnappetWidgets/{SnappetWidgetsBundle,WorkoutLiveActivity}.swift` + `Info.plist`.
- `ios/App/Snappet/Services/LiveActivityController.swift` — the ActivityKit driver.
- `ios/App/Snappet/Features/WorkoutTracker/WorkoutLiveSnapshot.swift` — pure snapshot + `elapsedString`.
- Edits: `WorkoutPlayerView.swift` (overall-timer header + Live Activity updates),
  `WorkoutTrackerModule.swift` (start/end activity in the session lifecycle), `Core/AppModel.swift`
  (`liveActivity` instance), `project.yml` (widget target + scheme), app `Info.plist`
  (`NSSupportsLiveActivities`).
- Tests: `SnappetTests/LiveActivityTests.swift` (elapsed formatting + snapshot/`ContentState` mapping);
  one walkthrough assertion for `overallWorkoutTimer`.

## Acceptance criteria

- [ ] The player shows a self-updating overall timer distinct from the rest timer.
- [ ] A Live Activity starts on session start/resume, updates with HR + exercise/set, and ends on finish.
- [ ] The overall timer stays correct across backgrounding with no background CPU (wall-clock `Date`).
- [ ] `LiveActivityController` no-ops where ActivityKit/Live Activities are unavailable/unauthorized.
- [ ] App + watch + `SnappetWidgets` build; `SnappetTests` pass (new + existing 15); `HighlightEngine` 18/18.
- [ ] No platform imports added to `HighlightEngine`.
- [ ] `decisions.md` updated with the non-obvious A2 choices.

## Constraints

- On-device only; no backend/network. Swift 6 strict concurrency (Sendable; `@MainActor` UI/controller).
- Don't nest a `NavigationStack` in the module. No new `@Model` (so `SnappetSchema.models` is unchanged).
- Build with `-destination` only, never `-sdk` (it breaks the embedded watch target — decisions.md).
- State verification honestly: a clean build proves the shape; the Lock Screen / Dynamic Island
  *rendering* needs a device (or careful sim support).

## Test plan

1. `cd ios/App && xcodegen generate` → defines app + watch + **SnappetWidgets** targets.
2. Build the `Snappet` scheme for a booted iPhone 17 Pro sim (`-destination` only) → BUILD SUCCEEDED.
3. Build the `SnappetWatch` scheme (watchOS sim) → confirm A1 still builds.
4. `-only-testing:SnappetTests test` → new A2 tests + the existing 15 pass. `cd ios/HighlightEngine &&
   swift test` → 18/18 (source unchanged).
5. Device-pending: actual Live Activity rendering on the Lock Screen / Dynamic Island.
