# Project: Snappet Mobile (iOS)

**Last updated**: 2026-06-11
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

- ✅ **Flagship validated on a real device (P1, 2026-06-15).** Ran `RUNBOOK-device.md` on a physical
  iPhone (MrRobot): onboarding → Health + Photos permissions → workout load → media auto-discovery →
  HR/Fusion-ranked reel → preview → **export** all work, and it produced the **first real
  `highlight-feedback.jsonl`** (73 events; the `feedback-replay` tuner ranks 3 real configs end-to-end).
  Validation surfaced + fixed one P1 bug — see next bullet. 681/681 on-device unit tests green.
- ✅ **Reel export normalizes mixed orientation (2026-06-15, prompt 58, issue #139).** The flagship
  `ReelExporter` exported with no `AVVideoComposition`, so any reel mixing clip dimensions/orientations
  failed on device (`AVFoundationErrorDomain -11800` / `OSStatus -12902`) — invisible on the sim (no real
  footage). Now `makeComposition` returns a normalizing `AVVideoComposition` (render canvas + per-segment
  orient-then-aspect-fit), used by export AND preview. Closes the "mixed-orientation normalization
  deferred" gap. Device-verified on a Dance reel.
- ✅ **Photo highlights render (P8, 2026-05-31)** — `PhotoClipRenderer` turns photos into Ken-Burns
  clips interleaved into the reel (was: silently dropped). Builds on the sim; visual needs a device.
- ⚠️ **±90 s media↔HR padding**: P5's *model* says it's sound for skew+drift, but the real fix is TZ
  normalization (gross TZ errors → missing media); unconfirmed until measured on a device.
- ✅ **Flagship intelligence wired (#83, 2026-06-15, prompts 59+60).** The half-built moat is closed in
  two stacked PRs: **Step 2** ported the feedback-replay tuner into `HighlightEngine` as pure Swift
  (`FeedbackReplay`, parity-tested vs the Python harness) + an on-device read of the local JSONL
  (`AppModel.recomputeFeedbackTuning`, `exportAll`'s first caller) → a replay-derived HR-vs-scene
  weighting; **Step 1** added the real Vision scene scorer (`Services/SceneScorer`: saliency + sharpness
  + face/body presence) feeding `FusionSelector` via the `visualScore` seam. The scene term enters the
  blend ONLY when replayed feedback has tuned in a weight (gated — no change from intuition). Engine
  stays platform-free.
- 🟡 **Phase-0a verdict is NEEDS-REAL-DATA → now collecting.** The first real on-device
  `highlight-feedback.jsonl` exists (P1 validation); the on-device `FeedbackReplay` ranks real configs.
  Enough real sessions still decide the final HR-vs-content weighting — but the loop now runs on-device,
  not just in the Python spike.
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

🟢 **Gym clip-tap → scoped Studio; single-clip editor retired (2026-06-17,
`73-ios-workout-clip-tap-studio-parity.md`).** Brought the WorkoutTracker session detail to Kilter
parity: tapping a video clip now opens the CapCut-style **multi-clip Studio scoped to that one clip**
(`focusClipMediaID` + `visibleClipMediaIDs=[clip.id]`) — the same editor the Kilter side opens per-clip —
instead of the old single-clip "Edit Clip" sheet; the session-wide "Edit in Video Studio" button still
opens it unscoped. New `StudioEntry.resolveProject` reconciles videos discovered after the project was
created (mirrors Kilter) so a scoped open is never blank. With both clip paths through the one Studio, the
old stack was **deleted as dead code** — `ClipEditorView`/`ClipEditorViewModel`, the `@Model ClipEdit` +
`TextOverlay`, and the `VideoStudio`/`EditPlan` render engine — leaving the multi-clip
`StudioProject`/`StudioComposer` as the single editor + render engine. First intentional `@Model` removal
from the schema/backup (destructive to legacy single-clip edits — accepted, alpha; see decisions.md).
Build + `SnappetTests` green; the UI walkthrough's clip-tap step now drives the Studio.

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

🟢 **Data safety: suite backup/export/restore + visible corrupt-store fallback (2026-06-10,
prompt 47, issue #68).** iOS (mirrors Android #84). Apps → toolbar → **Back up & restore**:
"Back up my data" serializes every `SnappetSchema` model into ONE versioned JSON file via the
suite's first `.fileExporter` (`Core/SnappetBackup` — explicit Codable Rows with a tripwire
test against schema drift; exact-Date encoding; HR series at full fidelity, compact JSON);
"Restore from backup" decode-validates, confirms, then replace-everything in a single save.
Per-module exports where format matters: Journal→Markdown, Budget/Split Expenses→CSV, workout
history→JSON, and `FeedbackStore.exportAll()`→JSON (its first call site). And the silent
corrupt-store fallback (`SnappetApp`'s `try?`→in-memory branch) is now captured in
`StoreHealth` and rendered as a persistent banner ("changes made now won't be saved") offering
restore-from-backup or a confirmed store reset — testable via `-uiTestCorruptStore`.
**Device-pending**: a real Files/iCloud Drive export+restore round trip.

🟡 **Fitness IA cleanup (2026-06-11, prompt 48, issue #74).** iOS. The two near-identically named
fitness cards are disambiguated: the gym tracker's display title is now **"Gym Tracker"**
(persisted id stays `workout-log` — `UsageRecord`s and routes key on it; Home feed rows now
caption with registry display titles), its subtitle advertises the video studio, and the two
modules cross-link ("Looking for your Apple Watch workouts?" on the tracker dashboard — empty
state included — and a Gym Tracker footer row in the Reels list). The tracker's section control
is **text-labelled** (Dashboard / Library / Routines / History; the "Exercises" segment was renamed
**Library** in workout-redesign E3 — a discipline-spined library of all workout types — with the
`browse` case id + the `workout.sectionPicker` a11y id unchanged; native segmented style kept so
XCUITest `segmentedControls` queries still resolve) with Settings moved to a toolbar gear that
pushes `WorkoutSettingsRoute`. The multi-clip studio is surfaced at module level: a dashboard
**Video Studio** card (Open-in-Studio rows for recent video-bearing sessions, a how-to hint
before any exist), a Studio badge + leading-swipe shortcut on media-bearing History rows, and the
session-detail button renamed "Edit in Video Studio" — all opening the same project through the
pure-cored `StudioEntry` (`StudioEntryTests`). **Simulator-pending**: the updated
walkthrough/UI-test suite (orchestrator's verification pass).

🟡 **Kilter un-buried (2026-06-11, prompt 49, issue #75).** iOS (the sibling of Android #94).
Sessions and create-a-climb leave the ellipsis menu: a visible **`+` Create climb** toolbar button
and an **idle Start-session bar** in the slot the green live bar takes over when active (start/end
left the menu — the bars own the lifecycle). Logging with no session live **auto-starts one**
(source `"auto"`, the BLE-connect parity; `start` folds recovery so an open session is adopted,
never forked) with an undoable "Session started" capsule — Undo keeps the log, detached. The
first-run catalog gate now **leads with Download** (Import secondary; boardlib/stale-account copy
replaced with user-terms captions — ToU posture unchanged). The shared HR profile gets a Kilter
Settings row + an inline "set up your heart-rate profile" affordance on default-ceiling summaries
(the summary ceiling resolves snapshot → live profile → 190). And `snappet://` is **registered**
(`CFBundleURLTypes`): a shared climb's QR scanned with the iOS Camera opens Snappet on the climb —
`RootShell.onOpenURL` → pure `SnappetDeepLink`/`KilterDeepLinkRouting` → one-shot
`SuiteRouter.pendingKilterClimb`, with a graceful "not in your catalog" landing (the in-app scanner
routes the same way now). **Simulator-pending**: unit + UI suites, `xcrun simctl openurl` cold/warm.
**Device-pending**: real Camera QR scan, BLE auto-start parity.

🟡 **OS integration — Phase 1: App Group + widget Today snapshot (2026-06-15, prompt 54, issue #81).**
iOS. Opening the suite to the OS (home-screen widgets → App Intents → Spotlight) in four stacked PRs;
this first PR is the foundation. An **App Group** (`group.com.snappet.app`) now sits on the app + the
`SnappetWidgets` extension, and the app publishes a small versioned **read-only snapshot**
(`Shared/SnappetWidgetSnapshot` + `WidgetSnapshotStore`) the widget will read — chosen over moving the
live SwiftData store into the App Group (decisions.md: isolates the widget from `SnappetSchema` churn,
no store-location migration, no cross-process locking, fully unit-testable). The snapshot is built by
the pure `WidgetSnapshotBuilder` (reusing `TodayDigest` + `HabitMilestones.streak`) and published by
`WidgetSnapshotService` on `scenePhase` from `RootShell` (no-op under the `-uiTest*` args so test runs
can't leak a snapshot file). `dayStreak` is the Home dashboard's suite-engagement streak via the shared
pure `TodayDigest.activityStreak` Home itself now uses — not a per-habit streak — so the widget can't
diverge from Home. **Verified**: app + watch + widget build, sign, embed with the new entitlement on the
sim; `WidgetSnapshotTests` (codec round-trip, missing-key/future-version back-compat, builder + streak
parity) + full unit suite green; UI suite green. **Device-pending**: the group must be registered under
the signing team in the portal for a device/TestFlight build, and the home-screen widget actually
rendering the snapshot (the Simulator does provide the container, so the file edge runs on the sim) —
both land verifiable with the Phase-2 widget UI. **Next**: Phase 2 (Today
widget + interactive check-off AppIntent via an App-Group outbox), Phase 3 (App Shortcuts), Phase 4
(Spotlight).

🟡 **OS integration — Phase 2: Today widget + interactive check-off (2026-06-15, prompt 55, issue #81).**
iOS. The springboard now has a **Today** widget (`SnappetWidgets/TodayWidget`, small + medium) reading
Phase 1's App-Group snapshot: day streak + habits remaining, and on medium an **interactive habit
checklist** + a **Start focus** button. Check-off works **without opening the app** via `ToggleHabitIntent`
(`Shared/`, `openAppWhenRun=false`) → it writes an App-Group **outbox** (`WidgetOutbox`, a directory of
one-file-per-toggle, race-free) + optimistically updates the snapshot; the app drains + reconciles into
SwiftData on foreground via the pure, idempotent `HabitCheckoffReconciler` (removing outbox files only
after a successful save). Start-focus is `Link(snappet://pomodoro/start)` → new `SnappetDeepLink.startFocus`
→ `SuiteRouter.pendingPomodoroStart` → `PomodoroRootView` starts the app-owned timer. The 3-lens
adversarial review caught + fixed 3 real issues: day-staleness (a snapshot built before midnight showed
yesterday's checks as today's, and a first tap silently no-op'd — fixed with the pure
`SnappetWidgetSnapshot.resolvedForDisplay`), the widget check-off not logging the `UsageRecord` that
drives the headline streak (now mirrored), and orphan completions for deleted habits (planner orphan
guard). **Verified**: app+watch+widget build/sign/embed; `WidgetOutboxTests` + `WidgetSnapshotTests`
(reconciler truth table incl. orphan/loggedAt + resolvedForDisplay staleness) + extended deep-link route
tests + full `SnappetTests` 665 green; UI suite green; `xcrun simctl openurl snappet://pomodoro/start`
routes to Snappet. **Device-pending**: the widget rendering on the springboard + a real check-off tap
firing the AppIntent. **Next**: Phase 3 (Siri AppShortcuts), Phase 4 (Spotlight).

🟡 **OS integration — Phase 3: Siri / Shortcuts App Shortcuts (2026-06-15, prompt 56, issue #81).**
iOS. The suite is now sayable + scriptable. A `SnappetShortcuts: AppShortcutsProvider` (app target)
vends 5 App Shortcuts over intents in `Shared/`: **StartPomodoro** ("start a focus timer" — the #81 AC),
**CheckOffHabit** (resolves a habit by name via a snapshot-backed `HabitEntity`, persists via the
Phase-2 outbox WITHOUT opening the app), **QuickJournal** (dictated note → prefilled new entry),
**StartRoutine** (opens the gym tracker), **OpenModule** (jump to any mini-app). Reuses Phase 2's two
cross-process channels rather than adding a third: check-off → the `WidgetOutbox`; the open-app intents
→ a new typed App-Group `AppActionInbox` the `RootShell` drains on foreground and dispatches through the
existing `SuiteRouter` deep-link paths. **Verified**: app+watch+widget build (intents/AppEntity/AppEnum/
provider compile + register); `AppActionInboxTests` (codec + module-id map + HabitEntity mapping) + full
`SnappetTests` 670 green; UI suite green. **Accepted residual**: StartRoutine opens the tracker rather
than auto-launching a named routine (deferred). **Device-pending**: real Siri phrases, the Shortcuts-app
gallery listing, donation. **Next**: Phase 4 (Spotlight indexing + deep-link routing) — the last phase.

🟢 **OS integration — Phase 4: Spotlight + deep-link routing (2026-06-15, prompt 57, issue #81 — COMPLETE).**
iOS. The suite's content is findable in Spotlight: `SpotlightIndexer` (CoreSpotlight edge) indexes the
873-exercise catalog + the user's created climbs as `CSSearchableItem`s whose `uniqueIdentifier` IS the
`snappet://` deep-link URL — so a result tap (via `.onContinueUserActivity(CSSearchableItemActionType)`)
routes through the SAME `RootShell.handle(_:)` as `onOpenURL`: `snappet://exercise/<id>` opens the gym
tracker's exercise detail; created climbs reuse the existing `snappet://kilter/climb/<uuid>` route. The
spec building is the pure, tested `SpotlightCatalog`. **Verified**: app+watch+widget build;
`SpotlightIndexTests` (spec ids/fields + identifier→route round-trip + parse) + full `SnappetTests` 680
green; UI suite green. **Accepted residual**: journal entries aren't indexed (no stable id — a follow-up
once `JournalEntry` gains a `uuid`); custom exercises likewise. **Device-pending**: real Spotlight
visibility + a result tap. **This completes issue #81** — the suite now has home-screen widgets
(streak + interactive habit check-off + Start focus), Siri/Shortcuts App Shortcuts, and Spotlight, all
on a shared App Group, entirely on-device. With #81 done the #100 iOS tracker is **15/16** — only
#83 (flagship intelligence, P3/L) remains.

**#83 flagship intelligence (2026-06-15, prompts 59+60, two stacked PRs).** Prerequisite cleared first:
the flagship reel flow was device-validated (P1) and a real export bug fixed (#139/#140). Then **Step 2**
(`FeedbackReplay` in the engine, parity-tested vs the Python harness; on-device replay of the local
JSONL → replay-derived weighting) and **Step 1** (`SceneScorer` — real Vision saliency/sharpness/presence
→ `FusionSelector.visualScore`, gated behind replayed-feedback tuning). Engine stays platform-free
(`swift test` green); scene fixture penalizes blurry/empty frames. **This completes #83** — with it the
#100 iOS tracker is **16/16**.

🟡 **Android Wave 3 — reels, BLE HR, Kilter share, Today home (2026-06-15, prompts 61–64, issues #90
#92 #91 #99).** Android. One wave PR closing four product-review issues. **#90:** the flagship Workout
Reels screen is rewritten in user language with a real "Coming to Android / Notify me" control (the
permanently-disabled emulator-blaming button is gone), and the first pipeline slice — `ReelRanking`, a
pure Kotlin port of the iOS HighlightEngine — lands JVM-tested. **#92:** the standard BLE Heart Rate
Profile (0x180D/0x2A37) is ported (`HRMeasurementParser` + `HeartRateZone` + `HRStats`/`HRVMetrics`,
all pure/tested; `BleHeartRateSource` is the thin edge with a default-deny RR-trust gate); a tappable
**session detail** (grade pyramid + per-climb timeline + HR summary) is driven by the pure
`KilterSessionStats`; sessions persist avg/max HR via a non-destructive **Room v4→v5 AutoMigration**
(nullable columns, committed schema, extended baseline test; Wave 2 shipped no schema change, so this v5
is the only bump and stands as-is). **#91:** the Kilter share loop closes —
QR render (zxing) + scan (CameraX + ML Kit), the `snappet://kilter/climb/<uuid>?angle=<n>` deep link
(pure-parsed, the iOS-compatible scheme), and paste-frames import, reusing the UUIDv5 identity. **#99:**
the Today tab becomes a daily home — feed rows show display names and deep-link in, actionable cards
(habits with inline check-off, focus) deep-tap in, and **Jetpack Glance widgets** (headless habit
check-off + focus) plus 4 static launcher shortcuts ride a shared `SuiteRouter`; cards and widgets read
ONE pure `TodayData` aggregator. **Verified**: `:app:testDebugUnitTest` (124) + `:app:assembleDebug`
green; androidTest compiles. **Device-pending**: live strap bpm, the instrumented v4→v5 migration run,
camera QR scan, Glance render + on-launcher check-off, shortcuts, and the full Reels device pipeline.

🟢 **Android Continuous-polish batch (2026-06-15, prompts 65/66/67, issues #97/#98/#93).** Android.
Three polish issues in one PR. **#97 (design tokens + motion):** one page gutter (`Spacing.pageGutter`,
16dp) + one card radius across the module roots, a single `Color.kilterAccent()` (no raw amber hex left
in Kilter), and one structural-transition spec (`Motion.snappetSurfaceTransition`, slide+fade, instant
under reduce-motion) shared by the tab switch, the workout EXERCISE→REST→DONE change, Kilter's
sub-screen swaps, and the library NavHost (no more 700ms crossfade); Kilter's count rolls, list rows
animate, and the session banner springs — all reduce-motion-gated. **#98 (accessibility):** pure
`ChartAccessibility` summaries give every silent Canvas (Home/Pomodoro bars, Budget donut, KilterBoard)
a `contentDescription`; the habit DayCell is now a `Role.Checkbox` with Done/Not-done state + ≥48dp
targets; the bar charts gained weekday labels, a today-highlight, and value annotations. **#93 (Kilter
delight):** a live "≈ V5 at 40°" manual-editor grade chip (pure linear model, meta-only — no ONNX) that
persists into `predictedGrade`; sibling swipe in detail (`HorizontalPager` over the browsed list);
**Plan a session** (pure ported `KilterRecommender` + `KilterPlanScreen`); and distinct log icons
(Attempt → Replay, Project → Flag) with long-press status tooltips. **Verified**: `:app:assembleDebug`
+ full `:app:testDebugUnitTest` green (new `KilterRecommenderTest`, `KilterManualGradeTest`,
`ChartAccessibilityTest`). **Device-pending**: real TalkBack verification (#98); swipe/estimate/Plan
end-to-end need a real catalog (#42) + installed generator meta on the emulator (#93).

🟡 **Clips feed — video/photo-first tab (2026-06-21, prompt 82, vertical slice).** iOS. A new bottom
tab **Clips** (Home · Clips · Recap · Apps; `SuiteTab.clips`, `snappet://clips`) — an Instagram-style
feed where the media IS the post: one post per exercise/climb, its clips a swipeable carousel, each
poster burning in the live HR scorebug (the editor's `HRTileView .scorebug`) + the climb/exercise name.
Derive-on-read over `SessionMedia` + the session models via the pure `ClipFeedComposer` (one post per
`FeedMedia` group; unit-tested in `ClipFeedComposerTests`) — **no new store**, the session stays the
single source of truth. The ⋯ menu reuses existing entry points: Edit this clip / Edit all · N
(`StudioEditorView` scoped via `StudioEntry`), Go to session (`SuiteRouter` open+push). Distinct from
the Recap card feed. **macOS gate passed (2026-06-21):** authored on Linux, then compiled + run on
Xcode — `ClipFeedComposerTests` (7) + the whole `SnappetTests` suite (1437, 0 failures) green, a new
`ClipsFeedUITests` (tab order Home·Clips·Recap·Apps + empty state) green, 0 warnings in the new files,
and a simulator pass confirming the tab order + `snappet://clips` selecting the tab. **Device-pending:**
the carousel paging, the HR scorebug + climb/exercise-name overlays, and the three ⋯ actions need real
Photos assets + a captured HR series (a fresh-store sim shows only the empty state). **Tap-to-play
(prompt 83):** tapping a poster now opens Recap's fullscreen `PagedMediaViewer` at that clip (real
AVPlayer playback, same HR overlay, presented without Share) — the viewer was decoupled from `FeedCard`
(optional `card` + explicit `restHR`) so Recap is unchanged; the tap→play path itself is device-owed.
**Inline-render plan (2026-06-22, stacked PRs):** the inline auto-clip hero was dropped in Recap R12
(black box in the scrolling card) → the plan is *tap-to-play inline* (not autoplay-on-scroll). **Phase 0
(prompt 84):** `ClipHROverlay` is now the single source of truth mapping a clip → its HR overlay +
video-playhead `fraction`, and the fullscreen viewer's scorebug goes **live** (BPM + chart dot track the
video, the editor's behaviour). **Phase 1 (prompt 85):** tapping a video poster now plays it **inline**
in the carousel (replacing the fullscreen pop-up), live HR riding the same `fraction`. One player engine
(`ClipMediaSurface`) backs both the inline poster and the fullscreen viewer (one `AVPlayerLayer`
lifecycle); single-active is tap-driven (`PlayingClipRef`, last-tapped-wins), **not** scroll-driven (the
dropped-R12 black-box lesson). The inline render is the R12 risk → **must be device-verified**. **Explore
grid (prompt 86):** a nav-bar `square.grid.3x3` button opens an IG-style grid (`ClipsGridView`) of all post
covers; tapping one scrolls the feed to that post — derive-on-read over the same composer, no new store.
**Share-a-clip (prompt 87):** a ⋯ "Share clip" exports the centered clip's raw video
(`ClipShareService`, passthrough) to the system `ShareSheet`; the overlay-burned share stays ⋯ → Edit →
Studio. **Reactions (prompt 88):** a ❤️ favorite per post (`ClipReactionStore`, UserDefaults — no new
`@Model`); a heart button in the header toggles it. **WYSIWYG feed-HR (prompt 89):** the poster now
renders the session's SAVED Studio HR tile (`StudioProject.hrOverlay?.tile` via `@Query`, so a Studio
edit re-renders the feed) instead of the fixed scorebug, falling back when none/empty — opt-in WYSIWYG
for the feed (Recap viewer stays the house style). **Autoplay-on-scroll (prompt 90):** opt-in (default
OFF, nav-bar toggle), muted, suppressed under Reduce Motion / Low Power — the ≥70%-on-screen card plays
its clip muted (a per-card `.onScrollVisibilityChange`, NOT the R12 scroll-center coordinator); tap to
unmute; reuses the proven `ClipMediaSurface`. **The inline render under scroll is THE R12 risk → must be
device-verified before defaulting ON.** All of the Clips inline-render + follow-up plan (#1 grid/share/
reactions, #2 WYSIWYG, #3 autoplay) is now built; only a favorites filter remains optional.

## License

TBD.
