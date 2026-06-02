# Prompt: enriched post-workout summary (HR chart + band stats + media gallery)

**File**: pdd/prompts/features/live-workout-studio/B2-enriched-summary.md
**Created**: 2026-06-01
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: `live-workout-studio/PLAN.md` → Track B → **B2** (depends on B1 tagged media + A1's live HR).
**Source**: GitHub issue [#15](https://github.com/harshal2802/snappet-mobile/issues/15); `RESEARCH.md` §3.4.
**Context**: `pdd/context/project.md`, `conventions.md`, `decisions.md` (the 2026-06-01 A1–A4 + B1
entries, AND the 2026-05-31 Journal-`tags` entry — the additive-SwiftData-property precedent).

## Goal

Turn the post-workout `SessionDetailView` into a rich summary — the **live HR series chart** + **detailed
band stats** (avg/max HR, time-in-zone) sitting above the **tagged-media gallery** (B1, already there) —
so a finished workout shows the user's "detailed fitness band data along with tagged videos".

## Context the implementer needs

- The live HR is buffered in `LiveMetricsCoordinator.samples` (`[HRSample]`, engine value type, `t`
  already rebased onto the `WorkoutSession.startedAt` timeline by A1) but **never persisted**.
- `WorkoutSession` (`Features/WorkoutTracker/WorkoutModels.swift`) stores `exercises` as a Codable
  composite — the same shape an additive HR series uses. The Journal `tags: [String] = []` precedent
  (decisions.md 2026-05-31) shows an additive Codable property with a default triggers SwiftData's
  **lightweight migration** with `SnappetSchema.models` UNCHANGED.
- `finishWorkout(_:saved:)` in `WorkoutTrackerModule.swift` is where the watch session stops; flush the
  HR buffer here on a saved finish, before `stop()` (which stops both sources).
- `HeartRateZone.forBpm(_:maxHR:)` (A4) is the pure bpm→zone mapping — reuse for time-in-zone.
- `HighlightEngine.HeartRateSeries.make(...)` resamples+smooths a `[HRSample]` — reuse for a clean chart
  line; do NOT modify the engine (it stays platform-free — grep-verify).
- Swift Charts is already used in the suite (`ExerciseProgressView`, `WorkoutDashboardSection`).

## Approach

Layering: `HighlightEngine` stays platform-free; persistence is an **additive** SwiftData property; UI in
the feature, thin (subviews in small `private struct`s).

1. **Persist the session HR series**: add `var hrSeries: [HRPoint] = []` to `WorkoutSession`, where
   `HRPoint { t: Double; bpm: Double }` is a small `Codable`/`Sendable` value type stored as a composite
   (like `exercises`) — **NOT** a new `@Model`. This is the additive lightweight migration (Journal-`tags`
   precedent); `SnappetSchema.models` is unchanged. In `finishWorkout`, on a **saved** finish and before
   `stop()`, map `app.liveWorkout.samples` (`HRSample`) → `[HRPoint]` and assign to `session.hrSeries`.
   Empty when there was no live source (degrade gracefully — discards keep no series).
2. **HR chart + stats in `SessionDetailView`** (only when `hrSeries` is non-empty): a Swift Charts line
   of bpm over session time (feed the points through `HeartRateSeries` to resample/smooth, render the
   smoothed series); a stats row — **avg / max / min HR**; and **time-in-zone** (reuse
   `HeartRateZone.forBpm`, summing per-sample dwell time per zone) as a small zone bar + legend. Put a
   pure, testable helper (`WorkoutHRStats`: avg/max/min + per-zone seconds + the `HRSample → HRPoint` map)
   in the feature so it's unit-tested without a device. Keep the view thin; the B1 gallery stays below.
3. Per-exercise HR overlay is OPTIONAL — only if cheap; don't block the core chart+stats+gallery on it.

## Hard constraints

- Swift 6 strict concurrency; `@MainActor` UI. No nested `NavigationStack`.
- NO platform import added to `ios/HighlightEngine/**`; do NOT modify the engine — only CALL it.
- Additive SwiftData property only (lightweight migration; no versioned plan; models list unchanged).
- On-device only.

## Tests (SnappetTests, NOT HighlightEngineTests)

Unit-test the pure `WorkoutHRStats` helper: avg/max/min over a synthetic series; time-in-zone bucketing;
the empty series → no stats; the single-sample series; and the `HRSample → HRPoint` flush mapping. Keep
`SnappetUITests/WorkoutWalkthroughTests` green (the walkthrough finishes a session with NO live HR on the
sim, so the chart section must hide cleanly and not break the flow). Walkthrough uses `-uiTestFreshStore`.

## Build & verify

- `cd ios/App && xcodegen generate`; build the `Snappet` iOS scheme (`-destination` only, never `-sdk`)
  + the `SnappetWatch` watchOS scheme.
- `-only-testing:SnappetTests test` (new stats tests + existing); `cd ios/HighlightEngine && swift test`
  (18/18, source unchanged); `-only-testing:SnappetUITests/WorkoutWalkthroughTests` (stays green).
- The chart's *visual* + real HR need a device with a live source; the sim finishes with an empty
  `hrSeries`, so the chart hides. Verify with a SYNTHETIC series in unit tests. State honestly what's
  verified vs device-pending.

## PDD bookkeeping

Dated `decisions.md` (2026-06-01): the additive `hrSeries`/`HRPoint` + lightweight migration (cite the
Journal-`tags` precedent), the flush point in `finishWorkout`, reuse of `HeartRateSeries`/`HeartRateZone`,
and what's device-pending.
