# Decisions: Snappet Mobile (iOS)

Reverse-chronological. Each entry: the decision, why, and what it rules out. These are the
non-obvious choices already baked into the v0.1 code — written down so future prompts don't re-litigate
or accidentally reverse them. Product-level decisions (separate repo, etc.) live in the web repo's
`decisions.md`; this file is native-implementation-specific.

---

## [2026-05-31] Pivot to the Snappet daily-app SUITE — shared store + module registry + dashboard (P9)

**Decision**: Expanded from a single workout app to the **daily-app suite** thesis (#60 §D): a `TabView`
shell (Home dashboard + App Library), an on-device **SwiftData** shared store (**Snappet Core**), and a
pluggable **module registry**. Built 6 mini-apps alongside the existing Workout module — Pomodoro,
Habits, Journal (productivity); Tip, Split Expenses, Budget (finance) — via parallel agents.
**Architecture / contract** (so the suite stays pluggable):
- `SnappetCore` (`Core/SnappetCore.swift`) wraps the shared `ModelContext` and exposes
  `log(module:action:summary:metric:)`. Every mini-app logs usage there; the **Home dashboard**
  (`@Query` over `UsageRecord` + Swift Charts) aggregates *historical sub-app usage* across the suite.
  The App Library logs an `open` event centrally, so every module gets baseline tracking for free.
- A mini-app = a self-contained `Features/<App>/` folder vending `AppModule` (`Core/AppModule.swift`)
  with `id/title/subtitle/systemImage/tint/category/destination`. `ModuleRegistry.all` lists them;
  `SnappetSchema.models` lists every `@Model` (the one central place new persistence types are added).
- Modules are **pushed into the App Library's `NavigationStack`** → they must NOT nest their own.
- Permissions are **per-module**, not global: the suite opens instantly; the Workout module primes
  Health/Photos on first entry (the old global onboarding gate was removed).
**Persistence**: SwiftData. `@Model` types: `UsageRecord`, `PomodoroSession`, `Habit`+`HabitCompletion`,
`JournalEntry`, `ExpenseGroup`+`ExpenseRecord`, `BudgetCategory`+`BudgetTransaction`. Mini-apps key
relations by `UUID` foreign keys (not `@Relationship`) for clean per-parent `#Predicate` queries.
**Verified**: full `xcodebuild` for the simulator → **BUILD SUCCEEDED** (foundation + all 7 modules),
app installs + launches, Home dashboard renders. Device run + each app's real-data behavior still pending.

## [2026-05-31] Photos rendered as Ken-Burns clips instead of being dropped (P8)

**Decision**: `ReelExporter` previously filtered to `kind == .video` and silently dropped every photo
highlight (a photo-only workout exported nothing). Added `PhotoClipRenderer` (`AVAssetWriter` +
pixel-buffer adaptor) that renders each photo into a short H.264 **Ken-Burns** clip (slow 1.0→1.1 zoom
+ gentle pan), and `makeComposition` now iterates `plan.segments` **in order**, inserting video ranges
and rendered photo clips alike (photos are silent). Fixes preview + export together (both use
`makeComposition`).
**Why**: the engine/planner already select photo highlights and reserve `photoStill` seconds — only the
exporter ignored them. Rendering-to-clip keeps the composition's track-insertion model uniform (no
`AVVideoCompositionCoreAnimationTool` special-casing).
**Choices/limitations**: photo clips render at a fixed **1080×1920 portrait** canvas; mixed-orientation
normalization across video + photo segments (a unifying `AVVideoComposition`/`renderSize`) is **not**
done — pre-existing for video-only reels too, deferred. A failed photo render is skipped, never fails
the reel.
**Verified**: app type-checks (Swift 6, 0/0); full `xcodebuild` for the simulator → SUCCEEDED with
`PhotoClipRenderer.swift` compiled; app installs + launches. The actual Ken-Burns *visual* needs a
device/sim run with real photos.

## [2026-05-31] App now BUILDS + RUNS on the iOS simulator (not just type-checks); fixed Info.plist bundle keys

**Decision / milestone**: With Xcode 26.5 + iOS 26.3/26.4 simulator runtimes now present, ran a full
`xcodebuild` (compile **and link**) for `iphonesimulator` → **BUILD SUCCEEDED**, then `simctl install`
+ `launch` on an iPhone 17 (iOS 26.4) sim → the **value-first onboarding screen renders** and the app
stays alive (no crash). This supersedes the earlier "type-check only" verification ceiling.
**Bug fixed (build couldn't catch it; install did)**: `Info.plist` was missing `CFBundleIdentifier`,
`CFBundleExecutable`, `CFBundlePackageType`, etc. Because `GENERATE_INFOPLIST_FILE: NO`, Xcode injects
nothing, so the built `.app` had no bundle ID and `simctl install` failed ("Missing bundle ID"). Added
the core bundle keys (as `$(PRODUCT_BUNDLE_IDENTIFIER)` etc.) + orientations + `LSRequiresIPhoneOS`.
**Build invocation that works here** (the generic destination wants iOS 26.5 which isn't installed):
`xcodebuild -scheme Snappet -sdk iphonesimulator -destination 'id=<booted-sim-udid>' CODE_SIGNING_ALLOWED=NO build`.
**Still device-only**: HealthKit has no Apple Watch *workouts* in the simulator and Photos has no
real media, so the end-to-end reel flow (real workout → auto-found media → reel) still needs a device
(P1 / `RUNBOOK-device.md`). The `Snappet.xcodeproj` is generated by XcodeGen and gitignored.

## [2026-05-31] Value-first onboarding + JIT permissions; `.limited` Photos → manual picker (P2)

**Decision**: First launch shows an `OnboardingView` that explains the value before requesting
anything; Health + Photos are requested only on the explicit "Connect" tap (`AppModel.completeOnboarding`).
Onboarding is gated on a persisted `snappet.hasOnboarded` flag (HealthKit read-auth status isn't
queryable). `.limited` Photo access (or an empty auto-discovery) routes to a `PHPicker` manual picker
(`MediaPicker`) → `PhotoLibraryService.media(forIdentifiers:)`.
**Why**: #60 §C (value-first, JIT). Also fixed a latent bug — `requestAccess()` was never called, so
Photos auth was never requested and the reel flow would always throw `.denied`.
**Rules out**: silent permission prompts on appear; assuming full-library scan under `.limited`.
**Verified**: app type-checks vs iOS 18; permission UX itself needs a device.

## [2026-05-31] In-app reel preview reuses the composition — no export round-trip (P3)

**Decision**: `ReelExporter.makeComposition(for:) async throws -> sending AVMutableComposition` is
shared by preview and export. `ReelViewModel` wraps it in an `AVPlayer` for an inline `VideoPlayer`;
edits (pin/remove/reorder/restore) invalidate the preview so the next build reflects them.
**Why**: an `AVMutableComposition` *is* an `AVAsset`, so the exact cut is previewable without exporting.
`sending` lets the freshly-built composition cross from the nonisolated exporter to the `@MainActor` VM
under Swift 6 isolation.
**Rules out**: exporting just to preview. Photo-only reels can't preview yet (degrade gracefully).

## [2026-05-31] Ship prep: privacy manifest declares NO data collection (on-device) (P7)

**Decision**: Ship `PrivacyInfo.xcprivacy` with `NSPrivacyTracking=false` and empty
`NSPrivacyCollectedDataTypes` — the app has no backend and transmits nothing; Health/Photos are read,
processed, and written back entirely on-device, so there is no *collected* (off-device) data to
declare. Declared the two required-reason APIs actually used: file timestamps (C617.1 — app's own temp
files via `FeedbackStore`/`ReelExporter`) and UserDefaults (CA92.1 — the onboarding flag). App icon
scaffolded as a single 1024×1024 asset-catalog slot (`ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon`);
the actual `AppIcon.png` art + TestFlight upload are deferred (no signing/art in this environment).
Display name pinned in Info.plist + `INFOPLIST_KEY_CFBundleDisplayName`.
**Rules out**: declaring data collection we don't do; shipping without a privacy manifest.

## [2026-05-31] P1 device build is the user's step — runbook authored, not executed

**Decision**: Added `pdd/prompts/features/01-ios-device-build-and-run.md` + `ios/App/RUNBOOK-device.md`.
P1 (first device run + first `highlight-feedback.jsonl`) is **not completable headless** — it needs the
user's Mac + paired Apple Watch with real workouts + a physical iPhone (HealthKit/Photos are device-only).
**Rules out**: claiming on-device runtime is verified. It is the one remaining unproven layer; the
runbook is the path to proving it.

## [2026-05-30] Pin/order are app composition state, NOT fields on the engine `Highlight` (P4)

**Decision**: Finishing the feedback loop (prompt `04-engine-finish-feedback-loop.md`) added **pin /
reorder / restore** to the reel editor. Pin and manual order are passed *into*
`ReelPlanner.plan(highlights:media:pinnedIds:order:)` as composition inputs — they are **not** stored
on the `Highlight` struct. The PLAN's earlier wording ("add `pinned` to `Highlight`") is superseded by
this cleaner split.
**Why**: `Highlight` is the algorithm's *output*; the engine never pins or reorders. Keeping edit
state out of the output type preserves "engine produces, app composes," keeps `Highlight` immutable,
and leaves every existing call site/test unchanged (the new planner args default to empty/nil). Pinned
highlights are **budget-exempt** (always included, even over `targetDuration`) because a pin is an
explicit user choice; the canonical `Highlight.pinned` field maps from the app's `pinnedIds` when the
on-device store is eventually built.
**Training data**: pin emits `.pinned` (strong positive), reorder emits `.reordered` — previously
modeled but never fired. The loop now captures them. Verified: engine pin/order logic is unit-tested
(18 tests pass); the UI wiring type-checks vs iOS 18 but is **not** device-run yet.
**Deferred (tracked for P4b/Phase 2)**: `added` (adding a moment the engine missed) — needs a
media/time picker UI; and **pins-survive-regenerate** — regenerate re-runs the engine with fresh ids,
so pins are per-generation for now.
**Rules out**: mutating engine output to carry UI state; treating a type-check as a device run.

## [2026-05-30] PDD initialized in this repo

**Decision**: Add a local `pdd/` layer (context + prompts + evals) to `snappet-mobile`, mirroring the
web repo's structure. The web repo stays the *product brain* (research #60, cross-platform PLAN,
canonical Snappet Core schema); this layer holds the **iOS-implementation** context and the prompt
chain that drives the code here.
**Why**: the codebase had outrun its written context (a working MVP, a finished spike) with no local
PDD scaffolding. Future prompts need iOS-specific conventions and a reality-based project snapshot
without round-tripping to the web repo every time.
**Rules out**: duplicating/forking the canonical schema or research here — we *reference* and mirror
only the parts already implemented; the source of truth stays in the web repo.

## [2026-05-30] v1 reads COMPLETED workouts from HealthKit (post-hoc), not a live watchOS session

**Decision**: The MVP reads already-synced `HKWorkout` + its HR series after the fact, rather than
running a live `HKWorkoutSession`/`HKLiveWorkoutBuilder` on a watchOS companion.
**Why**: the post-workout series is the *authoritative* HR the research recommends for highlight
detection (#60 §3), and it makes v1 runnable **today** against the user's existing Apple Watch
workouts — no watch app to build/install. Live in-session capture is a later phase (0d / Phase 2).
**Rules out**: live in-session HR UI and below-iOS-26 live relay *for v1*. Don't add a watchOS target
to ship the MVP.

## [2026-05-30] Algorithm lives in a platform-free SPM package (`HighlightEngine`)

**Decision**: All selection/scoring/planning logic is a pure-Swift package with zero platform
dependencies; the app talks to it only through plain value types.
**Why**: testability (`swift test`, no device), portability (reuse on watchOS, later Android via port
or shared spec), and a single swap point for the algorithm. The spike concluded the real winner is
probably a *fusion*, so the selector must be pluggable from day one.
**Rules out**: importing HealthKit/AVFoundation/UIKit into the engine; hardwiring HR-only selection.

## [2026-05-30] Selector is a protocol; HR-only is just today's default

**Decision**: `HighlightSelector` is a protocol (`score(at:…)` + a shared `select` pipeline doing
candidate-enumeration / NMS / padding / high-low split). Implementations: `HRHighlightSelector`
(default), `SceneHighlightSelector` (stub, returns 0 until a real vision pipeline exists),
`FusionSelector` (weighted blend, `hrLeaning` = 0.7 HR / 0.3 scene).
**Why**: the Phase-0a spike predicts a fusion beats HR-alone on real data (`RESULTS.md`). Shipping the
fusion path as real-but-inert means the day a vision selector exists, the upgrade is one line in
`AppModel.engine` — no UI/pipeline change.
**Rules out**: baking HR assumptions into the pipeline; a fusion that can't reduce to HR-only (a test
guards that it does when the scene signal is 0).

## [2026-05-30] Ship a best-guess engine now to harvest training data (the feedback loop)

**Decision**: Every reel logs what the engine proposed vs what the user kept/removed/regenerated/
exported, as JSONL on device (`FeedbackStore` → `highlight-feedback.jsonl`), attributed by selector
name + `HighlightConfig.fingerprint`.
**Why**: the spike is NEEDS-REAL-DATA; replaying real feedback offline is how we tune `HighlightConfig`,
learn the HR-vs-content weighting, and turn the synthetic verdict into a data-driven GO. Using the app
produces the dataset that optimizes the app.
**Rules out**: tuning the config from intuition; sending feedback off device (stays local; export only
with consent).
**Open**: the edit UI only fires `shown/kept/removed/regenerated/exported`. The stronger signals
(`pinned`, `added`, `reordered`) are modeled but not yet wired — closing that gap is a Phase-1 finish task.

## [2026-05-30] Auto-find media by capture-time window, with a ±90 s padding guess

**Decision**: `PhotoLibraryService` fetches `PHAsset`s whose `creationDate` falls within the workout
interval ± 90 s, mapping each to a workout-relative offset.
**Why**: "minimize manual work" is the core magic (#60 §A) — the app finds your clips, you don't pick
them. The 90 s grace pads for clock drift between the camera and the HR source.
**Rules out**: a manual-first picker as the default path (it's the *fallback* for `.limited` access).
**Open / unvalidated**: the 90 s number and the whole-clip-vs-clip-internal mapping are a guess until
the **Phase-0b time-sync spike** (`42-native-00b…`) measures real drift. Treat as provisional.

## [2026-05-30] Reel export is on-device AVFoundation; photos are skipped in v0.1

**Decision**: `ReelExporter` turns the platform-free `ReelPlan` into an `AVMutableComposition` and
exports `.mp4` via the modern async `AVAssetExportSession.export(to:as:)`. Video segments only;
photo highlights are dropped from the stitch.
**Why**: fully on-device (privacy, no backend); videos are the core of a reel. The async export API
avoids a continuation/data-race under Swift 6.
**Rules out**: any server-side rendering.
**Open**: photo highlights need a Ken-Burns still render (`photoStill` seconds) — deferred from v0.1.

## [2026-05-30] "Type-checks" ≠ "runs" — be precise about verification

**Decision**: We state exactly what's proven: `HighlightEngine` builds + 14 tests pass; the whole app
**type-checks** against the iOS 18 SDK (Swift 6, 0 warnings). A full `xcodebuild` link/bundle and a
device run are **not** done in this environment (no simulator runtime; HealthKit/Photos need a device).
**Why**: a type-check caught the real `Sendable`/`AVAssetExportSession` bugs, but it does not prove
runtime behavior. Overclaiming "verified" would mislead.
**Rules out**: reporting device-only features as working off a type-check. Next real verification =
`xcodegen generate && open` on a Mac with a device/simulator runtime.
