# Prompt: RR-intervals → on-device HRV (device-gated)

**File**: pdd/prompts/features/26-ios-rr-intervals-hrv.md
**Created**: 2026-06-08
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Fitness-band richness roadmap → **Phase 3** (builds on Phase 2, prompt `25-…`). See
`pdd/prompts/features/fitness-band-richness/ROADMAP.md`.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

The BLE band already sends RR-intervals (beat-to-beat timing) in the same `0x2A37` packet we parse
for bpm — and we discard them. Parse them, and compute **on-device HRV** (RMSSD / SDNN / pNN50) purely
in the engine, surfacing a per-rest HRV figure between efforts in **both** apps (between-climbs in
Kilter, between-sets in WorkoutTracker) — the recovery-quality signal that bpm alone can't give. No
new Bluetooth characteristic for HR (RR rides the packet we already read), no cloud, no vendor SDK.

## Context the implementer needs

- **RR is in the HR Measurement we already parse.** `BLEHeartRateMetricsSource.parseMeasurement`
  reads flags + bpm + sensor-contact and **stops**. Flags **bit 3** (`0x08`) = Energy-Expended present
  (a UInt16 that sits *before* RR — must be skipped to reach RR), **bit 4** (`0x10`) = RR-Intervals
  present (a variable-length array of UInt16, **units of 1/1024 s** → convert to ms: `×1000/1024`).
- **Honest device gating (the crux).** RR is trustworthy only from **chest straps**; optical wrist/arm
  sensors emit synthetic or no genuine RR. Gate capture on a pure model/name classifier
  (`rrTrusted(modelNumber:deviceName:)`, default-**deny** — unknown → degrade to the bpm-only effort
  /recovery already shipped). The roadmap calls for a Device-Info (`0x180A`, Model Number `0x2A24`)
  read; do it as a refinement, but also classify off the peripheral **name** we already have so a
  named strap ("Polar H10") is trusted without waiting on `0x180A`. The Apple-Watch path emits no RR
  → HRV is absent there by construction (symmetric degrade).
- **Threading.** RR is per-packet, so it attaches to the sample: add an **optional** `rrIntervalsMs`
  to `HRSample` (engine) and `HRPoint` (persisted) — additive/Optional, no migration (old `HRPoint`
  blobs decode with `nil`). `WorkoutHRStats.points(from:)` copies it through.
- **Rest windows already exist.** Kilter: `KilterSessionStats.TimelineItem.restBefore` is the gap
  `[prevClimbEnd, thisClimbStart]`. WorkoutTracker: `setEfforts` already derives a per-set work window;
  the rest is `[prevSetCompletedAt, thisWorkStart]`. HRV reads the RR that fell in that rest window.
- HRV needs enough beats: require ≥ a small minimum of usable RR intervals, and filter physiologically
  implausible RR (outside ~[300, 2000] ms) so a dropped/merged beat can't blow up RMSSD.

## Approach

- **Engine (platform-free):** `HRSample` gains `rrIntervalsMs: [Double]?` (defaulted → no call-site
  churn). New `HRVMetrics` helper (sibling to `ClimbEffort`): pure RMSSD/SDNN/pNN50 over an RR array,
  plus `make(from:start:end:)` that gathers RR from samples in `[start, end]`. `.empty` (all-nil) when
  under the minimum — the state the UI hides on.
- **Capture (shared `BLEHeartRateMetricsSource`):** `parseMeasurement` also decodes RR (skipping the
  energy field); `HRMeasurement` gains `rrIntervalsMs`. A pure `rrTrusted(modelNumber:deviceName:)`
  classifier (default-deny; optical blacklist checked before the chest-strap whitelist so "TICKR FIT"
  ≠ "TICKR"). `ingest(…rrIntervalsMs:)` stores RR **only when trusted**. Connect reads `0x180A` model
  number to refine trust; name-based trust works immediately. Both apps get RR for free (shared source).
- **Surface (shared view):** `HRVBadge` (sibling to `HREffortBadge`) renders RMSSD + a recovery-quality
  tint, nothing when `.empty`. `KilterSessionStats.TimelineItem` gains the rest-HRV; a new
  `WorkoutHRStats.setRestHRV(…)` returns per-set rest HRV. Both summary surfaces show the badge.

## Output

- New: `ios/HighlightEngine/Sources/HighlightEngine/HRVMetrics.swift` (+ engine tests);
  `ios/App/Snappet/Features/WorkoutTracker/HRVBadge.swift` (shared HRV badge).
- Edits: `Model.swift` (`HRSample.rrIntervalsMs`), `WorkoutModels.swift` (`HRPoint.rrIntervalsMs`),
  `WorkoutHRStats.swift` (`points` copy-through + `setRestHRV`), `BLEHeartRateMetricsSource.swift`
  (RR parse + `rrTrusted` + `ingest` + `0x180A` read + notification handler), `KilterSessionStats.swift`
  (per-climb rest HRV on `TimelineItem`), `KilterSessionDetailView.swift` + `SessionDetailView.swift`
  (render `HRVBadge`).
- Tests: `HRVMetricsTests` (engine: known-RR RMSSD/SDNN/pNN50, the min-intervals gate, outlier filter),
  `MetricsSourceTests` (RR decode incl. energy-skip + malformed bounds; `rrTrusted` whitelist/blacklist/
  default-deny; `ingest` drops RR when untrusted), `KilterSessionStatsTests` + `WorkoutHRStatsTests`
  (per-rest HRV computed over the rest window; absent for HR-less / RR-less sessions).

## Acceptance criteria

- [ ] `parseMeasurement` decodes RR (converting 1/1024 s → ms), correctly skipping the energy field
      when present, and never reads past a short buffer.
- [ ] `rrTrusted` defaults to **false** for unknown/empty; trusts a chest-strap name/model; rejects
      optical sensors (and "TICKR FIT" specifically, before the "TICKR" match).
- [ ] `ingest` stores RR only when trusted; the Apple-Watch path and untrusted bands carry no RR.
- [ ] `HRVMetrics.make` returns correct RMSSD/SDNN/pNN50 on a known RR array, `.empty` under the
      minimum, and ignores out-of-range RR.
- [ ] Per-rest HRV is shown between climbs (Kilter) **and** between sets (WorkoutTracker) via the
      shared `HRVBadge`; HR-less / RR-less / no-trust sessions render exactly as Phase 2 (badge hidden).
- [ ] Engine changes ship with passing `swift test`.
- [ ] App changes type-check (Swift 6, 0 warnings) and the full XCTest suite passes on the simulator.
- [ ] No platform imports added to `HighlightEngine`.
- [ ] `decisions.md` + the knowledge graph updated.

## Constraints

- On-device only; no cloud, no vendor SDK; no new HR characteristic (RR rides `0x2A37`). `0x180A` is a
  read-only standard GATT service, not a vendor API.
- State verification honestly: real RR capture + the trust gate firing on a specific strap need a
  physical chest strap (no BLE/RR in the simulator); the RR byte decode, the trust classifier, the HRV
  math, and the per-rest windowing are all fully unit-tested off-device.

## Test plan

1. `cd ios/HighlightEngine && swift test` (HRV math + min-interval gate + outlier filter).
2. `cd ios/App && xcodegen generate && xcodebuild test -scheme Snappet -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`.
3. Device follow-up (with a real chest strap, e.g. Polar H10): confirm RR is captured + trusted, a
   plausible RMSSD shows on the rest rows, and that an optical band shows no HRV.
