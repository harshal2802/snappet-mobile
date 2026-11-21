# Prompt: UI tests never touch real data — the test-store guard (prompt 266)

**File**: pdd/prompts/features/266-ios-ui-test-store-guard.md
**Created**: 2026-11-16
**Project type**: Native iOS test infrastructure (Swift / SwiftUI / XCUITest) — code lands in this repo.
**Chain**: incident 2026-11-16 (a UI test tapped Quick Start in the user's real data on their iPhone), after prompt 264.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md` (no change)

## Goal

UI tests are sometimes run on the user's real iPhone. They rely on launch arguments (`-uiTestFreshStore` and the
`-uiTestSeed…` arguments that imply it) for an empty in-memory SwiftData store. On 2026-11-16 the first test launch
after a fresh install attached to an app process iOS had started WITHOUT those arguments, and the test tapped Quick
Start in the user's real data. Nothing was lost, but it must become impossible: no UI test may tap, swipe or type
until it has confirmed the app is on the test store, and link tests (which reach whatever Snappet is installed) never
run on a real device.

## Context the implementer needs

- `ios/App/Snappet/SnappetApp.swift` `init`: the `freshStore` expression ORs `-uiTestFreshStore` with every seed
  argument (`StudioDemoSeed`, `RecapClipSeed`, `RoutineHistorySeed`, `ActivityClipsSeed`, `RacketHRSeed`,
  `RacketVideoSeed`, `FestivalLineupSeed`, `FestivalNightSeed` (implies the lineup), `FestivalPlanSeed`).
- `ios/App/SnappetUITests`: about 123 `app.launch()` sites, including relaunches inside tests and helpers.
- `XCUIDevice.shared.system.open(` in `LiveSessionSafetyUITests.swift` and `WorkoutLinkUITests.swift`.
- The test target can't import the app.

## Approach

1. **App:** a pure `UITestStore.isFreshStore(_ arguments: [String]) -> Bool` (`Snappet/Core/UITestStore.swift`) with
   the argument list; `SnappetApp.init` uses it for `freshStore`, and the `WindowGroup` content gets a 1pt clear
   overlay (`allowsHitTesting(false)`, `.accessibilityElement()`, identifier `uiTest.freshStore`) only when it's true.
   No layout change, no taps, nothing on a normal launch.
2. **Tests:** `SnappetUITests/TestStoreGuard.swift` — `XCUIApplication.launchCheckingTestStore(require:timeout:)`
   (launch; check always on a device, on the simulator when the arguments imply the test store or `require` forces it;
   wait up to 15 s for the marker; missing ⇒ `terminate()` then return the refusal) and the `launchOnTestStore()`
   wrapper that `XCTFail`s "Snappet is not on the test store; refusing to touch real data". A mirrored argument list
   with a comment pointing at `UITestStore`. `TestStoreGuard.skipLinkTestsOnDevice()` throws
   `XCTSkip("link tests are simulator-only")` on a device.
3. Scripted replace of every `app.launch()` with `app.launchOnTestStore()`, reviewed by hand; the link tests call the
   skip helper first (`WorkoutLinkUITests` in setUp, before launching).

## Output

- New: `Snappet/Core/UITestStore.swift`, `SnappetTests/UITestStoreTests.swift`, `SnappetUITests/TestStoreGuard.swift`,
  `SnappetUITests/TestStoreGuardUITests.swift`.
- Changed: `Snappet/SnappetApp.swift`, every `SnappetUITests` file with a launch, `LiveSessionSafetyUITests.swift` and
  `WorkoutLinkUITests.swift` (skip on device).
- Docs: `decisions.md` (incident + rule), `conventions.md` (Testing), `project.md` (the UI-test line).
  `docs/knowledge-graph/data.js` unchanged: no user-visible surface.

## Acceptance criteria

- [ ] `UITestStoreTests`: no arguments ⇒ false; `-uiTestFreshStore` ⇒ true; each seed argument ⇒ true; an unrelated
      `-uiTest…` argument alone (e.g. `-uiTestFakeCamera`) ⇒ false.
- [ ] No `app.launch()` left in `SnappetUITests`; every launch goes through the guard.
- [ ] `TestStoreGuardUITests`: a test-store launch shows the marker (≤ 1pt) and passes; a forced check on a launch
      without a store argument returns the refusal and leaves the app `.notRunning` (simulator only).
- [ ] Link tests skip on a real device; on the simulator they run as before.
- [ ] A normal launch is unchanged (no marker, same store).

## Constraints

Simulator only for verification; never the user's phone. Minimal change: no behaviour change for a normal launch.
Tests that launch without a store argument are refused on a device by design — list them.

## Test plan

1. `SnappetTests` (all), including `UITestStoreTests`.
2. UI on the simulator: `TestStoreGuardUITests`, `HeartRateOwnershipUITests`, `LiveSessionSafetyUITests`,
   `WorkoutLinkUITests`, `RacketVideosUITests`, plus suites on other seeds (`RacketGameHRUITests` on
   `-uiTestSeedRacketHR`, `FestivalUITests` on the festival seeds, `SuiteSmokeTests` with no store argument).
