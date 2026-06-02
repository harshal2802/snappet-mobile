# Snappet Mobile — working notes for Claude

Native iOS (+ watchOS) and Android app. iOS is the lead platform. Start from
`README.md` and `pdd/context/project.md` for the current state, and
`pdd/context/conventions.md` / `pdd/context/decisions.md` for how the repo is built.

## Standing instructions

- **Keep the knowledge graph current.** For **any** change that affects the user
  experience — a new screen/sheet/cover, a service, a watch surface, a widget, a
  navigation/data-flow edge, or a meaningful behavior change to an existing one —
  update `docs/knowledge-graph/data.js` (add/edit the `nodes` entry and wire it with a
  `links` edge) in the **same** change. The graph is the single source of truth the
  interactive map renders; treat it like docs that must not drift from the code.
- **`HighlightEngine` stays platform-free** — no HealthKit / AVFoundation / Photos /
  UIKit / SwiftUI imports. Platform I/O lives in `ios/App/Snappet/Services/`.
- **Shared wire/value types** (phone ↔ watch ↔ widget) live in `ios/App/Shared/` so
  there's one source of truth (e.g. `LiveWorkoutMessage`, `WorkoutActivityAttributes`,
  `HeartRateZone`). Compiled into every target via `project.yml`.
- **Pure logic is unit-tested without a device.** Push device-dependent behavior to a
  thin edge and keep the decision/mapping/formatting pure so it runs in `SnappetTests`
  (XCTest) with no simulator. Record decisions in `pdd/context/decisions.md`.

## Building & testing (requires macOS + Xcode — not a Linux/cloud box)

The iOS app, the watchOS companion, the widget extension, and the XCTest/XCUITest
suites need **macOS + Xcode** (and the iOS/watchOS simulators). They cannot be built or
run on Linux. The Xcode project is generated from `ios/App/project.yml` via XcodeGen.

```sh
cd ios/App && xcodegen generate && open Snappet.xcodeproj   # generate + open
# Unit + UI tests on the simulator:
xcodebuild test -scheme Snappet -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
# Engine-only (pure SPM, no Xcode/sim needed — runs anywhere Swift is installed):
cd ios/HighlightEngine && swift test
```
