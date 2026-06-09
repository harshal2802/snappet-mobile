# Prompt: Create a new climb — manual editor, content identity, duplicate guard (PR 1 of 3)

**File**: pdd/prompts/features/30-ios-create-climb-identity-dedup.md
**Created**: 2026-06-09
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: "Create new climb" feature → PR 1 (foundation). PR 2 adds the on-device generator; PR 3 polish.
**Source**: User request — integrate the board-explorer generator + a manual hold editor, with
duplicate validation against the downloaded dataset and a cross-device-stable climb uuid.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

The Kilter module is read-only — users browse/log/illuminate catalog climbs but can't author their own.
This PR adds **authoring**: a manual hold-by-hold editor that produces a real climb, validates it against
the entire downloaded dataset (and previously-authored climbs) for duplicates, assigns a **deterministic,
content-derived uuid** so the same climb authored on two devices is recognizably the same, and persists it
so it flows through the existing detail / render / BLE-illumination / logging path. It is the foundation
the on-device generator (PR 2) saves through.

## Context the implementer needs

- The board-explorer's generator (researched from the live bundle) emits a standard Kilter `frames`
  string (`p<placementId>r<roleId>`) — the same encoding `KilterCatalog.parseFrames` already decodes and
  `KilterCatalog.holds(for:sizeId:)` already renders. **Reuse that**: shape an authored climb as a
  `KilterClimb` and the whole pipeline applies unchanged.
- The user asked for a "time-based uuid that's the same across devices for the same climb." A literal
  time-based UUID can't be cross-device-equal (it embeds the clock + a node). Only a **content hash** can.
  So identity = UUIDv5 over the canonical `(layout, sorted-holds)`; creation time is a separate field.
- Catalog climbs keep Aurora's random uuids, so catalog dedup must compare **canonical frames**, not our
  uuid; created climbs dedup directly by the content uuid.

## Approach

Pure, platform-free core (unit-tested without a device):
- `KilterClimbIdentity` — `canonicalFrames`, `canonicalKey(layoutId:frames:)`, `uuid(forLayout:frames:)`
  (UUIDv5 via CryptoKit `Insecure.SHA1`, fixed namespace).
- `KilterCreatedClimb` (`@Model`, registered in `SnappetSchema.models`) + `asClimb` adapter; author-role
  vocabulary (`KilterAuthorRole`), `kilterFrames(from:)`, `kilterValidate(_:)`.
- `KilterDuplicateChecker` — layout-scoped index over catalog rows + created climbs; pure `init`/`find`
  plus a `@MainActor build(...)` that reads the installed catalog.

Catalog reads (additive, `KilterCatalog`): `placeableHolds(forLayout:sizeId:)` (tappable targets, same
render extent as `holds`), `boardBounds(forPlacementIds:)` (the climb's `edge_*`), `climbFramesForDedup`.

UI: `KilterEditableBoardView` (interactive Canvas, tap-to-cycle role); `CreateClimbView` (the sheet —
layout/size/angle/no-match + the editor + Save → validate → dedup alert → persist). Wire into
`KilterRootView` (More ▸ Create climb; a **Mine** browse filter) and `KilterClimbDetailView` (resolve a
created climb by uuid + synthesize a single-angle stat).

## Output

- New: `KilterClimbIdentity.swift`, `KilterCreatedClimb.swift`, `KilterDuplicateChecker.swift`,
  `KilterEditableBoardView.swift`, `CreateClimbView.swift`, `SnappetTests/KilterCreateClimbTests.swift`.
- Changed: `KilterCatalog.swift` (+3 reads), `KilterModels.swift` (`KilterPlaceableHold`),
  `KilterRootView.swift` (entry + Mine), `KilterClimbDetailView.swift` (created-climb resolver),
  `SnappetCore.swift` (schema), `docs/knowledge-graph/data.js`.

## Acceptance criteria

- [x] Same holds (any order) → same uuid; golden vector pinned; layout-scoped; v5 + RFC variant bits.
- [x] Saving validates against the catalog + created climbs and offers Open / Save anyway / Keep editing.
- [x] A created climb appears under **Mine**, opens in the normal detail screen, renders + illuminates.
- [x] App changes type-check against the iOS 18 SDK (Swift 6); new pure logic covered by passing tests.
- [x] No platform imports added to `HighlightEngine` (untouched).
- [x] `decisions.md` updated (content-uuid-not-time-uuid; reuse `KilterClimb` adapter).

## Constraints

- On-device only; no backend/network/accounts. The read-only catalog stays read-only (user data is
  SwiftData). Authoring requires an installed catalog (for geometry) — consistent with the whole module.

## Test plan

1. `xcodebuild test -only-testing:SnappetTests/KilterCreateClimbTests` — identity determinism + golden
   vector, frames canonicalization, validation floor, role cycling, duplicate hit/miss/scoping.
2. Full `SnappetTests` green (schema migration + view edits don't regress).
3. Device (when at a board): create a climb → Save → it shows under Mine → opens, renders, BLE-lights;
   re-creating the same holds is caught as a duplicate.
