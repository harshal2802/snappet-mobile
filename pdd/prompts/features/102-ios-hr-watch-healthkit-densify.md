# Prompt: Watch HR densification — backfill the sparse relay from HealthKit (Phase C / Opt 1)

**File**: pdd/prompts/features/102-ios-hr-watch-healthkit-densify.md
**Created**: 2026-06-23
**Project type**: Native iOS feature (Swift) — code lands in this repo.
**Chain**: HR-granularity epic (99) → Phase C. Builds on Phase A (`HRCadence`) + B (resample).
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

The Apple-Watch live relay surfaces HR only ~every 5–15 s, so a watch session's persisted `hrSeries` is
sparse — the root of the flat clip overlay. The watch's `HKWorkoutSession`, however, stores the full
on-wrist HR series in HealthKit (~1 per 1–5 s). After a watch session ends, **re-read that stored series
for the session window and merge the denser one into `hrSeries`** — so watch clips get real interior
detail (not just Phase B's smooth-but-interpolated line). BLE sessions are already dense (+ carry RR) and
are left untouched.

## Context the implementer needs

- `KilterSession.hrSeries` is flushed 1:1 from the live buffer on `end()` (`KilterBoardController.swift`
  ~550) and tagged with `metricsSourceRaw`. `HealthKitService` (AppModel-owned `health`) already reads a
  workout's HR via `heartRateSamples(for:)` mapping `HKQuantitySample → HRSample(t: sinceStart)`.
- HealthKit-stored `heartRate` samples carry **no RR** — fine, the watch path has no RR anyway; for BLE
  (which DOES carry RR) we must **not** densify (it would drop RR and could mix sources). Gate on
  `metricsSourceRaw == appleWatch`.
- HealthKit workout sync to the phone is **not instant** (seconds–tens of seconds after `end()`), so the
  densify must be idempotent and re-attemptable, and must no-op once the series is already dense.

## Approach

- **Pure merge.** Add `ios/App/Snappet/Features/WorkoutTracker/HRSeriesDensify.swift`:
  `enum HRSeriesDensify { static func denser(live: [HRPoint], healthKit: [HRPoint]) -> [HRPoint] }` —
  HK empty → live; live empty → HK; else the series with more samples (the watch HK series and the relay
  buffer are the SAME HR, so pick the complete one wholesale rather than union-merging two copies).
  Foundation-only → unit-tested.
- **HealthKit read.** Add `HealthKitService.heartRateSamples(start:end:) async throws -> [HRSample]`
  (a windowed read; refactor `heartRateSamples(for:)` to call it).
- **Manager wiring.** Inject `health` via `KilterSessionManager.bind(...)`. Add
  `densifyHRFromHealthKit(sessionID:in:) async`: fetch the session; guard **ended + `appleWatch` +**
  **not-already-dense** (`HRCadence.summarize(hrSeries).perSecond < 0.5` — reuses Phase A, so a re-open or
  a prior densify skips the HK query); read HK for `[startedAt, endedAt]`; `denser(...)`; write + save only
  if it grew. Idempotent.
- **Triggers.** Best-effort from `end()` (a `Task` — catches an already-synced workout) and a catch-up
  from `KilterSessionDetailView`'s existing `.task` (HK has had time to sync; re-saving `hrSeries` makes
  the Clips feed `@Query` re-render with the dense series).

## Output

- `ios/App/Snappet/Services/HealthKitService.swift` — `heartRateSamples(start:end:)`.
- `ios/App/Snappet/Features/WorkoutTracker/HRSeriesDensify.swift` — pure denser-of-two.
- `ios/App/Snappet/Features/Kilter/KilterBoardController.swift` — `bind(health:)`, `densifyHRFromHealthKit`,
  best-effort call in `end()`.
- `ios/App/Snappet/Core/AppModel.swift` — pass `health` into `bind`.
- `ios/App/Snappet/Features/Kilter/KilterSessionDetailView.swift` — densify catch-up in `.task`.
- `ios/App/SnappetTests/HRSeriesDensifyTests.swift` — empty/empty, denser wins, equal-keeps-live, BLE-skip
  (via the source guard, tested at the call layer if practical).
- `docs/knowledge-graph/data.js` + `pdd/context/decisions.md`.

## Acceptance criteria

- [ ] After a watch session ends and HealthKit has synced, its clips show the dense (~1/1–5 s) HR series.
- [ ] BLE sessions are untouched (keep their ~1 Hz + RR series); already-dense sessions skip the HK query.
- [ ] `denser` is correct on empty/denser/equal inputs; app type-checks (Swift 6, 0 warnings); `SnappetTests` green.
- [ ] No platform imports in `HighlightEngine`. `decisions.md` updated.

## Constraints

- **Device-gated**: the HealthKit read needs a real paired watch + a synced `HKWorkout`; it cannot run on
  the simulator. State this honestly — only the pure merge + the wiring's type-safety are verified here.
- Don't densify BLE (drops RR); don't union two copies of the same HR.

## Test plan

1. `xcodebuild test … -only-testing:SnappetTests` — green incl. `HRSeriesDensifyTests`.
2. Device (flagged): do an Apple-Watch Kilter session, wait for Health sync, open the session / Clips — the
   clip HR curve shows real interior detail (no longer dashed/sparse).
