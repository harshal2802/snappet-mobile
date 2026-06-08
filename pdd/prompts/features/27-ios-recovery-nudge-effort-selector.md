# Prompt: Live recovery-ready nudge + effort-aligned highlight selector

**File**: pdd/prompts/features/27-ios-recovery-nudge-effort-selector.md
**Created**: 2026-06-08
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Fitness-band richness roadmap → **Phase 4** (the bigger bets; builds on Phases 2 + 3). See
`pdd/prompts/features/fitness-band-richness/ROADMAP.md`.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Two bets that turn the personalized HR data (Phase 2 profile) and HRV (Phase 3) into in-the-moment
and in-the-reel value:

1. **Live "recovery ready" nudge.** While resting between efforts, tell the user when they're rested
   enough for the next burn — the next **climb** (Kilter) / next **set** (WorkoutTracker). Shared
   readiness logic over live bpm vs the profile's rest/max bounds, sharpened by Phase-3 RR-HRV
   rebound. Surfaced on both apps' live HUD pills, their Live Activities, the watch face, and the
   widget.
2. **Effort-aligned highlight selector.** One engine selector that boosts moments inside injected
   achievement windows, via the existing `SceneHighlightSelector.visualScore` pattern: Kilter boosts
   moments inside **sent**-climb windows; WorkoutTracker boosts **peak-effort set** windows. Both
   auto-reels feature the achievement, not just the raw HR peak.

## Context the implementer needs

- **Readiness gating.** Readiness needs the profile's rest + max bounds (Phase 2). No profile → no
  bounds → `.unknown` → the nudge hides, identically in both apps (the parity invariant's symmetric
  degrade). HRV rebound is an optional sharpener, never required.
- **Selector API.** `HighlightSelector.score(at:workout:hr:config:) -> Double` (see
  `HighlightSelector.swift`). The new `EffortAlignedSelector` mirrors `SceneHighlightSelector`: it
  returns a boost when `offset` falls in an injected window, else 0, and composes with HR via the
  existing `FusionSelector`. No protocol change.
- **Two reel paths (must both get the boost):** Kilter builds a reel via `ReelViewModel.generate` →
  `model.engine.generate(for:)` (source `KilterWorkoutBuilder.kilterSession`). WorkoutTracker's
  session reel runs `app.engine.selector.select(...)` directly in `SessionHighlightViewModel`. The
  boost windows are session-relative seconds: Kilter's **sent**-climb windows come from the logs;
  WorkoutTracker's **peak-effort** windows come from `WorkoutHRStats.setEfforts` (sets with a peak),
  each `[completedAt − work, completedAt + hrLagSec]`.
- **Live nudge surfaces already carry HR** the same way: live pills (`LiveHRPill`, `KilterHRPill`),
  `WorkoutLiveSnapshot`/`KilterLiveSnapshot` → Live-Activity `ContentState` (throttled `shouldPush`)
  → widget; the watch via `WorkoutWatchManager`. Readiness rides the same channels (a `Bool`).

## Approach

- **Engine (platform-free):** `RecoveryReadiness` — pure `evaluate(currentBpm:restBpm:maxBpm:
  rrReboundFraction:)` → `{ state: unknown|recovering|ready, fraction }`; `.unknown` without bounds.
  `EffortAlignedSelector` — boosts injected `[ClosedRange<Double>]` windows; a `FusionSelector
  .effortAligned(windows:)` convenience blends it with `HRHighlightSelector`. Both `swift test`'d.
- **Live nudge (shared, gated):** both live pills compute readiness from `app.liveWorkout.latestHR` +
  `app.userProfile.profile` bounds and show a small "Ready" chip (hidden on `.unknown`/`.recovering`).
  `recoveryReady: Bool` threads through `WorkoutLiveSnapshot`/`KilterLiveSnapshot` (counted as a
  structural change in `shouldPush`), the two `ContentState`s, the controllers, the widget renderers,
  and the watch face — mirroring how HR already flows.
- **Reel boosts:** `AppModel.engine(boosting:)` returns an engine whose selector is
  `FusionSelector.effortAligned(windows:)`. Kilter passes sent-climb windows via a new
  `ReelSource.boostWindows`; `ReelViewModel.generate` uses `model.engine(boosting: source.boostWindows)`.
  WorkoutTracker's `SessionHighlightViewModel` computes peak-effort windows and selects with the fused
  selector. Empty windows → today's HR-only behavior (gated).

## Output

- New: `ios/HighlightEngine/Sources/HighlightEngine/RecoveryReadiness.swift`,
  `ios/HighlightEngine/Sources/HighlightEngine/EffortAlignedSelector.swift` (+ engine tests).
- Edits: `WorkoutPlayerView.swift` (LiveHRPill nudge), `KilterHRPill.swift` (+ its call sites),
  `WorkoutLiveSnapshot.swift` / `KilterLiveSnapshot.swift` (+`recoveryReady` + `shouldPush`),
  `WorkoutActivityAttributes.swift` / `KilterActivityAttributes.swift` (+`recoveryReady`),
  `LiveActivityController.swift` / `KilterLiveActivityController.swift` (map it), the snapshot builders
  (`WorkoutPlayerView`/`FreeformPlayerView`/`KilterBoardController`), `WorkoutLiveActivity.swift` /
  `KilterLiveActivity.swift` (render), `WorkoutWatchManager.swift` + `WatchWorkoutView.swift`,
  `AppModel.swift` (`engine(boosting:)`), `ReelViewModel.swift` (+`ReelSource.boostWindows`),
  `KilterWorkoutBuilder.swift` (sent-climb windows), `SessionHighlightViewModel.swift` (peak-effort
  windows + fused selector).
- Tests: `RecoveryReadinessTests`, `EffortAlignedSelectorTests` (engine); app tests for the window
  derivations + the no-profile/no-window gating.

## Acceptance criteria

- [ ] `RecoveryReadiness.evaluate` → `.unknown` without rest+max bounds; `.ready` when current %HRR ≤
      the (HRV-eased) threshold, else `.recovering`; `fraction` is 0…1.
- [ ] `EffortAlignedSelector` boosts only in-window offsets; `FusionSelector.effortAligned` raises an
      in-window score above an out-window one; empty windows ⇒ pure HR behavior.
- [ ] The "Ready" nudge shows on both live pills only when a profile exists and the user is recovered;
      it threads to both Live Activities, the widget, and the watch.
- [ ] Kilter auto-reels boost sent-climb windows; WorkoutTracker auto-reels boost peak-effort windows;
      with no windows / no profile both behave exactly as before.
- [ ] Engine `swift test` passes; app type-checks (Swift 6, 0 warnings) and the XCTest suite passes.
- [ ] No platform imports in `HighlightEngine`. `decisions.md` + knowledge graph updated.

## Constraints

- On-device only; no backend. Keep the engine platform-free and the selector pluggable (the fusion
  pattern — no HR-only hardwiring).
- State verification honestly: the **live** nudge needs a real band/HR (and the Live-Activity/watch/
  widget rendering a device) — unverifiable in the simulator; the readiness math, the selector
  scoring/fusion, and the window derivations are fully unit-tested off-device.

## Test plan

1. `cd ios/HighlightEngine && swift test` (readiness states + selector boost/fusion).
2. `cd ios/App && xcodegen generate && xcodebuild test -scheme Snappet -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`.
3. Device follow-up (real strap + profile): rest after a hard set/climb and confirm the "Ready" nudge
   appears on the pill / Live Activity / watch as HR drops; export a reel and confirm sent-climb /
   peak-effort moments are favored.
