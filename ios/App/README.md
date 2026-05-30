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

- ✅ **`HighlightEngine` builds + 14 unit tests pass** — `cd ios/HighlightEngine && swift test`. The
  algorithm, selection pipeline, reel planning, and feedback capture are real and proven.
- ✅ **The whole app type-checks against the iOS 18 SDK** — Swift 6, **0 errors, 0 warnings**, all 9
  app sources compiled against the real HealthKit / Photos / AVFoundation / SwiftUI APIs + the engine
  module:
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
- ⚠️ **A full `xcodebuild` (link + bundle) and on-device run are NOT done here.** This environment is
  missing the iOS simulator *runtime* (`xcodebuild` fails at destination resolution: "iOS 26.5 is not
  installed"), and HealthKit/Photos/AVFoundation only *execute* on a real device with signing + real
  workouts/media. Type-check is proven; full build + runtime behaviour is the next verification step,
  via `xcodegen generate && open Snappet.xcodeproj` on a Mac with the simulator runtime / a device.

## Next

- First Xcode build on device → run against your real workouts → start collecting feedback data.
- Phase 0b time-sync spike (prompt `42`) to validate the photo↔HR alignment padding used in
  `PhotoLibraryService`.
- Then: content/vision selector → fusion; advanced edit controls; live watch capture.
