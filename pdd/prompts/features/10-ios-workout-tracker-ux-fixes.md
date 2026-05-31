# Prompt: Workout tracker UX & transition fixes (issue #5)

**File**: pdd/prompts/features/10-ios-workout-tracker-ux-fixes.md
**Created**: 2026-05-31
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: follow-up to `09-ios-workout-tracker.md` (same module, post-ship UX pass).
**Source**: GitHub issue [#5](https://github.com/harshal2802/snappet-mobile/issues/5) (deep UX review of screen transitions).
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md` (§"Adding a mini-app"), `pdd/context/decisions.md`.

## Goal

Fix the broken / disorienting screen transitions and functional gaps found in a deep UX review of the
Workout tracker mini-app (`Features/WorkoutTracker/`). The catalog/routine/session machinery works, but
the *flow between screens* — starting a workout, finishing it, and getting back to a useful place — is
confusing, and a few functional gaps (dead "Start" wiring, empty-session pollution, a drifting rest
timer) undercut the experience.

## Context the implementer needs

- The module is **pushed into the App Library's `NavigationStack`** and must NOT nest its own
  (conventions §"Adding a mini-app"; the 2026-05-31 suite-pivot decision). So no module-owned
  `NavigationStack`/`NavigationPath`. A pushed view *can* pop itself via `@Environment(\.dismiss)`.
- `WorkoutHomeView` (WorkoutTrackerModule.swift) owns the live-player `fullScreenCover` (`$playing`),
  the start-conflict `confirmationDialog` (`$startConflict`), and the section segmented control.
- `Start` is always invoked from a **pushed** `RoutineDetailView` (dashboard quick-start or the
  Routines list), so the player + dialog are presented from an ancestor while a child is on top —
  fragile, and on finish the user lands back on the routine's prescription page.
- The suite tab bar (Home/Apps) stays visible inside the module; `RoutineDetailView`'s bottom
  `.safeAreaInset` "Start Workout" bar stacks on top of it.
- `RoutinesSectionView` is handed a `start: (Routine) -> Void` closure that it never calls.

## Approach

Two focused branches (disjoint files), no module-owned NavigationStack:

**Branch `fix/workout-nav-and-transitions`** (navigation + routines + tab bar):
- `RoutineDetailView`: take `@Environment(\.dismiss)`; the "Start Workout" button pops the detail
  (`dismiss()`) *then* calls `start()`, so the player/dialog present from the home (now top) — fixing
  both the fragile presentation and the post-workout landing. Add `.toolbar(.hidden, for: .tabBar)`.
- `WorkoutTrackerModule.finishWorkout`: on a *saved* finish, switch `section = .dashboard`.
- `RoutinesSectionView`: wire the existing `start` closure — leading swipe + context-menu "Start".

**Branch `fix/workout-player-session`** (live player):
- `WorkoutPlayerView.finish(saved:)`: never persist an empty workout (`completedSetCount == 0` → discard).
- Rest timer driven off a target end `Date` so backgrounding doesn't make it drift.

## Output

- Code edits to `RoutineDetailView.swift`, `WorkoutTrackerModule.swift`, `RoutinesSectionView.swift`
  (branch 1) and `WorkoutPlayerView.swift` (branch 2); this prompt asset + a `decisions.md` entry.

## Acceptance criteria

- [ ] Starting a routine (dashboard quick-start, its detail, or a Routines-list swipe/context "Start")
      presents the player reliably; finishing a saved workout lands on the Dashboard, not the routine page.
- [ ] With an active session, tapping Start on a *different* routine shows the "already in progress" dialog.
- [ ] Routines list has a working "Start" (swipe + context menu).
- [ ] `RoutineDetailView` shows no tab bar under its Start bar.
- [ ] A workout with zero logged sets never appears in History / stats (auto-discarded).
- [ ] The rest timer reflects real elapsed time after backgrounding.
- [ ] App type-checks (Swift 6, 0 warnings) and `xcodebuild` for the iPhone 17 Pro sim → BUILD SUCCEEDED.
- [ ] No module-owned `NavigationStack`; no platform imports added to `HighlightEngine`.

## Constraints

- On-device only; no new dependencies. Respect the no-nested-NavigationStack rule.
- Verify honestly: a type-check / build ≠ a device run of the transition feel.

## Test plan

1. `cd ios/App && xcodegen generate && xcodebuild -scheme Snappet -sdk iphonesimulator -destination 'id=F1A2B6B8-C609-47F8-8D55-44D94C5577B4' CODE_SIGNING_ALLOWED=NO build` → BUILD SUCCEEDED.
2. Sim run: start from each entry point; finish → Dashboard; start a 2nd routine mid-session → conflict
   dialog; end an empty workout → not in History; start a rest, background ~the duration, return → corrected.
