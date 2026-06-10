# Prompt: On-device climb generator — ONNX transformer + ✨ Generate tab (PR 2 of 3)

**File**: pdd/prompts/features/31-ios-onnx-climb-generator.md
**Created**: 2026-06-09
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: "Create new climb" feature → PR 2 (the generator). Stacked on PR 1 (`30-…`).
**Source**: User request — integrate the board-explorer's generator model so the app can auto-create climbs.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

PR 1 made climbs *authorable* (manual editor) and handled identity + dedup + persistence. This PR wires
the actual board-explorer **generator** so the app can design a climb from a board size / angle / target
grade — the on-device transformer, running locally, no accounts, no server.

## Context the implementer needs (reverse-engineered from the live web bundle)

- The explorer runs a quantized ONNX transformer (`model.q.onnx`, ~9 MB int8) + `meta.json`. Input:
  int64 `tokens` `[1, block]` (the sequence **left-packed**, the rest `pad`); output: `logits`
  `[1, block, vocab]` — read at the **last real token's** position.
- Vocabulary (`itos`): `PAD/BOS/EOS`, `SIZE_*`, `ANGLE_*`, `GRADE_*`, `MATCH/NOMATCH`, then
  `HOLD_<placementId>_<roleId>` tokens. Prompt = `[BOS, SIZE_<id>, ANGLE_<a>, GRADE_<g>, MATCH|NOMATCH]`.
- Decode (`at`): mask candidates to `sizeMasks[sizeId]`, drop any placement already used, gate `EOS` on
  `minHolds`(4) + a start + a finish, temperature-softmax sample (temp 0.9). After the loop, **repair**
  any missing start/finish (lowest-id legal hold). Grade = a linear model (`st`) from `meta.gradeModel`.
  `nt` runs best-of-N toward the target grade. Output is a standard `p<placement>r<role>` frames string.

## Approach

Keep the binary dependency at a thin edge; make the algorithm pure:
- **Dependency:** add `onnxruntime` (microsoft/onnxruntime-swift-package-manager) to `project.yml`;
  import `OnnxRuntimeBindings` only in the adapter.
- **Pure core (no ONNX, unit-tested with a stub session):** `KilterGeneratorMeta` (Codable) +
  `KilterGeneratorModel` (prep maps); `KilterClimbGenerator` (the `at`/`rt`/`st`/`nt` port) behind a
  `KilterLogitsProviding` protocol.
- **Edge:** `KilterORTSession` (the only `import OnnxRuntimeBindings`) builds the int64 tensor + reads the
  last-position logits; `KilterGeneratorRuntime` is an `actor` that owns the non-Sendable session and
  returns the Sendable result off the main actor.
- **Assets:** `KilterGeneratorAssets` lazy-downloads `manifest.json` → model + meta from
  `…/Snappet/climb-generator/` into Application Support (mirrors `HostedCatalogClient`), cached.
- **UI:** add a Manual / ✨ Generate segment to `CreateClimbView`; Generate downloads the model once, then
  pickers (size/angle/grade/no-match) → preview (existing `KilterBoardView`) + predicted grade →
  "Use this climb" saves through PR 1's shared dedup + content-uuid path (`source = "generated"`).

## Output

- New: `KilterGeneratorMeta.swift`, `KilterClimbGenerator.swift`, `KilterGeneratorAssets.swift`,
  `KilterGeneratorRuntime.swift`, `SnappetTests/KilterGeneratorTests.swift`.
- Changed: `project.yml` (dependency), `CreateClimbView.swift` (Generate tab + shared save),
  `docs/knowledge-graph/data.js`.

## Acceptance criteria

- [x] App + tests build with ONNX Runtime linked (Swift 6, 0 new warnings).
- [x] The decode loop is unit-tested with a stub session: deterministic output, always start+finish,
      repair, no duplicate placement, mask honored, grade-model regression — no device, no model file.
- [x] Generated climbs save through PR 1's dedup + deterministic-uuid path.
- [x] No platform/ONNX import leaks into the pure core or `HighlightEngine`.

## Constraints

- On-device only; the model + meta are user-hosted (same posture as the catalog, #42). Nothing uploaded.

## Test plan

1. `xcodebuild test -only-testing:SnappetTests/KilterGeneratorTests` (pure decode + grade + meta).
2. Full `SnappetTests` green.
3. Device: ✨ Generate → download model once → generate for a size/angle/grade → preview matches the
   predicted grade band → "Use this climb" saves + dedupes. Compare a few generated frames against the
   web explorer for the same conditions to confirm parity. (Real-board BLE light = PR 3 / device.)
