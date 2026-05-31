# Snappet iOS app (v0.1 — first working version)

The flagship flow, end to end: **pick a completed Apple Watch workout → Snappet reads its
heart-rate series, auto-finds the photos/videos you shot during it, and builds a highlight reel
ranked by HR intensity → Share / Regenerate / edit.**

> **v1 scope decision:** this reads **completed** workouts from HealthKit (post-hoc) rather than
> running a live watchOS session. That's the authoritative HR series the research recommends
> (Snappet#60 §3) and it makes v1 runnable **today** with your existing Apple Watch workouts — no
> watch companion to install. Live in-session capture is a later phase.

## Architecture (modular by design)

```
ios/
  HighlightEngine/     ← pure-Swift package, NO platform deps. The algorithm. ✅ unit-tested.
  App/Snappet/
    Core/      AppModel (wires engine+services), FeedbackStore (training-data sink)
    Services/  HealthKitService, PhotoLibraryService, ReelExporter (AVFoundation)
    Features/  Workout (list), Reel (auto-generate-then-edit screen)
```

The engine is swapped/tuned in ONE place (`AppModel.engine`). Today it's the best-guess
`HRHighlightSelector` + per-activity presets; switch to `FusionSelector.hrLeaning(scene:)` the day a
content/vision selector exists — no UI or pipeline changes. All knobs live in `HighlightConfig`.

## The data-generation loop (why ship a best guess now)

Every reel the app builds logs what the engine proposed vs what you kept/removed/regenerated/exported
to `highlight-feedback.jsonl` (on-device, via `FeedbackStore`). Replaying those events offline lets us
tune `HighlightConfig`, learn the real HR-vs-content weighting, and turn the spike's NEEDS-REAL-DATA
(see `experiments/hr-highlight-efficacy/RESULTS.md`) into a data-driven GO. **Using the app produces
the dataset that optimizes the app.**

## Build & run

XcodeGen isn't required to understand the code, but it's the cleanest way to get a project:

```bash
brew install xcodegen          # one-time
cd ios/App
xcodegen generate              # creates Snappet.xcodeproj from project.yml
open Snappet.xcodeproj
```

Then set your signing team, run on a **real device** (HealthKit + Photos need a device, not the
simulator), and grant Health + Photos when prompted.

## Verification status — read this (precise about what's proven)

- ✅ **`HighlightEngine` builds + 18 unit tests pass** — `cd ios/HighlightEngine && swift test`. The
  algorithm, selection pipeline, reel planning (incl. pin budget-exemption + manual order), and
  feedback capture are real and proven.
- ✅ **The whole app type-checks against the iOS 18 SDK** — Swift 6, **0 errors, 0 warnings**, all
  app sources compiled against the real HealthKit / Photos / AVFoundation / AVKit / SwiftUI APIs + the
  engine module:
  ```bash
  cd ios
  xcrun -sdk iphonesimulator swiftc -emit-module -module-name HighlightEngine \
    -target arm64-apple-ios18.0-simulator -swift-version 6 \
    HighlightEngine/Sources/HighlightEngine/*.swift -emit-module-path /tmp/he/HighlightEngine.swiftmodule
  xcrun -sdk iphonesimulator swiftc -typecheck -target arm64-apple-ios18.0-simulator -swift-version 6 \
    -I /tmp/he $(find "$PWD/App/Snappet" -name '*.swift')
  ```
  This proves the API usage and Swift 6 concurrency are correct (it's what caught the `Sendable` /
  `AVAssetExportSession` fixes).
- ✅ **Full `xcodebuild` compile + link for the simulator → BUILD SUCCEEDED**, and `simctl install` +
  `launch` on an iPhone 17 (iOS 26.4) sim runs the app — the **onboarding screen renders, no crash**.
  This caught + fixed a real `Info.plist` bug (missing `CFBundleIdentifier` under `GENERATE_INFOPLIST_FILE: NO`).
  Build invocation (the *generic* sim destination wants an uninstalled iOS 26.5; target a concrete sim):
  ```bash
  cd ios/App && xcodegen generate
  xcrun simctl boot 'iPhone 17'   # or any booted iOS 26.x sim
  xcodebuild -project Snappet.xcodeproj -scheme Snappet -sdk iphonesimulator \
    -destination 'id=<booted-sim-udid>' CODE_SIGNING_ALLOWED=NO build
  ```
- ⚠️ **End-to-end reel flow still needs a real device.** The simulator has no Apple Watch *workouts*
  and no real Photos media, so "real workout → auto-found clips → reel → export" is validated on a
  device per [`RUNBOOK-device.md`](RUNBOOK-device.md). Build + launch + UI render are now proven; the
  data-dependent path is the remaining device-only step (P1).

## Next

The whole prompt chain in [`pdd/prompts/features/PLAN-ios-to-shippable.md`](../../pdd/prompts/features/PLAN-ios-to-shippable.md)
is done **except P1 — the first on-device run, which is yours**: follow
[`RUNBOOK-device.md`](RUNBOOK-device.md) on your Mac (Apple Watch + real workouts + a physical iPhone)
to validate runtime and produce the first `highlight-feedback.jsonl`. Then run
`experiments/feedback-replay/run.py <that file>` to start tuning, and once ≥8–10 real sessions exist,
apply the GO / fusion / NO-GO gate in `experiments/hr-highlight-efficacy/RESULTS.md`.

Already shipped since v0.1: value-first onboarding + JIT permissions (P2), in-app reel preview (P3),
finished pin/reorder/restore feedback loop (P4), the media↔HR time-sync (P5) + feedback-replay/fusion
(P6) analysis tools, and ship-prep scaffolding — privacy manifest, app-icon slot, display name (P7).
