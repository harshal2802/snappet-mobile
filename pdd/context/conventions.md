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

## Experiments (spikes)

- Live in `experiments/<name>/`, **Python stdlib only**, **seeded** so runs are reproducible.
- Each spike ships a `README.md` (what/how to run) and a `RESULTS.md` ending in an explicit
  **GO / NO-GO / NEEDS-REAL-DATA** verdict with honest limitations. The deliverable is a *decision*.

## Git

- **Conventional commits**, scoped: `feat(ios):`, `fix(engine):`, `docs(ios):`, `spike(phase-0a):`,
  `chore:`. Be precise in the body about what was actually verified (type-check vs build vs device run).
- **Branch per phase/feature**: `feat/ios-mvp-highlight-engine`, `spike/hr-highlight-efficacy`.
- One phase = one prompt + one PR. Commit the prompt asset alongside the code it produced.

## PDD

- Every feature/spike traces to a prompt in `pdd/prompts/` and ultimately to the web repo's `#60` /
  `PLAN-snappet-mobile.md`. Record non-obvious decisions in `decisions.md` the same day they're made.
