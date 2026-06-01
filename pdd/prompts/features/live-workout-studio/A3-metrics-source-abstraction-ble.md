# Prompt: A3 — MetricsSource abstraction + BLE heart-rate band

**File**: pdd/prompts/features/live-workout-studio/A3-metrics-source-abstraction-ble.md
**Created**: 2026-06-01
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: `pdd/prompts/features/live-workout-studio/PLAN.md` → Track A → **A3** (depends on A1).
**Source**: GitHub issue [#15](https://github.com/harshal2802/snappet-mobile/issues/15) (initiative umbrella);
RESEARCH.md §3.3.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
(esp. the three 2026-06-01 entries).

## Goal

Generalize the live-metrics layer behind a pluggable **`MetricsSource`** so live HR can come from
**either** the Apple Watch (A1) **or** a generic **BLE heart-rate band** (chest straps / Polar / Garmin /
any device exposing the standard Heart Rate Service), plus band identification + a picker. This is the
RESEARCH.md §3.3 decision: non-Apple bands connect via the BLE Heart Rate Profile (service `0x180D`,
measurement characteristic `0x2A37`) over `CoreBluetooth` — **never** a cloud API (Fitbit/Google ruled out).

## Context the implementer needs

- A1 left `LiveWorkoutService`'s public surface deliberately shaped to become a `MetricsSource` protocol
  with a BLE conformer **without changing call sites** (decisions.md 2026-06-01, A1 doc comment).
- The engine boundary is plain `HRSample` value types; `HighlightEngine` stays platform-free — A3 adds
  **no** engine import (verify with grep).
- Call sites today: `AppModel.liveWorkout` (the property name A2/A4 depend on); `WorkoutTrackerModule`'s
  session lifecycle (`start(for:sport:category:)` / `stop()` / `connectionState`); `WorkoutPlayerView`
  (`latestHR`, `samples`, status text); `WorkoutSettingsView` (where a source picker fits).
- Swift 6 strict concurrency: CoreBluetooth `CBCentralManagerDelegate`/`CBPeripheralDelegate` callbacks
  arrive **off** the main actor; hop to `@MainActor` before mutating observable state (mirror how
  `LiveWorkoutService`'s `WCSessionDelegate` does it).

## Approach

1. **`MetricsSource` protocol** (`Services/`, `@MainActor`, `AnyObject`): `latestHR: Double?`,
   `energy: Double`, `samples: [HRSample]`, a source-agnostic `state: MetricsSourceState`
   (`.unavailable/.idle/.connecting/.connected/.streaming`), `isReachable: Bool`, `displayName: String`,
   `start(for:sport:category:)`, `stop()`. Keep the engine-boundary `HRSample` buffer.
2. **`AppleWatchMetricsSource`**: today's `LiveWorkoutService` logic, conformed with **identical
   behavior** (regression-safe). Rename `isWatchReachable → isReachable`; map `connectionState` onto
   `MetricsSourceState`. (The one call-site change the A1 review flagged.)
3. **`BLEHeartRateMetricsSource`**: a `CoreBluetooth` central — scan for `0x180D` advertisers, expose
   discovered devices, connect a chosen one, subscribe to `0x2A37`, parse the Heart Rate Measurement
   (flags bit 0 = UInt8 vs UInt16 BPM; ignore optional sensor-contact / energy-expended / RR — only BPM
   needed), emit `HRSample`s on the `WorkoutSession.startedAt` timeline. `energy = 0`. **Isolate the
   byte parsing into a pure static func** so it is unit-testable without a device.
4. **`LiveMetricsCoordinator`** (keep the `AppModel.liveWorkout` property NAME): conforms to
   `MetricsSource`, holds an `AppleWatchMetricsSource` + a `BLEHeartRateMetricsSource`, exposes a
   `selectedSource` + the discovered-BLE list, and forwards the protocol surface to the active source.
   Default selection: Apple Watch when paired+app-installed, else a chosen BLE band. `start/stop` drive
   the active source.
5. **Band identification + picker UI**: a "Heart-rate source" sheet from `WorkoutSettingsView` listing
   Apple Watch + scanned BLE devices (name + connect), letting the user pick the active source. Give rows
   `accessibilityIdentifier`s. (A sheet — not a nested `NavigationStack` in the module.)
6. **Info.plist**: add `NSBluetoothAlwaysUsageDescription`.

## Output

- `ios/App/Snappet/Services/MetricsSource.swift` — protocol + `MetricsSourceState`.
- `ios/App/Snappet/Services/AppleWatchMetricsSource.swift` — A1 logic, conformed (renamed from
  `LiveWorkoutService.swift`).
- `ios/App/Snappet/Services/BLEHeartRateMetricsSource.swift` — CoreBluetooth source + pure parser +
  `BLEDevice` value type.
- `ios/App/Snappet/Services/LiveMetricsCoordinator.swift` — coordinator + `MetricsSourceKind` + the pure
  `resolve(selected:watchUsable:hasBLEDevice:)` selection rule.
- `ios/App/Snappet/Features/WorkoutTracker/HeartRateSourcePicker.swift` — the picker sheet.
- Edits: `Core/AppModel.swift` (`liveWorkout` is now the coordinator), `WorkoutPlayerView.swift`
  (`isWatchReachable → isReachable`; source-aware status text), `WorkoutSettingsView.swift` (Live-metrics
  section + sheet), `WorkoutTrackerModule.swift` (comment), app `Info.plist` (`NSBluetoothAlwaysUsageDescription`).
- Tests: `SnappetTests/MetricsSourceTests.swift` (HR-measurement parser + source-selection); the renamed
  type in `SnappetTests/LiveWorkoutTests.swift`.

## Acceptance criteria

- [ ] `MetricsSource` protocol with `AppleWatchMetricsSource` (identical A1 behavior) + `BLEHeartRateMetricsSource` conformers.
- [ ] `LiveMetricsCoordinator` keeps the `AppModel.liveWorkout` name, forwards to the active source, default-selects watch-when-usable else BLE.
- [ ] BLE source scans `0x180D`, subscribes `0x2A37`, parses BPM via a pure static func, `energy = 0`.
- [ ] A "Heart-rate source" picker (Apple Watch + scanned bands) reachable from Settings, rows have accessibility ids.
- [ ] `NSBluetoothAlwaysUsageDescription` added.
- [ ] App + watch build; `SnappetTests` pass (new parser/selection + existing); `HighlightEngine` 18/18.
- [ ] No platform imports added to `HighlightEngine`; the Apple-Watch path stays behavior-equivalent (A1 tests pass).
- [ ] `decisions.md` updated with the non-obvious A3 choices.

## Constraints

- On-device only; **no Fitbit/Google/cloud**. Swift 6 strict concurrency (hop CB delegate callbacks to `@MainActor`).
- Don't nest a `NavigationStack` in the module (the picker is a sheet, which may carry its own).
- Build with `-destination` only, never `-sdk` (it breaks the embedded watch target — decisions.md).
- A clean build is **not** a verified BLE stream: a real connect + HR stream needs a device + a physical band.

## Test plan

1. `cd ios/App && xcodegen generate`.
2. Build the `Snappet` scheme for a booted iPhone 17 Pro sim (`-destination` only) → BUILD SUCCEEDED.
3. Build the `SnappetWatch` scheme (watchOS sim) → confirm A1 still builds.
4. `-only-testing:SnappetTests test` → the new parser/selection tests + existing pass. `cd
   ios/HighlightEngine && swift test` → 18/18 (source unchanged). `WorkoutWalkthroughTests` stays green.
5. Device-pending: a real BLE band connect + live HR stream (`0x180D`/`0x2A37`) — a sim build proves the
   shape + the pure parser only.
