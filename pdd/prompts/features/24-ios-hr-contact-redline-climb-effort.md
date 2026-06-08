# Prompt: Feature-rich band data — sensor-contact gating, redline/strain, per-climb effort

**File**: pdd/prompts/features/24-ios-hr-contact-redline-climb-effort.md
**Created**: 2026-06-08
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Fitness-band richness roadmap (multi-agent exploration, 2026-06-08) → Phase 1 (the
bpm-only quick wins that need no user HR profile and no new BLE characteristics).
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Make the fitness-band data the app already captures meaningfully richer, without violating the
on-device-only / generic-BLE / platform-free constraints and without waiting on a user HR profile.
Three quick wins, all derivable from data we already have:

1. **Sensor-contact gating.** The band already sends a sensor-contact flag in the very same
   `0x2A37` packet we parse for bpm — we discard it. Decode it and drop off-skin garbage samples
   (the dry-strap 0/40/220 bpm spikes during a dyno that otherwise poison the HR chart and the
   highlight reel), and tell the climber to *adjust the strap*.
2. **Redline + strain.** `WorkoutHRStats` already computes per-zone dwell time. Surface the two
   figures that actually characterize a bursty climbing session: **redline** time (Z4+Z5) and an
   Edwards zone-weighted **strain** (TRIMP).
3. **Per-climb effort + recovery.** Score each logged climb's HR window for peak effort and
   post-burn recovery — separating a chill V4 flash from a redline V6 project at the same grade.
4. **Parity — per-set effort in WorkoutTracker.** Generalize the same effort scoring to the workout
   logger so both apps match: score each completed set across **every** Quick/freeform `SetKind` and
   render the identical effort badge (shared `HREffortBadge`). All three wins land in both apps except
   per-effort, which is per-climb (Kilter) and per-set (WorkoutTracker).

## Context the implementer needs

- `BLEHeartRateMetricsSource.parseHeartRate(_:)` reads ONLY bpm; the flags byte's sensor-contact
  bits are ignored. **Critical:** flags **bit 2 (`0x04`) = contact SUPPORTED**, **bit 1 (`0x02`) =
  contact STATUS** — two independent bits, NOT a 2-bit enum. Gate on support first (unsupported →
  `nil`/unknown, never a false "adjust strap"); only then read the status bit. The existing `0x0E`
  test fixture has both bits set, so a naive 2-bit decode passes tests but mis-fires on real hardware.
- `WorkoutHRStats.secondsByZone` (keyed by `HeartRateZone`) already exists and is tested.
- HR lags effort ~10–30 s and boulders are short, so a climb's HR peak often lands just **after**
  its logged `endedAt`. `KilterBoardController.climbWindows` ends windows at `endedAt` with **no**
  lag extension — and it feeds media auto-assignment, so it must stay un-extended. The per-climb HR
  window must therefore be computed separately (in `KilterSessionStats`, from each log's own
  timestamps) and extended by `HighlightConfig.hrLagSec`.
- No user HR profile exists yet → zones/%HRR still anchor to `HeartRateZone.defaultMaxHR` (190).
  Redline/TRIMP/%HRR are within-user trend figures, not cross-user or clinical numbers.
- A workout `SetLog` has only a single `completedAt` (no start/duration window like a Kilter
  `KilterLogEntry`), and Quick/freeform sessions log all three `SetKind`s. Per-set effort therefore
  needs a window derivation: end = `completedAt + hrLagSec`; start = `completedAt − durationSec` for
  `.duration` holds, else a capped (120 s) lookback to the previous chronological set's completion.

## Approach

- **Engine (platform-free):** add `ClimbEffort` (`HighlightEngine`) — pure per-window stats
  (peak bpm, peak %HRR only when a `maxBpm` bound is supplied, HR rise, time-to-peak, HRR60/30),
  reusing `HeartRateSeries` for resample→smooth + %HRR. Peak searched within the window; recovery
  read past its end. The helper does NOT extend the window — the caller does. Generic enough that
  both per-climb and per-set scoring reuse it.
- **Parity (WorkoutTracker):** a shared `HREffortBadge` view (used by both apps); a pure
  `WorkoutHRStats.setEfforts(for:sessionStart:hr:…)` that derives a window per `SetKind` and scores
  each completed set via `ClimbEffort`; `SetTileRow` renders the badge. Refactor the Kilter inline
  badge onto `HREffortBadge` so there's one source of truth.
- **Services:** add `isContactLost: Bool?` to `MetricsSource` (default `nil` via a protocol
  extension → the watch path stays `nil`); `BLEHeartRateMetricsSource` gets `parseMeasurement` +
  `contactStatus`, keeps `parseHeartRate` as a bpm-only shim, drops no-contact samples in `ingest`,
  and the coordinator forwards `isContactLost`.
- **Stats:** `WorkoutHRStats` gains `redlineSeconds` / `redlineFraction` / `edwardsTRIMP` (pure
  computed). `KilterSessionStats.make` takes optional `hrSeries`/`maxHR`/`restHR`/`config` and
  scores each climb via `ClimbEffort`, mapping the result onto flat optional `TimelineItem` fields.
- **UI:** "adjust strap" affordance on the live HR pills (`LiveHRPill`, `KilterHRPill`);
  Redline/Strain tiles in `SessionDetailView` + `KilterSessionDetailView`; a per-climb effort badge
  + recovery dot on each Kilter timeline row. All additive + gated so HR-less / watch-path sessions
  render exactly as before.

## Output

- New: `ios/HighlightEngine/Sources/HighlightEngine/ClimbEffort.swift` (+ engine tests);
  `ios/App/Snappet/Features/WorkoutTracker/HREffortBadge.swift` (shared effort badge).
- Edits: `MetricsSource.swift`, `BLEHeartRateMetricsSource.swift`, `LiveMetricsCoordinator.swift`,
  `WorkoutHRStats.swift` (+`setEfforts`), `KilterSessionStats.swift`, `WorkoutPlayerView.swift`,
  `KilterHRPill.swift` (+ its two call sites), `SessionDetailView.swift` (+`SetTileRow` effort),
  `KilterSessionDetailView.swift` (effort badge → shared view).
- Tests: `HighlightEngineTests` (ClimbEffort), `MetricsSourceTests` (contact decode + ingest gating
  + coordinator forward), `WorkoutHRStatsTests` (redline/TRIMP **+ per-set effort across SetKinds**),
  `KilterSessionStatsTests` (per-climb effort + the lag-extension negative control).

## Acceptance criteria

- [ ] No-contact samples are dropped (buffer unchanged, last good `latestHR` retained) and raise
      `isContactLost`; a contact-unsupported band reads `nil`, never a false "adjust strap".
- [ ] `redlineSeconds` = Z4+Z5 dwell; `redlineFraction` is `0` (not NaN) with no dwell; `edwardsTRIMP`
      weights minutes-in-zone by zone number.
- [ ] Each scored climb exposes peak bpm + recovery; a spike within `hrLagSec` after `endedAt` is
      captured (proven by a zero-lag negative-control test); HR-less / start-less climbs stay all-nil.
- [ ] WorkoutTracker scores per-set effort across all `SetKind`s: `.duration` uses `durationSec`,
      `.repsWeight`/`.climbAttempt` use the capped previous-set lookback; incomplete / HR-less sets
      stay unscored; both apps render the identical `HREffortBadge`.
- [ ] Engine changes ship with passing `swift test`.
- [ ] App changes type-check (Swift 6) and the full XCTest suite passes on the simulator.
- [ ] No platform imports added to `HighlightEngine`; `climbWindows` (media) left untouched.
- [ ] `decisions.md` + the knowledge graph updated.

## Constraints

- On-device only; no backend/network/accounts; no new BLE characteristics, no RR/HRV/energy parsing,
  no user-profile work (all later phases). Keep the engine platform-free and the selector pluggable.
- State verification honestly: the live contact-loss stream + live per-climb HR are device-only
  (no band/HR in the simulator); the pure decode/stats/effort math is fully unit-tested off-device.

## Test plan

1. `cd ios/HighlightEngine && swift test` (ClimbEffort math, no device).
2. `cd ios/App && xcodegen generate && xcodebuild test -scheme Snappet -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`.
3. Device follow-up (separate, when a real RR-capable strap is on hand): confirm a strap toggling
   on/off-skin drives the live "adjust strap" affordance and pauses sample capture.
