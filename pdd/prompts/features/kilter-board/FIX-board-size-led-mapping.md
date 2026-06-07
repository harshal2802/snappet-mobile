# Prompt: Kilter Board — map LEDs by the user's board size + send led_color

**File**: pdd/prompts/features/kilter-board/FIX-board-size-led-mapping.md
**Created**: 2026-06-06
**Project type**: Native iOS + Android bugfix (Swift / Kotlin) — code lands in this repo.
**Chain**: Kilter Board mini-app (#35) → board-illumination hardening → [FIX-ble-connect-protocol],
[FEAT-dual-protocol-toggle]
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`,
`pdd/prompts/features/kilter-board/RESEARCH.md`

## Goal

On a **real board**, after the connect/framing fix, the board lit up but showed the **wrong holds**
(the owner reported them **shifted/offset**). Make the app light the **correct** holds by addressing the
LEDs for the **user's actual board size**, and send the role's **LED** color rather than the on-screen
color.

## Context the implementer needs

The Aurora catalog models a layout in **many physical sizes** (`product_sizes`), and the `leds` table is
keyed by `(product_size_id, hole_id) → position`. **The same hole has a different `position` on each
size.** Real data for Kilter Original (layout 1): sizes 7×10 (225 LEDs), 8×12 Home (311), 12×12 w/ &
w/o kickboard (476/441), 12×14 Commercial (527), 16×12 Super Wide (641). Homewall (layout 8) adds
per-dimension × LED-kit variants.

- **Bug 1 (wrong/shifted holds)**: `ledPositions` used `MIN(product_size_id)` for the layout — i.e. a
  fixed, usually-wrong size (Original → size 7, the 12×14 Commercial). A taller assumed board shifts
  every LED address → the reported shift. The board can't report its size and the address space is
  size-specific, so the app must let the user pick it.
- **Bug 2 (start color)**: holds used `placement_roles.screen_color` for the board. The physical LED
  wants `led_color`; they differ for `start` (LED `00FF00` vs screen `00DD00`). Keep `screen_color` for
  the UI render; send `led_color` to the board.

Touched files: `KilterCatalog.{swift,kt}` (sizes + size-keyed LED map + led_color), `KilterModels`/
`KilterHold` (`ledColorHex`, `KilterBoardSize`), `KilterBoardController.{swift,kt}` (send `ledColorHex`),
`KilterSettings*`/`KilterClimbDetailView`/`KilterDetailScreen` (board-size preference + pickers),
fixtures (`KilterCatalogFixture.{swift,kt}` + `tools/kilter/build_test_fixture.py` + the checked-in
`kilter-fixture.sqlite3`).

## Approach

- `KilterCatalog.sizes(forLayout:)` → a layout's `product_sizes` (id, name, description), with a
  defensive fallback to bare ids if `product_sizes` is absent. `defaultSizeId(forLayout:)` = smallest.
- `holds(for:sizeId:)` resolves LEDs via `ledPositions(forSize:)`; an unset/invalid `sizeId` falls back
  to the layout's smallest (preserves prior behavior, never crashes).
- `KilterHold.ledColorHex` from `led_color`; controller `send` uses it. UI keeps `colorHex`.
- Persist `kilter.productSizeId` (AppStorage / SharedPreferences). Pick it in Settings (next to
  Board/Angle) and in the inline **"Wrong holds?"** control (size first, then the Standard/Legacy
  dialect). A change re-maps LEDs and re-lights the current climb instantly; seed to the layout default,
  reset when the layout changes.
- Mirror iOS and Android exactly. Extend the synthetic fixture to two sizes (size 2 offset by 1000) and
  a `start` whose `led_color` ≠ `screen_color`, so size selection + led_color are unit-testable.

## Output

- `ios/App/Snappet/Features/Kilter/KilterCatalog.swift`, `android/.../feature/kilter/KilterCatalog.kt`
  — `sizes`/`defaultSizeId`/`effectiveSizeId`/size-keyed `ledPositions`, `roleLedColor`, `holds(sizeId:)`.
- `KilterModels.swift` / `KilterCatalog.kt` — `KilterHold.ledColorHex`, `KilterBoardSize`.
- `KilterBoardController.{swift,kt}` — send `ledColorHex`.
- `KilterSettingsView.swift` / `KilterSettingsScreen.kt`, `KilterClimbDetailView.swift` /
  `KilterDetailScreen.kt` — board-size pickers + persistence + re-light on change.
- `KilterCatalogFixture.{swift,kt}`, `tools/kilter/build_test_fixture.py`, `kilter-fixture.sqlite3` —
  2-size fixture; `KilterCatalogStoreTests.swift` / `KilterCatalogStoreTest.kt` — size + led_color tests.
- `docs/knowledge-graph/data.js` (`kilter-catalog-db`, `kilter-board-ctrl`) + `decisions.md` updated.

## Acceptance criteria

- [x] LED address comes from the **selected** `product_size`, not `MIN(...)`; wrong/unset size falls
      back to the layout's smallest, deterministically.
- [x] Board payload uses `led_color`; the on-screen render keeps `screen_color`.
- [x] A persisted board-size preference is selectable in Settings and inline on the climb screen, and
      re-lights instantly on change.
- [x] 2-size fixture + tests prove `holds(sizeId:)` picks the right size's positions and uses `led_color`
      (off-device on both platforms); three fixtures kept in sync.
- [x] `decisions.md` + knowledge graph updated in the same change.
- [ ] **Device-pending**: the **correct** holds light on the real board with the size set (the repo's
      hardware rule — re-test by the owner).

## Constraints

- On-device only; no backend/network. Keep iOS and Android byte-identical and the catalog logic pure.
- Don't change the wire format — this is the LED *address* + *color source*, not the packet encoding.
- State verification honestly: unit tests proving size selection ≠ the wall lighting the right holds.

## Test plan

1. iOS: `xcodebuild test … -only-testing:SnappetTests` runs `testBoardSizeSelectsLEDMapAndUsesLedColor`.
   Android: `./gradlew :app:assembleDebugAndroidTest` compiles the instrumented mirror
   (`boardSizeSelectsLedMapAndUsesLedColor`), run on an emulator/device when available.
2. On-hardware (pending): set Board size to the owner's board, tap Connect, light a climb, confirm the
   **correct** holds illuminate; if still off, try Legacy.
