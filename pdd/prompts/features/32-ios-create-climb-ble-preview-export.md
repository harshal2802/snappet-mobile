# Prompt: Create-a-climb polish — live BLE preview + frames export (PR 3 of 3)

**File**: pdd/prompts/features/32-ios-create-climb-ble-preview-export.md
**Created**: 2026-06-09
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: "Create new climb" feature → PR 3 (polish). Stacked on PR 2 (`31-…`).
**Source**: User request — finish the create-a-climb feature.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

PR 1 (manual editor + identity + dedup) and PR 2 (on-device generator) made climbs authorable. This PR
closes the loop with two pieces of polish: **see the climb you're building on the real board** as you
author/generate it (BLE), and **take the climb with you** as a portable frames string.

## Context the implementer needs

- `KilterBoardController.illuminate([KilterHold])` lights a connected board; `isConnected`/`state` gate it.
  `KilterRootView` already owns the shared `board` controller and presents `CreateClimbView` as a sheet.
- `KilterCatalog.holds(for:sizeId:)` turns a `{layout, frames}` into positioned holds — already used to
  render; reuse it to light a draft.
- A climb's `frames` (`p<placement>r<role>`) is the catalog's native storage *and* the board-explorer's
  "Copy frames" format — the natural portable artifact. `KilterShareView` is the existing share surface.

## Approach

- **Live BLE preview:** pass the shared `board` into `CreateClimbView`. Auto-light the draft on a
  connected board as holds change (`onChange(of: assignments)`) and after a generation; add an explicit
  "Light on board" row (hidden when no board is connected). Reuse `holds(for:)` + `illuminate`.
- **Frames export:** "Copy frames" buttons in both the manual board section and the Generate preview
  (canonical frames). In `KilterShareView`, add Copy/Share-frames so any climb — including an authored
  one — is portable as plain text (the QR/link path stays for catalog climbs).

## Output

- Changed: `CreateClimbView.swift` (board param, live-light, copy-frames, BLE row),
  `KilterRootView.swift` (pass `board`), `KilterShareView.swift` (frames copy/share),
  `docs/knowledge-graph/data.js`.

## Acceptance criteria

- [x] App + tests build (Swift 6, 0 new warnings); full `SnappetTests` green (467).
- [x] A connected board lights the draft as it's authored/generated; no board → the affordance is hidden.
- [x] Copy/Share frames produce the canonical `p…r…` string from both tabs and the share sheet.
- [x] No platform leakage into the pure core / `HighlightEngine`.

## Constraints

- On-device only. BLE is device-only (the simulator has no board) — verify lighting on hardware.

## Test plan

1. Full `SnappetTests` green (no regression; this PR is UI/BLE/clipboard — covered by build + existing
   suite, BLE/clipboard are device/runtime).
2. Device: connect a board → author/generate → the physical board follows the draft; Copy frames pastes
   the `p…r…` string; Share frames offers it as text.
