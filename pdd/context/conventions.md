# Conventions: Snappet Mobile (iOS)

**Last updated**: 2026-05-30

These describe how the existing code is written — match them in new work. (Detected from the v0.1
codebase, not aspirational.)

## Repo & folder structure

```
ios/
  HighlightEngine/                 SPM package — the pure-Swift algorithm core, ZERO platform deps.
    Sources/HighlightEngine/       Model, HeartRateSeries, HighlightConfig, HighlightSelector,
                                   HighlightEngine (façade), ReelPlan, Feedback.
    Tests/HighlightEngineTests/    XCTest — one file, grouped by `// MARK:` sections.
  App/
    project.yml                    XcodeGen spec → generates Snappet.xcodeproj (don't hand-edit .pbxproj).
    Snappet/
      SnappetApp.swift             @main App + RootView.
      Core/                        AppModel (wiring), FeedbackStore (training-data sink).
      Services/                    HealthKitService, PhotoLibraryService, ReelExporter — platform I/O.
      Features/<Feature>/          One folder per screen: <Feature>View.swift + <Feature>ViewModel.swift.
      Resources/                   Info.plist, entitlements.
android/                           Later phase — Kotlin (Wear OS / Health Connect / Media3).
experiments/<spike-name>/          Throwaway Python spikes (stdlib only, seeded). README.md + RESULTS.md each.
pdd/                               This PDD layer (context, prompts, evals).
```

## The layering rule (most important convention)

**`HighlightEngine` stays platform-free.** No `import HealthKit / AVFoundation / Photos / UIKit /
SwiftUI` in that target — ever. Platform I/O lives in `App/Services/`, which converts platform types
into the engine's plain value types (`Workout`, `HRSample`, `MediaItem`) and back from its outputs
(`Highlight`, `ReelPlan`). This is what keeps the algorithm testable and portable to watchOS/Android.

The engine and services meet in exactly one place — `AppModel` — so swapping the selector (HR →
fusion) or tuning `HighlightConfig` is a one-line change with no UI/pipeline edits.

## Swift language

- **Swift 6, strict concurrency.** Everything that crosses an actor boundary is `Sendable`. UI types
  are `@MainActor`. Services that wrap a documented-thread-safe object (e.g. `HKHealthStore`) use
  `@unchecked Sendable` with a comment justifying why; stateless services are plain `Sendable`.
- Engine types are **value types** (`struct`/`enum`), `Sendable`, and `Equatable`; the persisted ones
  (`Activity`, `Highlight.Kind`, `HighlightFeedbackEvent`) are `Codable`.
- Prefer `async`/`await`; bridge legacy callback APIs (HealthKit, PhotoKit) with
  `withCheckedThrowingContinuation`. Wrap a non-`Sendable` value crossing a continuation in a small
  `Box<T>: @unchecked Sendable` used exactly once.
- Errors are typed `LocalizedError` enums with user-facing `errorDescription` (e.g. `HealthError`,
  `PhotoError`, `ExportError`).
- Keep public API documented with `///`; explain *why* (cite `#60 §x` where a decision traces to the research).

## SwiftUI

- State: `@Observable` final classes for view models and app state; injected via
  `.environment(model)` and read with `@Environment(AppModel.self)`. No external state library.
- View models are `@MainActor`, own a `State` enum (`loading/ready/empty/error/exporting/exported`),
  and the view `switch`es over it. Empty/error states use `ContentUnavailableView`.
- Views are thin: a `body` that switches on state + a computed `content`/`list`; pull row views into
  small `private struct`s. No business logic in views — it lives in the view model / engine.
- Bridge UIKit only when SwiftUI lacks it (e.g. `ShareSheet: UIViewControllerRepresentable`).

## Naming

- **Files**: match the primary type (`ReelViewModel.swift`, `HealthKitService.swift`).
- **Types**: PascalCase, no prefix (`HighlightEngine`, `WorkoutSummary`). **Methods/properties**: camelCase.
- **Enum cases**: lowerCamelCase (`.climbing`, `.exported(URL)`).
- **Tunables**: live in `HighlightConfig`, named by unit (`smoothingWindowSec`, `clipLeadSec`).

## Testing

- Engine logic is tested in `HighlightEngineTests` with XCTest; group by `// MARK:`. Build synthetic
  workouts in helpers (e.g. a Gaussian HR surge) and assert on selection/padding/NMS/fusion/feedback.
- The engine must stay test-runnable with `swift test` (no device, no simulator). Don't add a
  dependency that breaks that.
- Services + UI need a device/simulator to *run*; a clean type-check is necessary but **not**
  sufficient — never report a device-only feature as "verified" from a type-check alone.
- **UI tests launch with `app.launchOnTestStore()`, never `app.launch()`** (`SnappetUITests/TestStoreGuard.swift`,
  prompt 266). It waits for the app's invisible `uiTest.freshStore` marker before the first tap (always on a real
  device; on the simulator when the launch arguments ask for the test store) and terminates the app and fails if it is
  missing. A new test-store argument goes in `UITestStore.freshStoreArguments` (`Snappet/Core/UITestStore.swift`) AND
  the mirrored list in `TestStoreGuard`. Tests that open links with `XCUIDevice.shared.system.open` call
  `try TestStoreGuard.skipLinkTestsOnDevice()` first: link tests are simulator-only.
- **UI tests have no `async` hooks or tests** (prompt 267): use `setUpWithError` / `tearDownWithError` and
  `wait(for:)`. A failure under `continueAfterFailure = false` in an async `setUp` / `tearDown` / test makes the
  runner exit, and xcodebuild resumes at the next test without retrying it. `scripts/ci-ui-shard.py --check` fails on one.
- **UI tests wait on conditions, not on time.** On the CI runner one XCUITest step takes 1–4 s, so don't read or tap
  something that hides by itself (player controls, camera overlays, toasts) in separate steps that must fit inside its
  timer: read from one `snapshot()`, or check the lasting effect. When a test must *tap* a control on a short timer
  (a single tap step can outlast it), give the app a UI-test-only launch argument that lengthens the timer, gated on
  `UITestStore.isFreshStore` so a real launch never sees it, and keep one focused test on the real timer that taps
  nothing on it. The racket player's controls: `-uiTestPlayerControlsHideAfter <seconds>`
  (`RacketPlayerControls.hideAfterArguments`, 60 s); every suite that taps them while playing launches with it, and
  `RacketPlayerUITests.testControlsHideByThemselvesWhilePlaying` keeps the real 3 s. `SnappetUITests/UITestTaps.swift`
  has `tap(_:until:)`, `startQuickSession()`, `scrollIntoView(_:)`; `SnappetUITests/RacketPlayerControls.swift` drives
  the racket player's controls (use it, don't copy it).
- **CI runs UI tests by area** (prompt 268): a PR runs the UI classes of the areas it touches plus a smoke set;
  the full suite runs nightly, on dispatch, on a ci.yml / `scripts/ci-ui-shard.py` change, or with the `full-ui`
  label (`ui-quick`: smoke only). The area map is `AREAS` in `scripts/ci-ui-shard.py`: a **new UI test class must
  match an area's class pattern** (or the smoke set), or `--check` fails; a new feature folder gets an area. Name UI
  test classes after their area (`Racket…`, `Kilter…`) so the existing patterns pick them up. Preview a change's
  legs with `git diff --name-only origin/main...HEAD | python3 scripts/ci-ui-shard.py --select -`; run chosen
  classes on CI with a manual dispatch's `ui_classes`.

## Experiments (spikes)

- Live in `experiments/<name>/`, **Python stdlib only**, **seeded** so runs are reproducible.
- Each spike ships a `README.md` (what/how to run) and a `RESULTS.md` ending in an explicit
  **GO / NO-GO / NEEDS-REAL-DATA** verdict with honest limitations. The deliverable is a *decision*.

## Git

- **Conventional commits**, scoped: `feat(ios):`, `fix(engine):`, `docs(ios):`, `spike(phase-0a):`,
  `chore:`. Be precise in the body about what was actually verified (type-check vs build vs device run).
- **Branch per phase/feature**: `feat/ios-mvp-highlight-engine`, `spike/hr-highlight-efficacy`.
- One phase = one prompt + one PR. Commit the prompt asset alongside the code it produced.

## Adding a mini-app to the suite

Each mini-app is a self-contained `Features/<App>/` folder. To add one:
1. Build your screens in `Features/<App>/`. The root view is **pushed into the App Library's
   `NavigationStack`** — do **not** wrap it in your own `NavigationStack` (set `.navigationTitle`;
   use `NavigationLink`/`.navigationDestination` for deeper screens). Sheets may carry their own stack.
2. Vend a descriptor: `enum <App>Module { @MainActor static var module: AppModule { AppModule(id:…,
   title:…, subtitle:…, systemImage:…, tint:…, category: .fitness/.productivity/.finance) { <App>RootView() } } }`.
3. Log usage so the Home dashboard tracks it: `@Environment(SnappetCore.self) private var core` →
   `core.log(module: "<id>", action:, summary:, metric:)` on meaningful actions. (Module open is logged
   centrally by the App Library.)
4. Persistence = **SwiftData**. Define `@Model` types in your folder (globally-unique names; key
   relations by `UUID` foreign key for clean per-parent `#Predicate` queries). Trivial state → `@AppStorage`.
5. **Two central edits to wire it in:** append `<App>Module.module` to `ModuleRegistry.all` and your
   `@Model` types to `SnappetSchema.models` (both in `Core/`). Then `xcodegen generate` & build.
- **Studio golden frames** (prompt 304): **a change to how a Studio frame looks must change a golden image in
  the same PR, and the prompt must say why.** `SnappetTests/StudioGoldenFrameTests` renders each
  `StudioGoldenScene` through the export (a real file) and through the preview's video composition and compares
  the listed frames with the PNGs in `ios/App/SnappetTests/GoldenFrames/`. A golden image that changed with no
  reason in the prompt is a review finding; so is a rendering change with no golden image changed.
  - New rendering gets a scene (or a frame in one) in `StudioGoldenScenes.swift` and a test in that class. The
    placeholder tests there (`XCTSkip`) are for what the compositor does not draw yet.
  - The source videos are **not** in the repo. `StudioGoldenRenderer.makeFixture` writes them from
    `StudioGoldenPattern`; do not commit a video for a golden test.
  - **To record**: `touch ios/App/SnappetTests/GoldenFrames/.record`, run
    `-only-testing:SnappetTests/StudioGoldenFrameTests`, delete the file, run again. With the file there every
    scene's export frames are written as the new images and `testRecordModeIsOff` fails, so a recording run is
    never green. It is a file, not an environment variable, because `xcodebuild` does not pass the shell's
    environment to a hosted unit test. `.record` is git-ignored. Look at each changed PNG before committing it.
  - The tolerances are in `StudioSelfCheck.tolerance(for:on:)`. Do not loosen one to make a test pass; find out
    what moved.
  - A Debug build copies the images into the app (`project.yml`, "Copy Studio golden frames") for the
    Settings → Developer → **Studio render check** screen, which runs the same check on a phone.

## Keep the knowledge graph current

The interactive app map (`docs/knowledge-graph/`) is rendered entirely from `data.js`. **Any change
that affects the user experience** — a new screen/sheet/cover, service, watch surface, widget, a
navigation/data-flow edge, or a meaningful behavior change to an existing node — must update
`data.js` (add/edit the `nodes` entry + wire a `links` edge) **in the same change**. Treat it like
docs that must not drift from the code; shared value/wire types in `Shared/` get a node too so the
phone ↔ watch ↔ widget reuse is visible.

## PDD

- Every feature/spike traces to a prompt in `pdd/prompts/` and ultimately to the web repo's `#60` /
  `PLAN-snappet-mobile.md`. Record non-obvious decisions in `decisions.md` the same day they're made.
