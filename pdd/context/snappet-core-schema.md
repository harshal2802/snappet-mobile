# Snappet Core — schema (iOS mirror)

**Last updated**: 2026-05-30
**Status**: v0 draft — **mirror, not source of truth.**
**Canonical source**: the web repo `harshal2802/Snappet` → `pdd/context/snappet-core-schema.md`
(schemaVersion is bumped *there* first, then propagated here). GitHub issue
[#60](https://github.com/harshal2802/Snappet/issues/60) §D is the rationale.

This file records how the canonical Snappet Core contract maps onto the iOS `HighlightEngine` value
types **as currently implemented**, so prompts can check drift without round-tripping to the web repo.
It is not exhaustive — see the canonical file for `Reel`, `DayLog`, the consent model, and versioning
rules not yet realized in code.

## Mapping: canonical contract → engine types (in `ios/HighlightEngine/Sources/HighlightEngine/Model.swift`)

| Canonical (TS) | iOS engine type | Notes / drift |
|---|---|---|
| `HrSample { t, bpm, wallClock? }` | `HRSample { t: Double, bpm: Double }` | engine omits `wallClock` (alignment handled in `PhotoLibraryService` before the engine sees offsets). |
| `Workout { activity, hrSeries, hrRestBpm?, hrMaxBpm?, … }` | `Workout { activity, duration, hr: [HRSample], restBpm?, maxBpm?, media: [MediaItem] }` | engine is offset-based (seconds from start), not ISO timestamps; `media` is pre-matched. No `id`/`schemaVersion`/`source` — those belong to the persistence layer (not yet built). |
| `activity` enum | `Activity { climbing, running, dance, strength, other }` | exact match. `Codable`. |
| `MediaItem { kind, localIdentifier, capturedAt, durationSec? }` | `MediaItem { id, kind, startOffset: Double, duration: Double }` | engine uses workout-relative `startOffset` (already TZ-resolved); `id` = `PHAsset.localIdentifier`. |
| `Highlight { kind, atSec, score, clipStartSec, clipEndSec, pinned? }` | `Highlight { id, mediaItemId, kind, atOffset, clipStart, clipEnd, score }` | offsets are on the **workout timeline**; `clipStartWithin/EndWithin(media)` convert to in-media. `pinned` **not yet** on the engine type — pin state lives in the view model's `removed`/kept sets for now (gap, see decisions). |
| `Reel { highlightIds[], style?, music?, exportedAssetId? }` | `ReelPlan { segments: [Segment], photoStill }` | engine emits a **plan** (platform-free segment list); the persisted `Reel` entity isn't built yet. No `style`/`music`. |
| `DayLog`, `ModuleGrant` (consent) | — | **not implemented** — Phase 3 (suite expansion). |

## Persistence (not yet built)

The engine is pure I/O-free value types. There is **no on-device store yet** (SQLite/Core Data) — the
only thing persisted is the feedback JSONL (`FeedbackStore`), which is training data, *not* a Snappet
Core record. When the store lands, it must read/write the canonical entity shapes (with `id`,
`schemaVersion`, ISO `createdAt/updatedAt`) and stamp `schemaVersion = 0`.

## When the schema changes

1. Change it in the **web repo** first; bump `schemaVersion`.
2. Update this mirror table.
3. Update the engine value types + any persistence to match; note it in `decisions.md`.
