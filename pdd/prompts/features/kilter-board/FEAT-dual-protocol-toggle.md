# Prompt: Kilter Board — dual Aurora payload dialects (Standard/Legacy) with a user toggle

**File**: pdd/prompts/features/kilter-board/FEAT-dual-protocol-toggle.md
**Created**: 2026-06-06
**Project type**: Native iOS + Android feature (Swift / Kotlin) — code lands in this repo.
**Chain**: Kilter Board mini-app (#35) → board-illumination hardening (follows FIX-ble-connect-protocol)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Aurora boards come in two payload "API levels" (2 = older controllers, 3 = current). The level is **not
advertised or negotiated** — the app must pick — and a wrong pick still *connects* but lights the
**wrong holds/colors**. Rather than guess and risk a broken wall, ship **both** encoders and let the
user switch, defaulting to Standard (level 3) so the common case stays frictionless. The switch must be
discoverable right where the problem appears and must re-light the wall instantly.

## Context the implementer needs

- Level 3: 3 bytes/hold (position uint16-LE + R3G3B2), markers 82/81/83/84. Level 2: 2 bytes/hold
  (byte0 = position low 8 bits; byte1 = R2G2B2 color in bits 7–2 OR the high 2 position bits in
  bits 1–0), markers 78/77/79/80. Outer frame `[0x01, len, cksum, 0x02, marker+holds, 0x03]` and the
  Nordic UART UUIDs are identical for both (see FIX-ble-connect-protocol).
- `bodyChunk = 12` works for both (multiple of 2 and 3; framed ≤ 20 bytes).
- The board controller is created once in the root (`KilterRootView` / `KilterRoot`) and shared with
  the climb-detail screen, which is where illumination is triggered.

## Approach

- `KilterProtocol` (both platforms): add `APILevel { v3, v2 }`; `messages(for:level:)` defaults to
  `.v3` (keeps existing callers/tests intact). Keep `colorByte` (v3) and add `colorBitsV2`. Branch the
  per-hold body + markers by level.
- Controller: store `apiLevel` + `lastHolds`; `setAPILevel(_:)` switches and re-sends `lastHolds` when
  connected (instant re-light); no-op when unchanged.
- Persist `kilter.apiLevel` (AppStorage / SharedPreferences). Surface it two ways: a **Settings**
  picker, and an inline **"Wrong holds lighting up?"** switch in the *connected* controls on the climb
  screen. The shared controller is the single sink; root (and Android detail) push the persisted value
  down so a change anywhere applies everywhere.

## Output

- `KilterProtocol.{swift,kt}` — `APILevel`, `colorBitsV2`, level-aware `body`/`messages`.
- `KilterBoardController.{swift,kt}` — `apiLevel`, `lastHolds`, `setAPILevel`, level-aware send.
- `KilterSettingsView.swift` / `KilterSettings.kt` + `KilterSettingsScreen.kt` — persistence + picker.
- `KilterClimbDetailView.swift` / `KilterDetailScreen.kt` — inline "wrong holds?" switch + board sync.
- `KilterRootView.swift` / `KilterRoot.kt` — push persisted level into the controller.
- `KilterProtocolTests.swift` / `KilterProtocolTest.kt` — exact v2 + v3 byte vectors.
- `docs/knowledge-graph/data.js` + `pdd/context/decisions.md` updated.

## Acceptance criteria

- [x] Both dialects encode to the documented bytes; level-2 packs the high position bits into the color
      byte; default stays v3 so the connect-fix tests are unchanged.
- [x] Switching the level while connected re-lights the current climb without re-navigating.
- [x] The preference persists and is reachable from Settings + an inline climb-screen affordance.
- [x] New pure encoder tests (both levels) pass off-device on both platforms.
- [x] `decisions.md` + knowledge graph updated in the same change.
- [ ] **Device-pending**: confirm on a real older (level-2) board that Legacy lights the correct holds.

## Constraints

- On-device only; BLE is local radio. Keep iOS/Android byte-identical and the encoder pure/testable.
- Default Standard — don't make the common user touch the setting. State verification honestly:
  unit tests ≠ a real board lighting up.

## Test plan

1. iOS `xcodebuild test` / Android `./gradlew testDebugUnitTest` run the v2+v3 encoder vectors.
2. On-hardware (pending): with an older board, connect → Light up → if wrong, tap "Wrong holds lighting
   up?" → Legacy → confirm the holds correct themselves live; reopen the app and confirm it persisted.
