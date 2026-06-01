# Prompt: A4 — Live metrics overlay UI (HR zone + overall timer + rest timer)

**File**: pdd/prompts/features/live-workout-studio/A4-live-overlay-ui.md
**Created**: 2026-06-01
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: `pdd/prompts/features/live-workout-studio/PLAN.md` → Track A → **A4** (depends on A1, A2; uses A3).
**Source**: GitHub issue [#15](https://github.com/harshal2802/snappet-mobile/issues/15) (initiative umbrella);
RESEARCH.md §3.2 (the "overlay fitness data along with current and overall workout timer" ask).
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
(esp. the three 2026-06-01 A1/A2/A3 entries).

## Goal

Replace A1's temporary debug HR row in the workout player with a polished **live-metrics overlay** that
shows, together: the **live HR** (bpm + zone color/label + source name), the **overall workout timer**
(A2), and — during rest — the **rest countdown**, plus a graceful **"no source connected"** state. This
is the user's "overlay fitness data along with current and overall workout timer".

## Context the implementer needs

- A1 added `WorkoutPlayerView.liveMetricsDebugRow` + `liveStatusText`; A2 added `overallTimerHeader`
  (a self-updating `Text(timerInterval:)` pinned to the top via `.safeAreaInset`) and the rest-timer
  screen. A3 made the player's status text source-aware (`MetricsSourceState` / BLE vs watch wording).
- Live data is read **only** through `app.liveWorkout` (the `LiveMetricsCoordinator`, a `MetricsSource`):
  `latestHR: Double?`, `state`, `isReachable`, `displayName`, `connectionState` (watch shim), `activeKind`.
  Do **not** reach into `watch` / `ble` directly from the view.
- `HighlightEngine` stays platform-free — A4 adds **no** engine import (verify with grep). The overlay
  is pure UI over the `Services` boundary.
- The module rides the App Library's `NavigationStack`; don't nest one. The player already owns a
  `NavigationStack` (pre-existing) — don't add another, and don't regress A2's Live Activity sync.

## Approach (layering: engine platform-free; UI in the feature; pure logic unit-testable)

1. **`HeartRateZone`** (pure value type, `Features/WorkoutTracker/HeartRateZone.swift`): map a bpm to a
   5-zone %-of-max training zone with a `label`, a compact `pillLabel` ("Z3 · Aerobic"), and a SwiftUI
   `Color`, given a configurable `maxHR` (default **190** — the app has no user age / HR profile yet, so
   `220 − age` isn't available; 190 is a reasonable adult ceiling for *relative* color, not a personalized
   prescription). Add a `.none` case for nil / no-data so a missing sample never renders as a fake zone.
   `forBpm(_:maxHR:)` returns `.none` for `nil` / non-positive bpm / non-positive maxHR. Plain value type
   (only `Color` touches SwiftUI) so it's unit-testable in `SnappetTests` with no device.
2. **`liveMetricsOverlay`** in `WorkoutPlayerView`: replace `liveMetricsDebugRow` with a clean HR pill
   (a small `private`/file-private `LiveHRPill` view): ❤️ bpm tinted by the zone color, the zone
   `pillLabel`, and the source `displayName`. Shown on **both** the exercise and rest screens, integrated
   with the existing `overallTimerHeader` (A2) so the user sees overall timer + live HR at a glance, and
   the rest countdown during rest. When `latestHR == nil`, show the source-aware status (reuse
   `liveStatusText` / `MetricsSourceState`). Keep the view thin: the pill is handed an already-computed
   bpm + `HeartRateZone` + names — **no business logic in the view** (the mapping is `HeartRateZone`).
   Give the overlay `accessibilityIdentifier("liveMetricsOverlay")`.
3. Don't regress A2's Live Activity / overall timer; don't nest a `NavigationStack`.

## Hard constraints

- Swift 6 strict concurrency; `@MainActor` UI.
- **NO** platform import added to `ios/HighlightEngine/**` (grep-verify).
- Reads live data only through `app.liveWorkout` — never `watch` / `ble` directly from the view.
- On-device only; no network.

## Tests (SnappetTests, NOT HighlightEngineTests)

- Unit-test `HeartRateZone`: bpm→zone boundaries (at the default 190 max and a custom max), the
  nil/no-data case, labels / `pillLabel`. Pure, no device.
- Keep `SnappetUITests/WorkoutWalkthroughTests` green; add **one** assertion that `liveMetricsOverlay`
  appears in the player. The walkthrough launches `-uiTestFreshStore` with no watch/HR in the sim, so
  assert the overlay renders its **no-source** state — **don't** assert a bpm value.

## Build & verify (precise; don't fake)

- `cd ios/App && xcodegen generate`; build the app:
  `xcodebuild -project ios/App/Snappet.xcodeproj -scheme Snappet -destination 'id=<booted iPhone 17 Pro sim>' CODE_SIGNING_ALLOWED=NO build` (**`-destination` only, never `-sdk`** — `-sdk` breaks the embedded watch target).
- Build the watch scheme (`SnappetWatch`, watchOS 26.5 sim) to confirm nothing broke.
- `-only-testing:SnappetTests test` (HeartRateZone + existing) and `cd ios/HighlightEngine && swift test` (18/18, source unchanged).
- `-only-testing:SnappetUITests/WorkoutWalkthroughTests` (must stay green with the overlay assertion).
- The overlay's *visual* (zone colors, live bpm) needs a device with an HR source; a sim build + the
  no-source state + the pure zone tests prove the **shape**, not a live-HR rendering. State this honestly.

## PDD bookkeeping

Dated `decisions.md` entry (2026-06-01): the zone model + default max-HR choice (and why — no age/HR
profile yet), how the overlay composes overall timer + HR + rest timer, the no-source states, and what's
device-pending. Commit this prompt asset with the code.
