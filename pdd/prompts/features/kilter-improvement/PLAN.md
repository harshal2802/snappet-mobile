# PLAN — Kilter Improvement (your climbing record, made smart)

**Created**: 2026-06-19
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Source**: GitHub epic [Kilter Improvement] + child issues P0–P5.
**Design**: `docs/ux-research/kilter-improvement/README.md` + `wireframes.html` + `research-appendix.md`.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## The chain

One PDD prompt = one PR. Each ships its committed feature prompt, keeps `pdd/context/` true, records
decisions in `pdd/context/decisions.md` the same day, and updates `docs/knowledge-graph/data.js`
(nodes + edges for every new/changed surface) **in the same change**.

| Phase | Prompt | Depends on |
|-------|--------|------------|
| **P0** | [P0-all-time-stats-engine.md](./P0-all-time-stats-engine.md) — keystone pure `KilterAllTimeStats` aggregator + ascent-style tokens (no UI, no schema) | — |
| **P1** | [P1-board-detect.md](./P1-board-detect.md) — `KilterBoardMemory` (BLE id + serial) **+ CoreLocation** place-match + confirm ribbon | — |
| **P2** | [P2-your-climbs.md](./P2-your-climbs.md) — first-class Your Climbs thumbnail gallery | — |
| **P3** | [P3-analytics-dashboard.md](./P3-analytics-dashboard.md) — tiered Pulse Pro dashboard; delete inline History math | P0 |
| **P4** | [P4-session-history.md](./P4-session-history.md) — grouped/scoped/filterable history + heatmap + calendar + naming/notes/edit | P0 |
| **P5** | [P5-on-the-board.md](./P5-on-the-board.md) — lit-event capture + On the Board timeline + re-light rail | P0 |
| **H** | hardening + Android wave (device burn-in: BLE + CoreLocation + re-light; Android model + Room + backup mirror) | P1–P5 |

## Sequencing

- **P0 first** — it's the spine of P3 + P4 (and the per-bucket roll-ups + adaptive card facts).
- **P1, P2** are independent — can run in parallel after/with P0.
- **P3 before P4** — both touch `KilterHistoryView` (P3 deletes its inline math, P4 regroups it); sequence
  or coordinate to avoid a merge collision (mirror the merge-conflict map from prior parallel-batch work).
- **P5** depends only on P0.
- **Android** is its own multi-PR wave after each iOS phase.

## Standing constraints (every phase)

- On-device only: no backend, no network, no accounts. The coarse CoreLocation place is stored on-device
  and never uploaded.
- Pure cores stay platform-free value types, unit-tested in `SnappetTests` without a simulator
  (`KilterAllTimeStats`, `KilterBoardMemory` rules, all sort/filter/bucket helpers). `HighlightEngine`
  stays platform-free; CoreBluetooth/CoreLocation behind the Services edge.
- State verification honestly: type-check ≠ device run. The BLE + CoreLocation legs (P1) and live re-light
  (P5) are device-pending on MrRobot.
- Minimize new `@Model`s: P0–P3 add none; P4 adds additive optional fields; P5 adds one (`KilterLitEvent`).
  Any new `@Model`/field pays the `SnappetSchema` + `SnappetBackup` mirror tax with both test tripwires
  (`testCodecCoversEverySchemaModel` + the count) green.
