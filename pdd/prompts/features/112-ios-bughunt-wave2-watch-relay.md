# Prompt: Bug-hunt Wave 2 — watch relay correctness (dropped stop, duplicated HR)

**File**: pdd/prompts/features/112-ios-bughunt-wave2-watch-relay.md
**Created**: 2026-07-08
**Project type**: Native watchOS + iOS fix (Swift) — code lands in this repo.
**Chain**: Wave 2 of the 2026-07-07 whole-repo bug hunt (issues #271–#274); Wave 1 was
prompt 111 (#271, merged as #275).
**Source**: proactive bug hunt (GitHub issue #272)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Make the watch↔phone relay correct at its two weak seams in `WorkoutWatchManager`: (F2) a stop
that arrives during `start()`'s async window is silently dropped — the watch then starts and runs
an HR-collecting `HKWorkoutSession` that was already cancelled; (F3) kcal-only
`didCollectDataOf` batches re-relay the stale `latestHR` as a *new* sample, padding the phone's
persisted `hrSeries` with duplicates and turning the on-watch average event-weighted.

## Context the implementer needs

- **F2 (dropped stop)**: `end()` guards `let session, let builder` — both `nil` for the whole
  async start window (`requestAuthorization` await + MainActor hop) that `starting == true`
  brackets. The realistic trigger is the phone queueing `start` then `stop` via
  `transferUserInfo` while the watch is unreachable: both land back-to-back when the watch app
  wakes, the stop is processed mid-auth and dropped, then `startSession` runs a workout nobody
  will ever end (battery drain + a phantom HealthKit workout until manually ended on the wrist).
- **F3 (duplicated HR)**: `relay()` runs on EVERY builder batch, including kcal-only ones. The
  unchanged `latestHR` is re-folded into `hrSum`/`hrCount` (event-weighted average) and re-sent
  as a fresh metrics message, which the phone's `AppleWatchMetricsSource.ingest` appends
  unconditionally as a new `HRSample` at a new `t` — inflating `HRCadence` density and defeating
  the honest sparse-window styling. Related latent hole: before the watch's first HR reading,
  kcal-only batches relay `hrBpm: 0` and the phone appends *0-bpm phantom samples*.

## Approach

- Extract the start/stop decision into a pure `WatchWorkoutStartGate` (in `ios/App/Shared/` so
  it compiles into both targets and unit-tests in `SnappetTests` — the watch has no test
  target): `beginStart(isRunning:)` opens the window, `absorbEndDuringStart()` remembers a stop
  arriving inside it, `completeStart()` returns `.abandon` when one was absorbed —
  `startSession` then resets instead of creating the `HKWorkoutSession` at all.
- Extract the running average into a pure `WatchHRAverage`; fold it **only when the batch
  actually collected a new HR statistic** (`newHR != nil` plumbed as `relay(hrUpdated:)`).
- Wire convention: `hrBpm <= 0` in a metrics message now explicitly means "no new HR in this
  batch". The watch sends 0 on kcal-only batches; the phone's `ingest` records energy but skips
  `latestHR` + the sample append (also closing the pre-first-reading 0-bpm phantom hole).

## Output

- `ios/App/Shared/WatchWorkoutRelayState.swift` — `WatchWorkoutStartGate` + `WatchHRAverage`
- `ios/App/SnappetWatch/WorkoutWatchManager.swift` — adopt both; `relay(hrUpdated:)`
- `ios/App/Snappet/Services/AppleWatchMetricsSource.swift` — `ingest` hrBpm ≤ 0 guard
- `ios/App/SnappetTests/WatchWorkoutRelayStateTests.swift` — gate + average contracts
- `ios/App/SnappetTests/MetricsSourceTests.swift` — kcal-only ingest test

## Acceptance criteria

- [ ] Gate contract pinned: stop inside the start window → `completeStart() == .abandon` and the
      window is fully consumed (a later start proceeds); stray stop ignored; duplicate start
      inside the window dropped.
- [ ] Average contract pinned: sample-weighted, non-positive readings don't count, reset clears.
- [ ] Phone ingest: `hrBpm: 0` records energy, keeps the last real `latestHR`, appends no sample.
- [ ] App + watch type-check (Swift 6, 0 new warnings); full `SnappetTests` unit suite green.
- [ ] `decisions.md` + knowledge-graph node descriptions updated.

## Constraints

- No wire-format change (no new `LiveWorkoutMessage` keys) — the 0-bpm sentinel keeps old/new
  sides mutually compatible.
- `HighlightEngine` untouched. UI-suite policy: logic-only change → gate on the unit suite +
  build; no new XCUITests.

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'` — full unit suite incl. the new gate/average
   tests and the extended MetricsSourceTests.
2. Device check (owed, same posture as the rest of the watch surface): paired-watch end-to-end
   on real hardware — start→stop while the watch app is closed (queued delivery), and a session
   with the wrist static long enough to produce kcal-only batches.
