# Project: Snappet Mobile (iOS)

**Last updated**: 2026-06-10
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
  *(One explicit, **narrow** exception, added 2026-06-05 — keep it named so it can't be cited to justify
  general networking: the Kilter mini-app may make a **user-initiated** request to fetch the climb
  catalog onto the device, because that data is third-party-owned (Aurora) and can't legally be
  redistributed inside the app. No background sync, no analytics, no Snappet backend; health + media
  still never leave the device. See `decisions.md` (2026-06-05) and issue #42.)*
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
editable presets + round-up; **Split Expenses** edit expenses/groups + manual settlements + **itemized
receipts** (scan with the camera or paste receipt text → per-item assignment with proportional
tax/discount + per-person split; iOS Vision / Android ML Kit OCR; mirrored on both platforms); **Budget**
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

🟢 **Kilter Board mini-app (#35)** — browse the read-only climb catalog, render a climb on the
board, log Flash/Sent/Project/Attempt, review history, QR-share climbs, and (gated, device-unverified)
light the physical board over BLE.

🟡 **Kilter create-a-climb (2026-06-09).** The module is no longer browse-only: users author climbs, either
by hand (tap holes on an editable board) or with the **on-device board-explorer transformer** (✨ Generate,
ONNX, lazy-downloaded). Every save is validated against the downloaded dataset + prior creations and given a
**deterministic content uuid** — the *same holds on iOS and Android collapse to one id* (UUIDv5, shared
golden vector). Live BLE preview + frames export round it out. **iOS:** PRs #63→#64→#65 (prompts 30–32).
**Android:** full Kotlin/Compose mirror (prompt `33-android-create-climb.md`) — `:app:assembleDebug` +
`:app:testDebugUnitTest` green (golden UUID matches iOS). Device-pending on both: real model download +
on-device ONNX inference, BLE draft-lighting.

🟢 **Kilter opt-in on-device catalog (2026-06-05, #42, `22-kilter-opt-in-catalog.md`).** The app ships
**no** Aurora climb data — the bundled `kilter.sqlite3` is gone from both platforms. On first open the
Kilter module shows an opt-in **"Get the climb catalog"** screen (surfacing Aurora's Terms of Use) that
imports a user-supplied `.sqlite3` (iOS **Files** / Android **SAF**) into `KilterCatalogStore`; the
existing `KilterCatalog` reader opens it from there and every browse/detail/log/illuminate feature works
unchanged. A `KilterCatalogProvider` seam (FileImportProvider shipped; AuroraSyncProvider an inert
Phase-2 stub) keeps the read path source-agnostic; a `KilterCatalogValidator` rejects malformed files.
Removes the redistribution exposure (#32 OQ#11.2) **architecturally**. A synthetic, zero-Aurora-data
fixture (Python generator verified locally + in-code `KilterCatalogFixture` on both platforms) drives the
tests. Authored on Linux — `xcodebuild test` (Mac) + Android `connectedDebugAndroidTest` owed at the
merge gate.

🟡 **Kilter create-a-climb — authoring (2026-06-09, `30-ios-create-climb-identity-dedup.md`, PR 1/3).**
The module is no longer browse-only: a manual hold editor (`CreateClimbView` + `KilterEditableBoardView`,
tap-to-cycle role) produces a real climb, validated against the whole downloaded dataset + previously
created climbs (`KilterDuplicateChecker`) and given a **deterministic content uuid**
(`KilterClimbIdentity` — same holds ⇒ same uuid on every device, the cross-device-identity requirement)
before persisting as a `KilterCreatedClimb`. Created climbs surface under a **Mine** browse filter and
reuse the existing detail/render/BLE/logging path via a `KilterClimb` adapter. iOS-only so far. **Next:**
PR 3 adds live BLE preview + frames export. Pure logic is sim-tested (`KilterCreateClimbTests`); the
on-board author→illuminate path is device-pending.

🟡 **Kilter create-a-climb — on-device generator (2026-06-09, `31-ios-onnx-climb-generator.md`, PR 2/3).**
The ✨ Generate tab in `CreateClimbView` runs the board-explorer's quantized **ONNX transformer**
(`model.q.onnx`, lazy-downloaded by `KilterGeneratorAssets` from the existing host) to design a climb for
a chosen size / angle / target grade. The decode is a pure Swift port (`KilterClimbGenerator` over a
`KilterLogitsProviding` protocol — unit-tested with a stub, no ONNX) behind a thin ONNX Runtime edge
(`KilterORTSession`, the only `import OnnxRuntimeBindings`; isolated in the `KilterGeneratorRuntime`
actor). Adds the `onnxruntime` SPM dependency. Generated climbs save through PR 1's dedup + content-uuid
path (`source = "generated"`). Sim-tested (`KilterGeneratorTests`, 467 total green); **device-pending:**
a real model download + an on-device inference run + frames-parity spot checks vs the web explorer.

🟡 **Kilter create-a-climb — polish (2026-06-09, `32-ios-create-climb-ble-preview-export.md`, PR 3/3).**
Closes the arc: `CreateClimbView` now lights the climb being authored/generated on a connected board over
BLE (reusing `KilterCatalog.holds` + `KilterBoardController.illuminate`), and both create tabs +
`KilterShareView` export the climb's `p…r…` frames (Copy / Share) so an authored climb is portable as
text. Full suite green (467); **device-pending:** BLE draft-lighting + clipboard/share on hardware.
Create-a-climb (PRs 30→31→32) is feature-complete on iOS; the Android mirror is still owed.

🟢 **Kilter rich session (2026-06-05, `pdd/prompts/features/18-ios-kilter-rich-session.md`).** Brought
the Live Workout toolkit to a climbing session by **reuse, not rebuild**: live HR (Apple Watch *or* a BLE
chest strap, via a `LiveMetricsContext` that decouples `LiveMetricsCoordinator` from `WorkoutSession`),
per-climb timing + attempts, photo/video auto-discovery (`SessionMediaService`) with clip→climb tagging, a
one-tap highlight reel (`HighlightEngine.Workout(.climbing)` + `ReelExporter`), a Lock Screen / Dynamic
Island Live Activity (`KilterActivityAttributes` + a dedicated controller/widget), and a rich
`KilterSessionDetailView` summary (HR zones, grade pyramid, per-climb timeline). All data-model changes are
additive (SwiftData lightweight migration); pure cores (`KilterSessionStats`, `KilterWorkoutBuilder`,
`KilterLiveSnapshot`) are unit-tested. **Verified on the iPhone 17 Pro sim: 266 unit tests green**;
`HighlightEngine` 18/18. Device-only paths (live HR, Live Activity render, board auto-session-open, Photos
discovery + reel export) are deferred to a real board + watch/HR band.

🟢 **Kilter clip-scoped editing (2026-06-05, `20-ios-kilter-clip-scoped-editing.md`).** Tapping a Kilter
clip opens a scope-filtered Studio (one clip, or a climb's clips via "Edit all · N", or session-wide),
with a floating Climb panel to edit the climb's log in place — all sharing one session `StudioProject`.

🟢 **Studio overlays & grids (2026-06-05, `21-ios-studio-overlays-grids.md`).** Editor + browse polish:
the Kilter browse bar's grade filter split into **two independent chips** (Min / Max); a **climb-name
overlay** (a lower-third `OverlayItem.Kind.climbName` auto-filled with name · grade · angle from
`KilterLogEntry`, a setter toggle from the catalog, freely editable, time-gated + keyframable like text);
a **timeline lane** to move/trim any overlay's on-screen window; and **PiP grids** — PiP gained optional
per-axis size (`normalizedWidth/Height`, default = `scale`, back-compatible) for true split-screen, with
one-tap collage presets (`StudioGridLayout`), corner-resize handles, and rule-of-thirds snap guides. Pure
cores (`KilterClimbCaption`, `StudioGridLayout`, the new `StudioProjectEditor`/`ClipEditGeometry` ops) are
unit-tested. The render paths were since **device-verified** (see the next entry).

🟢 **Studio overlay/PiP polish — DEVICE-VERIFIED (2026-06-06, PRs #46/#48/#49).** A run of editor fixes +
features, all **verified on a physical iPhone (MrRobot)** via a screenshot/recording capture loop — incl.
the export path. **Placement**: PiP/base cells were offset + overflowing; root-caused to the wrong render
origin (the `AVMutableVideoCompositionLayerInstruction` space is **top-left**, like the device-verified
`cropTransform` — NOT the Core-Animation overlay's bottom-left) and aspect-**fill** (a layer instruction
can't clip a sub-rect, so it spilled). Fixed: drop the Y-flip, aspect-**fit** (`fitTransform`), and a
source-aspect default frame. **Resize**: corner-drag now **aspect-locks** to the footage (box hugs the
video) and is **flicker-free** — the live-resize had been a SwiftUI drag-feedback loop (a `@State` driven
from the handle's own gesture re-positioned the handle); rewritten to the canonical `@GestureState`
pattern with the gesture-hosting handles anchored at the committed size. **Resizable base video**: an
optional `StudioProject.baseFrame` places the main track into a collage cell (a draggable "Main" frame +
a Grid-tool toggle). **Rich text**: text/climb-name now **wrap to ~0.9 of the video width** (preview +
export, the export box measured via `NSAttributedString.boundingRect`) so captions never spill, plus a
**Style** sheet for text colour / highlight background / font preset (`StudioFont`) / bold / italic —
rendered identically in preview and the exported file. One migration crash was caught + fixed on device:
new `OverlayItem` style fields shipped non-optional → Swift's synthesized `Decodable` threw on old saved
overlays; made optional-backed with computed defaults (the codebase's migration-safe pattern), guarded by
a decode-from-old-JSON test. Full suite green (**301 unit + 15 UI**). All 5 surfaces (placement, resize,
text+styling, base cell, **export**) confirmed working on-device.

🟢 **Kilter board design: size on the climb page, size-accurate render, color-blind hold shapes
(2026-06-07, `FEAT-board-size-render-and-colorblind-shapes`).** iOS + Android. The physical board-size
preference moved onto the browse filter bar as an inline **Size chip beside Layout** (shown when a layout
offers >1 size; cached, seeded/reset per layout). The on-screen board now **renders at the selected
size** — `renderHoles(forLayout:sizeId:)` bases the grid + aspect + hold normalization on the holes
wired for that `product_size` (the `leds` hole set), so a smaller board reads shorter and the lit holds
reshape with it (sizeId 0 / no-LED sizes fall back to the whole layout). And lit holds are now
**shape-coded by role** (start triangle / hand circle / finish square / foot diamond — a color-blind
redundant channel via the pure `KilterHoldShape`, colors kept, legend teaches it). No real board photos —
they're copyrighted Aurora assets the repo can't ship (#42), so the schematic was made size-accurate
instead. Off-device verified (new size-geometry + shape-mapping tests on both platforms, prior LED test
green, 3rd fixture size mirrored across all four sources). **Device-unverified**: that the size-coded
schematic + shapes read better on a real screen for a color-blind climber.

🟢 **Kilter: "No matching" tag + board-size download filter (2026-06-07).** iOS + Android. The climb
screen now shows the Kilter **"No matching"** rule (whether the setter forbids matching hands on a hold)
as a tag, read from the real catalog's `climbs.is_nomatch` column (grounded by inspecting the actual
165 MB Kilter dataset — 73,864/344,504 climbs flagged; `hsm` is unrelated), with a pure
description-note fallback for older catalogs. The **download** flow gained a **board-size** filter that
keeps only climbs physically fitting a chosen size — mirroring the Board Explorer's
`c.edge_* ⊆ product_sizes.edge_*` rule; sizes come from the installed catalog (hidden on a first-ever
download). Both newer columns (`is_nomatch`, `product_sizes.edge_*`) are PRAGMA-guarded and degrade on
catalogs that lack them. Off-device verified (match read, size-box read, the size-fit filter, and the
pure detector — both platforms; fixture extended across all four mirrors).

🟢 **Kilter download: board-first, end-user-friendly (2026-06-07).** iOS + Android. The catalog
download was a 12-field power-user form; reshaped around the one thing an end user knows — **which board
do you have.** The sheet is now **Your board** (Layout + Size) + **How many climbs** (a cap) + Download,
with the host URL under Advanced. **Layout + size are the only download filters** (they define your
physical board); angle/grade/quality/ascents/setter/name/benchmark moved to **browse-time** (already in
the list + Filters sheet). The size picker works on a first download via an embedded known-Kilter board
table (`KilterCatalogOptions.boards`, real `product_sizes.edge_*` fit boxes — board *dimensions*, not
climb data, #42-consistent); the chosen size's box trims the catalog to fitting climbs. Compiles clean
on both platforms; no UI test touched the removed controls.

🟢 **Kilter browse: live climb count + Clear (2026-06-07).** iOS + Android. The catalog list shows a
**live "N climbs" count** for the current search + filters (a true `count(filter)`, not the capped list)
with a **Clear** action when a search/Saved/extra filter is active — immediate feedback that makes
searching friendlier. New `count` unit test on both platforms.

🟢 **Flagship reel flow: recoverable dead ends + a real export payoff (2026-06-10, prompt 44,
issue #72).** iOS. Every reel/workout dead end is now actionable, driven by the pure
`ReelFlowPolicy` (copy + action selection, regenerate confirmations, export destination + sweep,
activity icons — `ReelFlowPolicyTests`) rendered through one `RecoveryUnavailableView`: export
failure → Retry with pins/removals/order intact (new `.exportFailed` state); Photos-denied →
Open Settings (never the fetch-blind "Select clips"); the workout empty state is truthful about
invisible HealthKit denial (Refresh + Open Settings). The success screen plays the exported reel
as an auto-playing looped hero with add-only **Save to Photos** + Share; exports persist in
`Application Support/Reels` (backup-excluded, keep-latest sweep) instead of tmp; highlight rows
show `PHCachingImageManager` poster thumbnails and workout rows activity icons.
**Device-pending**: the full flow on hardware (real export, Photos save, Settings round-trips,
haptics).

🟡 **Home is an actionable daily home (2026-06-10, prompt 46, issue #71).** iOS. `SuiteRouter` is
hoisted to the shell (`RootShell` owns tab + path; `open(module:)` is the deep-link entry —
groundwork for QR #75 / App Intents #81), so Home can route: an "Up next" section of tappable
Today cards (habits left, resume workout, focus minutes, budget month pace, plan a climb session)
derived by the pure `TodayDigest` (`TodayDigestTests`) from the same SwiftData rows the modules
query — each card renders only when its data exists; activity-feed rows deep-link into the module
that logged them; a fresh install gets a flagship CTA hero that lands in Workout Reels onboarding
(plus a featured flagship card atop the App Library, and the Home glyph moved off the app-grid
symbol to `house.fill`). Apps-tab navigation and the `apps`/`-uiTest*`/`-screenshotModule` launch
hooks unchanged. **Simulator-pending**: the card routes + first-run hero + full XCUITest suite
(the orchestrator's verification pass).

## License

TBD.
