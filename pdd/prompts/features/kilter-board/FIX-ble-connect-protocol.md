# Prompt: Kilter Board — fix BLE connect addressing + packet framing

**File**: pdd/prompts/features/kilter-board/FIX-ble-connect-protocol.md
**Created**: 2026-06-06
**Project type**: Native iOS + Android bugfix (Swift / Kotlin) — code lands in this repo.
**Chain**: Kilter Board mini-app (#35) → board-illumination hardening
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`,
`pdd/prompts/features/kilter-board/RESEARCH.md`

## Goal

A board owner taps **Connect** and the app sticks on *"Connected, but the board didn't respond. Try
again."* (the in-app banner). The link establishes but illumination never works. Root-cause: the BLE
connect path addresses the **wrong** GATT service/characteristic, and the illumination packet framing
doesn't match the Aurora wire format — so the write characteristic is never discovered and, even if it
were, the packets would be malformed. Fix both so the controller is correct against the canonical
community reverse-engineering, ready for the (still-pending) on-hardware validation.

## Context the implementer needs

The Aurora/Kilter protocol (per `1-max-1/fake_kilter_board`):

- The board **advertises** service `4488B571-7806-4DF6-BCFF-A2897E4953FF`, but illumination data is
  **written** to the **Nordic UART** GATT service `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`,
  characteristic `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`. The current code discovers on the *advertised*
  UUID and writes to a non-existent `4488B572-…` characteristic — so discovery finds nothing and the
  watchdog fails with the reported banner.
- These write UUIDs are **shared across the whole Aurora family** (Kilter / Tension / Grasshopper /
  Decoy / So iLL) — there is no per-board UUID variation. The only axis that varies is the *payload*
  "API level" (2 = older, 3 = current); this fix keeps the existing **API level 3** encoder and leaves
  level 2 out of scope.
- Packet frame must be `[0x01, length, checksum, 0x02, <marker + holds…>, 0x03]`. The current `wrap()`
  omits the `0x02` data marker and uses `0x02` (not `0x03`) as the terminator. With the correct
  6-byte overhead, the per-packet hold chunk must be ≤ 4 holds (`bodyChunk = 12`) to stay within the
  20-byte BLE ATT payload.

Touched files: `KilterBoardController.{swift,kt}` (UUIDs + discovery), `KilterProtocol.{swift,kt}`
(framing + chunk size). Pure encoder is unit-testable off-device; the live radio path is not.

## Approach

- Split the single `serviceUUID` constant into `advertisedServiceUUID` (4488B571 — scan/recognise +
  `retrieveConnectedPeripherals` / Android advertised match) and `gattServiceUUID` (6E400001) +
  `writeUUID` (6E400002 — discover characteristics + write). `isLikelyBoard` keeps matching the
  advertised UUID/name.
- Fix `wrap()` to `[0x01, len, checksum, 0x02, payload, 0x03]` and set `bodyChunk = 12` on both
  platforms; keep the hold encoding (uint16-LE position + R3G3B2) and markers 82/81/83/84.
- Mirror the change exactly across iOS and Android so the two stay byte-identical.

## Output

- `ios/App/Snappet/Features/Kilter/KilterBoardController.swift`,
  `android/.../feature/kilter/KilterBoardController.kt` — corrected UUID constants + discovery/lookup.
- `ios/App/Snappet/Features/Kilter/KilterProtocol.swift`,
  `android/.../feature/kilter/KilterProtocol.kt` — corrected framing + `bodyChunk`/`BODY_CHUNK`.
- `ios/App/SnappetTests/KilterProtocolTests.swift`,
  `android/.../test/.../feature/kilter/KilterProtocolTest.kt` — pure encoder vectors.
- `docs/knowledge-graph/data.js` (`kilter-board-ctrl` desc) + `pdd/context/decisions.md` updated.

## Acceptance criteria

- [x] Connect path discovers + writes on the Nordic UART service/characteristic (6E400001 / 6E400002),
      not the advertised 4488B571 / a non-existent 4488B572.
- [x] Framed packets are `[0x01, len, cksum, 0x02, marker+holds, 0x03]`, ≤ 20 bytes per write.
- [x] New pure encoder tests pin the exact bytes and pass off-device on both platforms.
- [x] `decisions.md` + knowledge graph updated in the same change.
- [ ] **Device-pending**: illumination confirmed on a real board (the repo's hardware rule — not
      reported as working until then).

## Constraints

- On-device only; BLE is local radio, no backend/network/accounts.
- Keep iOS and Android byte-identical; keep the encoder pure so it's testable without a simulator/device.
- State verification honestly: type-check / unit tests ≠ a real board lighting up.

## Test plan

1. iOS: `xcodebuild test -scheme Snappet …` runs `KilterProtocolTests` (+ existing
   `KilterBoardMatchTests`) on the simulator; Android: `./gradlew testDebugUnitTest` runs
   `KilterProtocolTest`. Both assert the corrected framed bytes.
2. On-hardware (pending): tap Connect near a powered board, confirm it reaches Connected and a selected
   climb lights the correct holds/colors.
