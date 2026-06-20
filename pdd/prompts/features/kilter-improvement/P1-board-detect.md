# Prompt: P1 — Auto-detect board (KilterBoardMemory + CoreLocation)

**File**: pdd/prompts/features/kilter-improvement/P1-board-detect.md
**Created**: 2026-06-19
**Project type**: Native iOS feature (Swift / SwiftUI + CoreBluetooth + CoreLocation).
**Chain**: PLAN.md → P1 (independent; can run in parallel with P0/P2)
**Source**: GitHub issue — Kilter Improvement P1
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Design**: `docs/ux-research/kilter-improvement/README.md` §4 (Flow 1) · wireframes `01c_arrival`, `01_autodetect`, `01b_remembered`

## Goal

Recognize a board **this phone has connected to before** and restore its layout + size automatically, with
a one-tap angle confirm — so the climber stops re-picking their board every visit. Option B: add a coarse,
on-device **CoreLocation** place match so the app can suggest the usual board **on arrival, before BLE
connects**, and disambiguate two boards at one gym. Fully on-device; the coarse place is never uploaded.

## Context the implementer needs

- **The constraint (do not fight it):** the Aurora/Kilter BLE advert carries no layout/size, and angle is
  never transmitted (see research-appendix §1). So this recognizes only boards already connected once; the
  first encounter with any board/place stays today's manual pick.
- The stable key already exists: `KilterBoardController.swift:329` writes `peripheral.identifier` to
  `kilter.lastBoardID`, and `beginConnect()` (`:115-126`) already re-adopts it via
  `retrievePeripherals(withIdentifiers:)`. The advertised local name is read at `:251-263` (`isLikelyBoard`)
  and currently discarded — its `#serial` token is a reinstall cross-check.
- The selection source of truth is three `@AppStorage` keys (`kilter.layout` / `kilter.productSizeId` /
  `kilter.angle`, `KilterRootView.swift:39-46`). Writes MUST route through
  `catalog.effectiveSizeId(forLayout:requested:)` (`KilterCatalog.swift:460-465`) + `syncBoardSize()`
  (`KilterRootView.swift:321-328`) so render + LED map stay consistent.
- **The template:** `BandMemory` + `BLEBands` (`Services/`) is a working, unit-tested remember-device +
  pure-auto-rules + suppress/forget store. Clone its shape.
- No CoreLocation today; `Info.plist` has only `NSBluetoothAlwaysUsageDescription`.

## Approach

- Add a pure **`KilterBoardMemory`** (`Services/`, `UserDefaults`-backed map, injectable like `BandMemory`):
  `identifier UUID → {layoutId, sizeId, angleHistory, label, serial?, coarsePlace?, lastSeen}` + pure rules
  (recall by identifier, serial cross-check fallback, most-frequent-angle, forget/suppress).
- On a confirmed connect (the existing `didDiscoverCharacteristicsFor` / `onConnectionChange` hook), if the
  board is known: restore layout+size through `effectiveSizeId`, pre-select the usual angle, and show a
  **non-blocking `pulseGlassChrome` confirm ribbon** (angle stepper + coral "Got it"). Unknown board → no
  change; remember it on first successful connect.
- Add a thin **CoreLocation** service (when-in-use): on Kilter appear / significant-location, match a
  remembered `coarsePlace` (rounded lat/long bucket, stored raw, never reverse-geocoded, never networked);
  if matched, surface the **arrival suggestion** card (pre-connect). Degrade gracefully to BLE-only when
  location is denied. Add `NSLocationWhenInUseUsageDescription` to the generated Info.plist via
  `project.yml`.
- Add a **"Board detection"** + **"Remembered boards"** section to `KilterSettingsView` (location permission
  + "suggest on arrival" toggle; per-board rename / forget). Seed `SessionExercise.gym` default from the
  board label.

## Output

- `KilterBoardMemory.swift` (pure store + rules) + a small `KilterLocationMatcher` service.
- `KilterBoardController` changes: capture label/serial, fire a "recognized board" event with the memory.
- `KilterRootView` confirm-ribbon + arrival-suggestion surfaces; `KilterSettingsView` management section.
- `project.yml` Info.plist `NSLocationWhenInUseUsageDescription`.
- `KilterBoardMemoryTests.swift` in `SnappetTests`. `docs/knowledge-graph/data.js` node + edges.

## Acceptance criteria

- [ ] A previously-connected board restores layout+size (through `effectiveSizeId`) and pre-selects the
      most-frequent angle on connect; the confirm ribbon adjusts angle without overwriting silently.
- [ ] An unknown board changes nothing; it is remembered on first successful connect.
- [ ] At a remembered coarse place, an arrival suggestion appears pre-connect; with location denied, the
      feature degrades to BLE-only with no crash and no prompt loop.
- [ ] `KilterBoardMemoryTests` cover recall-by-identifier, serial cross-check, most-frequent-angle,
      forget/suppress, unknown→no-restore (pure, injectable `UserDefaults`, no CoreBluetooth/CoreLocation).
- [ ] `KilterBoardMatchTests` (`isLikelyBoard`) stay green. App type-checks (Swift 6, 0 warnings).
- [ ] `decisions.md` records the coarse-place privacy posture (on-device, never uploaded).

## Constraints

- On-device only; coarse place never leaves the phone. Suggestion-not-overwrite; angle always a confirm.
- Prefer `UserDefaults` (like `BandMemory`) over a new `@Model` to avoid the backup tax.
- BLE connect + CoreLocation legs are **device-pending** (MrRobot) — keep all new logic pure + unit-tested
  so the PR ships green without a board.

## Test plan

1. `KilterBoardMemoryTests` + `KilterBoardMatchTests` green; build-for-testing; UITest for the Settings
   management + confirm ribbon (mocked recognition).
2. Device pass (MrRobot): connect a real board twice → second visit auto-restores; arrive at a saved place
   → suggestion appears; deny location → BLE-only still works.
