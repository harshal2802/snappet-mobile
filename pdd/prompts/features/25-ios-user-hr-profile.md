# Prompt: On-device user HR profile — personalized zones, %HRR, HR-based calories

**File**: pdd/prompts/features/25-ios-user-hr-profile.md
**Created**: 2026-06-08
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Fitness-band richness roadmap → **Phase 2 (the keystone)**. See
`pdd/prompts/features/fitness-band-richness/ROADMAP.md` (Phase 1 shipped in PR #56). Phases 3 (RR→HRV)
and 4 (recovery nudge) build on this.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Replace the single hardcoded `HeartRateZone.defaultMaxHR = 190` with a small, on-device,
app-agnostic **user HR profile** (age / resting HR / max HR / weight / sex; manual entry + HealthKit
prefill). Once a profile exists, the suite stops pretending every climber tops out at 190: zone
colors, real `%HRR`, per-set/per-climb effort, redline/strain, and a brand-new **HR-based calorie
estimate** (which fills the BLE band's hardcoded `energy = 0`) all personalize — in **both**
WorkoutTracker and Kilter, and on every HR surface (summary, live pill, Live Activity, watch face,
widget). With no profile, behavior is byte-for-byte today's bpm-only defaults, identically in both
apps (the parity invariant's symmetric gating).

## Context the implementer needs

- **The structural parity gap to close (roadmap Phase 2):** `KilterSession` already has
  `maxHR` / `restHR` / `metricsSourceRaw` and `KilterSessionDetailView` already personalizes off them;
  `WorkoutSession` has only `hrSeries`, so today the workout side can't. Add `maxHR` / `restHR` /
  `metricsSourceRaw` (+ a new `kcalEstimate`) to `WorkoutSession` (additive Optionals → lightweight
  migration, the `hrSeries` precedent) and populate them in `finishWorkout` from the profile. Add the
  same `kcalEstimate` to `KilterSession`.
- **Honest personalization gating:** store `session.maxHR` only when the profile *resolves* one (an
  explicit max override, else an age estimate) — never a stored `190`. No resolved max → the field
  stays `nil` → `%HRR`/effort stay the bpm-only state, exactly as today. `peakHRR` per-set is already
  plumbed through `WorkoutHRStats.setEfforts(maxHR:restHR:)`; it just needs the values passed at the
  `SessionDetailView` call site (currently omitted) + the `HREffortBadge`/zone tints threaded.
- **Calories (Keytel) are BLE-only.** The Apple-Watch path already measures real active energy on the
  wrist; never override it with an estimate. Gate `kcalEstimate` on `metricsSourceRaw == ble`. For a
  watch session it stays `nil` (we don't persist watch energy → show nothing, don't estimate).
- **Max-HR formula:** use Tanaka (`208 − 0.7·age`), the current physiological standard, not the older
  `220 − age`. Record the choice in `decisions.md` and update the `HeartRateZone` doc-comment (which
  still references "220 − age" / "a later prompt").
- **The profile must reach off-device processes.** The watch app and the widget extension can't read
  the phone's `UserDefaults`, so the resolved `maxHR` travels as a **wire field**: a new optional on
  `LiveMetricsContext` → `LiveWorkoutMessage.start` (watch face zone) and a new static attribute on
  **both** `WorkoutActivityAttributes` and `KilterActivityAttributes` (widget zone). All optional /
  back-compatible.
- **Keytel formula** (kcal/min, HR in bpm, weight kg, age yr): men
  `(−55.0969 + 0.6309·HR + 0.1988·w + 0.2017·age)/4.184`; women
  `(−20.4022 + 0.4472·HR − 0.1263·w + 0.0740·age)/4.184`. Needs a male/female sex → no estimate when
  sex is unspecified (honest gating). Integrate over the bpm series with left-edge dwell.

## Approach

- **Engine (platform-free):** add `EnergyExpenditure` (`HighlightEngine`) — pure Keytel kcal/min +
  a series integrator. No app types leak in (takes scalars + `[HRSample]`). `swift test` covers it.
- **Profile (app, app-agnostic):** add `UserHRProfile` (Codable/Sendable value type: `age`,
  `restingHR`, `maxHROverride`, `weightKg`, `BiologicalSex`) with pure `resolvedMaxHR` (override →
  Tanaka → `nil`), `restingBound`, `canEstimateEnergy`, and an `estimatedKcal(forSeries:durationSec:)`
  pass-through to the engine. A `@Observable UserProfileStore` persists it to `UserDefaults` (JSON);
  lives once on `AppModel` (shared by both apps). Pure parts unit-tested in `SnappetTests`.
- **HealthKit prefill (thin Services edge):** extend `HealthKitService` to read date-of-birth →
  age, biological sex, latest body mass, resting HR; merge into blank profile fields. Device-only;
  the math/merge stays testable.
- **Persist on session end:** `finishWorkout` (WorkoutTracker) and `KilterBoardController.end`
  (Kilter) stamp `maxHR = profile.resolvedMaxHR`, `restHR = profile.restingBound`,
  `metricsSourceRaw`, and `kcalEstimate` (BLE-only) from the shared store.
- **Summaries:** `SessionDetailView` passes `session.maxHR`/`restHR` into `WorkoutHRStats.make`,
  `setEfforts`, and the `HREffortBadge` / per-set zone tints, and shows a calories row + source label
  (Kilter already shows the source). `KilterSessionDetailView` adds the calories row. Both gate on the
  data being present so HR-less / no-profile sessions render unchanged.
- **Watch + widget:** thread the resolved `maxHR` through `LiveMetricsContext` → the watch start
  message → `WorkoutWatchManager` → the watch face zone; and through `WorkoutActivityAttributes` /
  `KilterActivityAttributes` → the widget zone tints. Live-Activity `start(...)` call sites pass it.
- **UI:** a `UserHRProfileView` editor (age/sex/weight/resting/max + "Use Health data" prefill),
  reachable from `WorkoutSettingsView` (the one app-global settings surface; the profile is global).

## Output

- New: `ios/HighlightEngine/Sources/HighlightEngine/EnergyExpenditure.swift` (+ engine tests);
  `ios/App/Snappet/Core/UserHRProfile.swift` (profile value type + store + engine bridge);
  `ios/App/Snappet/Features/WorkoutTracker/UserHRProfileView.swift` (editor).
- Edits: `WorkoutModels.swift` (+4 session fields), `KilterModels.swift` (+`kcalEstimate`),
  `WorkoutTrackerModule.swift` (`finishWorkout` + live-start maxHR), `KilterBoardController.swift`
  (`end` + start maxHR + `bind` profile), `KilterRootView.swift` (bind profile), `HealthKitService.swift`
  (prefill reads + auth), `AppModel.swift` (`userProfile` store), `MetricsSource.swift`
  (`LiveMetricsContext.maxHR`), `AppleWatchMetricsSource.swift` (send maxHR),
  `LiveMetricsCoordinator.swift` (`start(for:…maxHR:)`), `LiveWorkoutMessage.swift` (`.start` maxHR),
  `WatchConnectivityLink.swift` + `WorkoutWatchManager.swift` + `WatchWorkoutView.swift` (watch zone),
  `WorkoutActivityAttributes.swift` / `KilterActivityAttributes.swift` (+`maxHR`),
  `LiveActivityController.swift` / `KilterLiveActivityController.swift` (`start(…maxHR:)`),
  `WorkoutLiveActivity.swift` / `KilterLiveActivity.swift` (widget zone), `SessionDetailView.swift`
  (personalize + calories/source), `KilterSessionDetailView.swift` (calories), `HeartRateZone.swift`
  (doc-comment), `WorkoutSettingsView.swift` (profile entry).
- Tests: `EnergyExpenditureTests` (engine), `UserHRProfileTests` (resolvedMaxHR / gating /
  estimatedKcal), `WorkoutHRStatsTests` (per-set %HRR lights up with a profile), and the
  no-profile-is-unchanged negative controls.

## Acceptance criteria

- [ ] No profile → `session.maxHR == nil`; zones/%HRR/effort render exactly as Phase 1 (bpm-only),
      identically in WorkoutTracker and Kilter.
- [ ] With age or a max override → `resolvedMaxHR` (Tanaka for age), stored on the session; per-set
      **and** per-climb `peakHRR`/zone tints personalize off it on summary, live pill, Live Activity,
      watch, widget.
- [ ] `kcalEstimate` is computed (Keytel) only for **BLE** sessions with a complete profile
      (age+weight+male/female); `nil` for watch sessions, incomplete profiles, or unspecified sex;
      shown in both summaries when present.
- [ ] HealthKit prefill fills blank profile fields (age from DOB, sex, weight, resting HR) and never
      clobbers a value the user typed.
- [ ] Engine changes ship with passing `swift test`.
- [ ] App changes type-check (Swift 6, 0 warnings) and the full XCTest suite passes on the simulator.
- [ ] No platform imports added to `HighlightEngine`.
- [ ] `decisions.md` + the knowledge graph (`docs/knowledge-graph/data.js`) updated.

## Constraints

- On-device only; no backend/network/accounts. The profile is the user's; it never leaves the device.
- No new BLE characteristics, no RR/HRV parsing (Phase 3). Keep the engine platform-free.
- State verification honestly: the live watch-face zone + live per-set HR are device-only (no
  band/HR/watch in the simulator); the profile math, %HRR, calorie integration, and prefill-merge are
  fully unit-tested off-device.

## Test plan

1. `cd ios/HighlightEngine && swift test` (Keytel kcal math, no device).
2. `cd ios/App && xcodegen generate && xcodebuild test -scheme Snappet -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`.
3. Device follow-up (when a real strap + watch are on hand): enter a profile, run a BLE session, and
   confirm personalized zone colors on the watch + widget and a non-zero calorie estimate in the summary.
