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

## Verification status — read this

- ✅ **`HighlightEngine` is built and unit-tested** (`cd ios/HighlightEngine && swift test`, 14 tests
  green). The algorithm, selection pipeline, reel planning, and feedback capture are real and proven.
- ⚠️ **The app shell (Services + SwiftUI) is NOT compile-verified here** — it depends on Xcode +
  HealthKit/Photos/AVFoundation entitlements and a device, which can't run in this environment. The
  code is written to current SwiftUI/HealthKit/AVFoundation APIs and is structured to build, but
  expect to resolve minor signing/concurrency wrinkles on first Xcode build. The *logic that matters*
  for the algorithm is in the tested engine, not the shell.

## Next

- First Xcode build on device → run against your real workouts → start collecting feedback data.
- Phase 0b time-sync spike (prompt `42`) to validate the photo↔HR alignment padding used in
  `PhotoLibraryService`.
- Then: content/vision selector → fusion; advanced edit controls; live watch capture.
