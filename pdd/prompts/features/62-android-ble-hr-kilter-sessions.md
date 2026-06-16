# Prompt: Android BLE heart-rate capture + Kilter session enrichment

**File**: pdd/prompts/features/62-android-ble-hr-kilter-sessions.md
**Created**: 2026-06-15
**Project type**: Native Android feature (Kotlin / Compose / Room). Code lands in this repo.
**Chain**: Android Wave 3 → #92
**Source**: GitHub issue [#92](https://github.com/harshal2802/Snappet/issues/92)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Android recorded nothing about intensity, and a finished Kilter session was one non-tappable two-line
row. Port the standard BLE Heart Rate Profile capture (0x180D / 0x2A37 incl. RR + contact) from iOS,
persist a session HR summary, and add a session-detail screen (grade pyramid + per-climb timeline +
HR summary) driven by a pure, unit-tested stats core.

## Context the implementer needs

- iOS templates: `BLEHeartRateMetricsSource.swift` (0x2A37 parse + RR-trust default-deny),
  `KilterSessionStats.swift` (pure stats core), `HeartRateZone.swift`.
- `KilterBoardController` already has BLE scan/connect patterns to mirror.
- Room is at v4 with committed schemas (`exportSchema=true`, no destructive fallback).

## Approach

- Pure cores (JVM-tested): `hr/HRMeasurementParser` (0x2A37), `hr/HeartRateZone`, `hr/HRSeries`
  (HRStats time-in-zone + HRVMetrics), `KilterSessionStats`.
- Thin platform edge: `hr/BleHeartRateSource` (scan → connect → notify → ingest), `rrTrusted`
  default-deny gate is pure/tested. Live capture is **device-pending**.
- Schema **v4 → v5**: three NULLABLE HR columns on `kilter_session` via a self-contained
  `@AutoMigration` (additive, no SQL). Extend `MigrationBaselineTest`.
- UI: `KilterSessionDetailScreen`, `KilterHRPill`; history session rows become tappable; first log of
  a sitting auto-opens a manual session; live HR pill in the session banner.

## Output

New files under `feature/kilter/hr/`, `KilterSessionStats.kt`, `KilterSessionDetailScreen.kt`,
`KilterHRPill.kt`; edits to `KilterEntities` (columns + DAO), `SnappetDatabase` (v5 AutoMigration),
`KilterRoot`, `KilterDetailScreen`, `KilterHistoryScreen`, `KilterSessionManager`. Unit tests for the
parser, zones, stats, HRV, and the RR-trust gate.

## Acceptance criteria

- [x] 0x2A37 parse (8/16-bit, contact, energy-skip, RR→ms) unit-tested to iOS parity.
- [x] Sessions persist avg/max HR via a non-destructive migration (v5 schema committed + baseline test).
- [x] Tapping a session opens detail with grade breakdown + timeline; stats core unit-tested.
- [x] First log of the day without a session auto-opens one.
- [ ] Live bpm from a real chest strap in the banner/player — **device-pending**.
- [x] Knowledge graph + decisions.md updated.

## Constraints

On-device only. **Cross-wave note:** Wave 2 also bumps to v5 independently; keep this one column-set,
one AutoMigration, clearly commented so the reviewer renumbers to v6 at merge.

## Test plan

1. `./gradlew :app:testDebugUnitTest` — HR/stats/deep-link tests green.
2. `MigrationBaselineTest` (instrumented) validates v4→v5 — device-pending run.
