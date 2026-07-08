# Prompt: Bug-hunt Wave 1 — frozen-timer / stuck-paused display family

**File**: pdd/prompts/features/111-ios-bughunt-wave1-frozen-timers.md
**Created**: 2026-07-07
**Project type**: Native iOS fix (Swift / SwiftUI) — code lands in this repo.
**Chain**: Wave 1 of the 2026-07-07 whole-repo bug hunt (issues #271–#274); same defect family
as prompt 110's rest-ticker freeze, now closed at its two remaining hosts.
**Source**: proactive bug hunt (GitHub issue #271)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Fix the two remaining "display clock stops and never restarts" defects: (F1) the timed-effort
FOCUS covers freeze their hero timer after the in-app camera closes, and (F5) a Recap story stays
paused forever after sharing a scene. One PR — one shared root cause: a paused/torn-down display
clock with no resume on the return path.

## Context the implementer needs

- **F1 (covers)**: `RecordClipButton` presents `VideoRecorder` via `.fullScreenCover`
  (RecordClipButton.swift:74). Presenting it removes the host cover from the hierarchy →
  `TimedSetCover`/`TimedAttemptCover`'s `.onDisappear` runs `vm.endTicking()` (correct — no
  refresh task behind other screens). On camera dismissal `.onAppear` re-fires, but its
  `vm.start()` no-ops (`StopwatchViewModel.start` guards `!isRunning`, and the run survived), so
  the ~200 ms ticker never restarts: `vm.now` stops updating and the hero digits freeze at the
  moment the camera opened. The wall-clock capture stays correct — STOP logs the true duration,
  which then *disagrees* with the frozen display the user just watched. `resumeTicking()` (prompt
  110) exists precisely for this and is already unit-friendly; the covers simply don't call it.
- **F5 (story)**: `RecapStoryView`'s "Share scene" calls `playback.pause()` then presents the
  ShareComposer sheet. Nothing resumes: hold-to-pause's `onPressingChanged(false)` fired before
  the sheet came up, and `StoryPlayback.next()/back()` didn't clear `isPaused` — so after the
  share sheet closes, auto-advance and the progress bar are dead for the rest of the story
  (taps still switch scenes, each sitting frozen).

## Approach

- Covers: `vm.resumeTicking()` in `.onAppear` right after `vm.start()` — a no-op on first
  appearance (start already runs the ticker) and the restart on re-appearance. Display-only; run
  state untouched.
- Story: `.sheet(item:onDismiss:)` → `playback.resume()`, and make `next()`/`back()` clear
  `isPaused` in the pure type (deliberate navigation is an implicit resume) so any future pause
  caller degrades gracefully too.
- Testability: expose `StopwatchViewModel.isTicking` (`ticker != nil`) so the
  run-survives / ticker-dead / resume contract is pinned without sleeping on real ticks.

## Output

- `ios/App/Snappet/Features/WorkoutTracker/TimedSetCover.swift` — onAppear `resumeTicking()`
- `ios/App/Snappet/Features/WorkoutTracker/TimedAttemptCover.swift` — onAppear `resumeTicking()`
- `ios/App/Snappet/Features/WorkoutTracker/StopwatchView.swift` — `isTicking` test seam
- `ios/App/Snappet/Features/Feed/StoryPlayback.swift` — next/back clear `isPaused`
- `ios/App/Snappet/Features/Feed/RecapStoryView.swift` — share-sheet `onDismiss` resume
- `ios/App/SnappetTests/StopwatchViewModelTests.swift` — new ticker-contract tests
- `ios/App/SnappetTests/StoryPlaybackTests.swift` — navigation-clears-pause test

## Acceptance criteria

- [ ] Time a set/attempt → Record a clip → return: the hero timer digits keep counting (device —
      the Simulator has no camera; on the sim, any fullScreenCover over the covers exercises the
      same onDisappear/onAppear path).
- [ ] Open a Wrapped story → Share scene → dismiss the sheet: auto-advance resumes; tapping
      next/back on a paused story also resumes.
- [ ] `StopwatchViewModelTests` pin: endTicking keeps `isRunning`; `start()` alone does NOT
      restart the ticker; `resumeTicking()` does; resume is a no-op when not running / already
      ticking.
- [ ] App type-checks (Swift 6, 0 new warnings); full `SnappetTests` unit suite green.
- [ ] `decisions.md` + knowledge-graph node descriptions updated.

## Constraints

- Display-only fixes: never touch `startedAt`/`accumulated` (the wall-clock capture is already
  correct) or `StoryPlayback`'s index/elapsed semantics.
- UI-suite policy: logic-scale change → gate on the unit suite + build; no new XCUITests (the
  camera leg is device-only regardless).

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'` — full unit suite incl. the two new/extended
   test files.
2. Device check (owed): the real camera round-trip on MrRobot next time it's connected.
