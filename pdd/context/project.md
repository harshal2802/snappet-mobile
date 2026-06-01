# Project: Snappet Mobile (iOS)

**Last updated**: 2026-05-30
**Type**: Native iOS app (Swift / SwiftUI) — the native companion to the [Snappet web hub](https://github.com/harshal2802/Snappet).

## What we're building

A native iOS app whose flagship feature is **workout-tracking + HR-driven auto-highlight reels**:
the user does a normal Apple Watch workout and films however they like; Snappet reads the workout's
**heart-rate series from HealthKit**, **auto-finds the photos/videos shot during the workout window**,
and **assembles a highlight reel ranked by HR intensity** — minimal manual work by default, full
control for power users.

It is also the proof of the broader **Snappet daily-app-suite** thesis: mini-apps sharing one
on-device data layer ("Snappet Core") that compounds into a unified daily home.

## Who it's for

People who already track workouts on an Apple Watch and want shareable highlight reels without manual
video editing — climbers, runners, dancers first. Casual users get a finished reel in one tap; power
users curate it.

## The product brain lives in the web repo

This repo is **code + prompt assets**. The authoritative product thinking lives in
[harshal2802/Snappet](https://github.com/harshal2802/Snappet):

| What | Where (web repo) |
|---|---|
| Deep research (feasibility + UX), the source of truth for every design claim | GitHub issue [#60](https://github.com/harshal2802/Snappet/issues/60) |
| Initiative plan & full prompt chain | `pdd/prompts/features/native-mobile/PLAN-snappet-mobile.md` |
| **Snappet Core** shared data-schema spec | `pdd/context/snappet-core-schema.md` |
| Separate-repo rationale | `pdd/context/decisions.md` (2026-05-30 entry) |

The schema is **copied/generated** per platform when implementation starts — it is not a runtime
import. When it changes, it changes in the web repo first. A local mirror of the parts the engine
already implements lives in [`snappet-core-schema.md`](./snappet-core-schema.md).

## Stack

- **Language**: Swift 6 (strict concurrency; `Sendable` enforced).
- **UI**: SwiftUI (`@Observable` / `@MainActor` view models, `NavigationStack`).
- **Algorithm core**: `HighlightEngine` — a pure-Swift SPM package with **zero platform dependencies**
  (no HealthKit/AVFoundation/UIKit). The swappable selection algorithm; unit-tested with XCTest.
- **Platform services**: HealthKit (completed-workout HR reads), Photos/PhotoKit (time-window media
  discovery), AVFoundation (`AVMutableComposition` + `AVAssetExportSession` on-device reel export).
- **Project generation**: XcodeGen (`ios/App/project.yml` → `Snappet.xcodeproj`); no `.pbxproj` churn in git.
- **Deployment target**: iOS 18.0. watchOS companion: later phase.
- **Experiments**: throwaway Python harnesses under `experiments/` (stdlib only, seeded/reproducible).

## What good output looks like

- The **default reel is genuinely good** — most users never open the editor (auto-generate-then-edit, #60 §B).
- **Progressive disclosure**: one-tap casual path; advanced controls behind "Edit".
- **Value-first, just-in-time permissions**; full Photo Library primed with a limited/multi-select fallback.
- The algorithm is **swappable + tunable in one place** (`AppModel.engine`, `HighlightConfig`) — no
  UI/pipeline change to switch HR-only → fusion.
- **Every edit produces training data** (the feedback loop) so the synthetic spike can become a
  data-driven GO. Using the app improves the app.
- Builds clean under Swift 6 strict concurrency; engine changes ship with passing unit tests.

## Constraints (what the AI should never do or suggest)

- **On-device only. No backend, no network sync, no accounts.** Health + media never leave the device.
- **HealthKit/Photos are device-only** — they don't run in the simulator; don't claim a feature is
  "verified" off a type-check alone (see `decisions.md`).
- Keep `HighlightEngine` **platform-free** — no HealthKit/AVFoundation/UIKit imports in that target.
- **Don't hardwire HR-only.** The spike predicts the real winner is a fusion (HR + content + manual
  pins); keep the selector pluggable.
- No analytics/tracking/third-party SDKs. No feature creep beyond the flagship flow until it ships.
- Don't bump `HighlightConfig` knobs or selector weights from intuition — change them from replayed
  feedback data or a spike result, and record the why in `decisions.md`.

## Current state (2026-05-31)

🟢 **Now the Snappet daily-app SUITE (P9) — builds + runs on the iOS simulator.** A `TabView` shell
(Home dashboard + App Library) over an on-device SwiftData store (Snappet Core), with 7 modules:
**Workout Reels** (flagship), **Pomodoro / Habits / Journal** (productivity), **Tip / Split Expenses /
Budget** (finance). Every app logs usage to Snappet Core; the Home dashboard aggregates historical
usage (Swift Charts). Full `xcodebuild` → BUILD SUCCEEDED; installs, launches, dashboard renders.

🟢 **Feature-completeness pass on the 6 non-flagship apps (2026-05-31, issues #9–#14).** Each got one
coherent increment, implemented on its own branch by parallel agents and merged one-by-one:
**Pomodoro** session history + 7-day chart + persisted settings; **Habits** edit + 7-day backfill strip
+ 30-day rate; **Journal** tags + `.searchable`; **Tip** calculation history (its first `@Model`) +
editable presets + round-up; **Split Expenses** edit expenses/groups + manual settlements; **Budget**
edit transactions + month switcher + 6-month trends. Prompts in `pdd/prompts/features/12–17`. Tests:
each app has a `SnappetUITests/<App>UITests.swift` driving its flow; UI tests use a `-uiTestFreshStore`
launch arg (isolated in-memory store) for determinism. **Verified on the iPhone 17 Pro sim: all 10 UI
tests green** (6 apps + `SuiteSmokeTests` + `WorkoutWalkthroughTests`) and `HighlightEngine` 18/18.
Remaining: data-dependent on-device runs (Workout needs Apple Watch workouts/Photos); the Budget
month-switcher's forward chevron is verified in-app but its synthetic XCUITest tap is flaky (harness
quirk, noted in the test).

### Built

- **`HighlightEngine`** (pure Swift package): `HeartRateSeries` (resample→smooth→%HRR→derivative),
  `HighlightSelector` protocol with `HRHighlightSelector` + `SceneHighlightSelector` stub +
  `FusionSelector`, `HighlightConfig` per-activity presets, `ReelPlanner` (pin budget-exemption +
  manual order), `HighlightFeedbackEvent` + `FeedbackSink`. **18 XCTest cases pass** (`swift test`).
- **iOS app** (`ios/App/Snappet`): `AppModel`, `HealthKitService`, `PhotoLibraryService` (+ limited-
  access mapping), `ReelExporter` (AVFoundation, shared `makeComposition`), `FeedbackStore`,
  `OnboardingView`, `MediaPicker` (PHPicker fallback), `WorkoutListView`, `ReelView`+`ReelViewModel`
  (auto-generate-then-edit with pin/reorder/restore + in-app `VideoPlayer` preview). Ship-prep:
  `PrivacyInfo.xcprivacy`, app-icon asset-catalog slot, display name.
- **Analysis tools** (`experiments/`): `media-hr-timesync` (P5) and `feedback-replay` (P6, + Fusion
  selector & tolerance sweep added to `hr-highlight-efficacy`). All run, seeded.
- **Verified**: 18 engine tests pass; whole app **type-checks vs iOS 18 SDK** (Swift 6, 0/0); **full
  `xcodebuild` compile+link for the simulator succeeds**; the app **installs, launches, and renders**
  the onboarding screen on an iPhone 17 (iOS 26.4) sim.

### Not yet done / known gaps

- ⏳ **No on-device run yet (P1, the user's step).** Follow `ios/App/RUNBOOK-device.md` on a Mac with a
  paired Apple Watch + physical iPhone to validate runtime, permission flows, and reel export, and to
  produce the first `highlight-feedback.jsonl`. This is the one unproven layer.
- ✅ **Photo highlights render (P8, 2026-05-31)** — `PhotoClipRenderer` turns photos into Ken-Burns
  clips interleaved into the reel (was: silently dropped). Builds on the sim; visual needs a device.
  Mixed-orientation normalization (a unifying `AVVideoComposition`) still deferred.
- ⚠️ **±90 s media↔HR padding**: P5's *model* says it's sound for skew+drift, but the real fix is TZ
  normalization (gross TZ errors → missing media); unconfirmed until measured on a device.
- 🟡 **Phase-0a verdict is NEEDS-REAL-DATA** (synthetic). P6 added Fusion + a tolerance sweep (Fusion
  overtakes Scene at ±12–15 s), strengthening the fusion case — but real sessions still decide.
- App-icon **art** + **TestFlight upload** deferred (need signing/art).

## Roadmap

See [`pdd/prompts/features/PLAN-ios-to-shippable.md`](../prompts/features/PLAN-ios-to-shippable.md)
for the prompt chain that drives v0.1 → a shippable v1. The cross-platform initiative plan (Phases 0–5)
lives in the web repo's `PLAN-snappet-mobile.md`.

**Next initiative (post-v1, planned 2026-06-01):** **Live Workout Capture + Video Studio** —
[`pdd/prompts/features/live-workout-studio/`](../prompts/features/live-workout-studio/PLAN.md)
(`RESEARCH.md` + `PLAN.md` + A1). Adds a watchOS companion for live HR/timers/background to WorkoutTracker,
session media tagging, an enriched summary, a CapCut-style clip editor, engine-driven highlight generation,
and share/save — bridging WorkoutTracker to `HighlightEngine`. Tracking: GitHub issue
[#15](https://github.com/harshal2802/snappet-mobile/issues/15).

## License

TBD.
