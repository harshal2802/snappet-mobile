# Contributing to Snappet Mobile

Thanks for contributing! This guide covers how the codebase is structured, the conventions to match,
and the workflow for getting a change merged. It distills the canonical references — keep those open
while you work:

- [`pdd/context/project.md`](pdd/context/project.md) — what we're building + the reality-based current state. **Start here.**
- [`pdd/context/conventions.md`](pdd/context/conventions.md) — how the Swift/SwiftUI (and Kotlin) code is written.
- [`pdd/context/decisions.md`](pdd/context/decisions.md) — non-obvious choices already baked in; don't re-litigate them.
- [`pdd/README.md`](pdd/README.md) — the Prompt-Driven Development workflow this repo follows.

## Ground rules (non-negotiable)

These come straight from the product constraints — a change that violates one of these won't be merged:

1. **On-device only.** No backend, no network sync, no accounts, no analytics, no third-party tracking
   SDKs. Health and media data never leave the device.
2. **`HighlightEngine` stays platform-free.** No `import HealthKit / AVFoundation / Photos / UIKit /
   SwiftUI` in that target — *ever*. Platform I/O lives in `ios/App/Snappet/Services/` and converts
   platform types into the engine's plain value types and back. This is what keeps the algorithm
   testable and portable to watchOS/Android.
3. **Keep the selector pluggable.** Don't hardwire HR-only selection — the engine predicts a fusion
   (HR + content + manual pins) will win. The algorithm is swappable/tunable in exactly one place
   (`AppModel.engine`, `HighlightConfig`).
4. **Don't tune from intuition.** Don't change `HighlightConfig` knobs or selector weights without
   either a spike result or replayed feedback data behind it — and record the *why* in `decisions.md`.
5. **No feature creep** beyond the flagship flow until it ships.
6. **Never report a device-only feature as "verified" from a type-check or simulator build alone.**
   HealthKit, Photos, and AVFoundation behavior must be confirmed on a real device.

## Development workflow (PDD)

This repo uses **Prompt-Driven Development**: features and spikes are specified as committed prompts,
and the AI-generated output is reviewed before it lands. The prompt is part of the codebase.

1. **Context** — make sure [`pdd/context/`](pdd/context/) still reflects reality; stale context
   misleads every future change.
2. **Plan** — find or add the relevant prompt under
   [`pdd/prompts/features/`](pdd/prompts/features/). The roadmap is
   [`PLAN-ios-to-shippable.md`](pdd/prompts/features/PLAN-ios-to-shippable.md).
3. **Prompt** — copy [`pdd/prompts/templates/feature-prompt.md`](pdd/prompts/templates/feature-prompt.md),
   fill it in, and commit it.
4. **Implement & review** the output. Engine changes must pass `swift test`.
5. **Record** any non-obvious decision in `decisions.md` the same day you make it.

**One prompt = one job = one PR.** Commit the prompt asset alongside the code it produced.

## Building, running, and testing

See the [Getting started](README.md#getting-started) section of the README for the full commands.
At minimum, before opening a PR:

| Change touches… | Must pass |
|---|---|
| `HighlightEngine` | `cd ios/HighlightEngine && swift test` (no device/simulator needed) |
| iOS app / services / UI | A clean `xcodebuild` for the simulator **and**, for any module change, its `SnappetUITests/<App>UITests.swift` |
| Android app | `./gradlew :app:assembleDebug` **and** `./gradlew :app:connectedDebugAndroidTest` |
| A Phase-0 experiment | The spike runs seeded/reproducibly and `RESULTS.md` ends in a GO / NO-GO / NEEDS-REAL-DATA verdict |

Device-only flows (the flagship Workout Reels pipeline, watchOS live HR) can't be auto-verified in CI
or the simulator — follow [`ios/App/RUNBOOK-device.md`](ios/App/RUNBOOK-device.md) and say in your PR
exactly what was verified (type-check vs. build vs. real-device run).

## Coding conventions

The full set lives in [`pdd/context/conventions.md`](pdd/context/conventions.md). The highlights:

### Swift / SwiftUI (iOS)

- **Swift 6, strict concurrency.** Everything crossing an actor boundary is `Sendable`; UI types are
  `@MainActor`. Justify any `@unchecked Sendable` with a comment.
- Engine types are **value types** (`struct`/`enum`), `Sendable`, `Equatable`; persisted ones are `Codable`.
- Prefer `async`/`await`; bridge callback APIs (HealthKit, PhotoKit) with `withCheckedThrowingContinuation`.
- Errors are typed `LocalizedError` enums with user-facing `errorDescription`.
- State via `@Observable` final classes injected with `.environment(_:)`; **no external state library**.
  View models are `@MainActor`, own a `State` enum, and the view `switch`es over it. **Views stay thin**
  — no business logic in views.
- **Naming:** files match the primary type; types are PascalCase with no prefix; tunables live in
  `HighlightConfig`, named by unit (`smoothingWindowSec`).

### Kotlin / Compose (Android)

The Android app mirrors iOS feature-for-feature: Jetpack Compose + Material 3 (≈ SwiftUI), Room
(≈ SwiftData), `core/ModuleRegistry` + `core/SnappetCore` (≈ the iOS equivalents). Match the existing
patterns in `android/app/src/main/java/com/snappet/mobile/`.

## Adding a mini-app to the suite

Each mini-app is a self-contained `Features/<App>/` folder (iOS) / `feature/<app>/` package (Android).
On iOS:

1. Build your screens in `Features/<App>/`. The root view is **pushed into the App Library's
   `NavigationStack`** — do **not** wrap it in your own `NavigationStack`; set `.navigationTitle` and
   use `NavigationLink` / `.navigationDestination` for deeper screens.
2. Vend a descriptor: `enum <App>Module { @MainActor static var module: AppModule { … } }` with an
   `id`, `title`, `subtitle`, `systemImage`, `tint`, and `category`.
3. Log usage so the Home dashboard tracks it: read `@Environment(SnappetCore.self)` and call
   `core.log(module:action:summary:metric:)` on meaningful actions.
4. Persistence is **SwiftData** — define `@Model` types in your folder (globally-unique names; key
   relations by `UUID`). Trivial state → `@AppStorage`.
5. **Two central edits to wire it in:** append `<App>Module.module` to `ModuleRegistry.all` and your
   `@Model` types to `SnappetSchema.models`. Then `xcodegen generate` & build.
6. Add a `SnappetUITests/<App>UITests.swift` driving the flow; UI tests use the `-uiTestFreshStore`
   launch argument for an isolated in-memory store.

Android follows the same shape (registry entry + `@Entity` list); see `android/README.md`.

## Commits & pull requests

- **Conventional commits, scoped:** `feat(ios):`, `fix(engine):`, `docs(android):`, `spike(phase-0a):`,
  `test(ios):`, `chore:`. Be precise in the body about what was actually verified.
- **Branch per phase/feature:** e.g. `feat/ios-mvp-highlight-engine`, `spike/hr-highlight-efficacy`.
- Open one PR per prompt/feature. Include:
  - what changed and which prompt/issue it traces to,
  - the verification you ran (and explicitly, what you *couldn't* verify because it's device-only),
  - any new entry you added to `decisions.md`.
- Don't commit a generated `Snappet.xcodeproj` diff — the project is generated from `project.yml`.

## Questions

Open an issue, or check whether the answer already lives in
[`pdd/context/decisions.md`](pdd/context/decisions.md) or the web repo's
[Snappet#60](https://github.com/harshal2802/Snappet/issues/60).
