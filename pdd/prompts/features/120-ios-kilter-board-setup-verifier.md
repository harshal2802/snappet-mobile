# Prompt: Kilter — "Set up this board" guided layout/size verifier

**File**: pdd/prompts/features/120-ios-kilter-board-setup-verifier.md
**Created**: 2026-07-11
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Kilter improvement initiative (epic #199) → P1 board-recognition follow-up.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

A first-time climber standing at an unfamiliar Kilter board doesn't know its **layout + size**, and the
wrong size (or layout) lights shifted / wrong holds. Today the only fix is a hidden "Wrong holds lighting
up?" link that exposes a board-size picker — the user has to *discover* it and guess. This builds a
proactive, guided **"Set up this board"** verifier: on the first light against a board the app hasn't yet
confirmed, a sheet lets the user pick a layout + size, light it on the wall, and cycle until the LEDs land
right — then confirm. The confirmed choice is remembered against **this physical board** (`KilterBoardMemory`,
keyed on the BLE identifier) so it auto-restores on every future connect and never asks again.

## Context the implementer needs

- **A catalog climb's layout is intrinsic.** `KilterCatalog.holds(for: climb, sizeId:)` resolves LED
  positions using `climb.layoutId`; you can re-light the *same climb* across **sizes** (same layout), but a
  layout-A climb has no placements in layout B — so you cannot "light this climb under layout B". Cycling
  **layouts** therefore has to light a layout-agnostic **calibration pattern** (recognizable reference
  holds), while cycling **sizes** within the climb's own layout lights the real climb. This is the one
  non-obvious constraint the design turns on.
- Lighting goes through `KilterBoardController.illuminate([KilterHold])` (`Features/Kilter/KilterBoardController.swift:217`).
  The controller is platform-pure and only sees `[KilterHold]`; layout/size are baked into the holds upstream.
- `KilterBoardMemory` (`Services/KilterBoardMemory.swift`) already remembers per-board `layoutId` +
  `productSizeId` + angle history, keyed on `CBPeripheral.identifier` (+ serial + coarse place), and
  `KilterRootView.recognizeBoard`/`applyRestore` already auto-restore a recalled board on connect. **But**
  `recognizeBoard` calls `remember(...)` on *every* connect with the current global defaults — so a board is
  "remembered" the instant it first connects, which is not the same as the user having *confirmed* its
  layout. We need a distinct "verified" signal so the prompt fires exactly once, on the first light before
  the user has confirmed.
- The lighting UI is `KilterClimbDetailView` — the board pill (`boardPillTapped`, `:272`) and the primary
  "Light up this climb" button (`lightAndCapture`, `:912`). The hidden escape hatch is `wrongHoldsControl`
  (`:650`).
- `KilterBoardView(geometry:holds:)` renders holds over the board grid — reuse it for the sheet preview.

## Approach

1. **Pure logic (unit-tested, no device)** — `Features/Kilter/KilterBoardSetup.swift`:
   - `KilterBoardSetup.target(climbLayoutId:chosenLayoutId:chosenSizeId:) -> LightTarget` where
     `LightTarget = .climb(sizeId:) | .calibration(layoutId:sizeId:)`. Returns `.climb` only when the chosen
     layout equals the climb's own layout; otherwise `.calibration`.
   - `KilterCalibration.pick(from holes:) -> [hole]` — given the wired holes `(holeId,x,y,led)` for a board,
     pick the hole nearest each of the **4 corners + center** of the extent, deduped by holeId (a tiny board
     may collapse two targets to one hole). Pure geometry, fully testable.

2. **Catalog** — `KilterCatalog.calibrationHolds(forLayout:sizeId:) -> [KilterHold]`: gather the size's wired
   holes + board coords, run `KilterCalibration.pick`, normalize to the same render extent `holds(for:)`
   uses, and stamp a distinctive calibration color + real `ledPosition`.

3. **Controller** — expose `var connectedIdentifier: UUID?` (the connected board's stable identifier) so the
   detail view can bind a confirmed choice to the right board without waiting for the one-shot
   `onBoardRecognized`.

4. **Memory** — add `verifiedSetup: Bool?` to `RememberedBoard` (optional so old stored JSON still decodes)
   with `isVerified`; add `confirmSetup(identifier:layoutId:productSizeId:label:)` that sets layout/size and
   flips verified true; leave `remember(...)` preserving the flag.

5. **UI** — `Features/Kilter/KilterBoardSetupSheet.swift`: layout + size pickers, a `KilterBoardView`
   preview, "Light on board" (re-lights live on every change), "This looks right" (confirm), calibration
   hint when off the climb's layout. Present it from `KilterClimbDetailView` automatically when the user
   lights on a connected board where `boardMemory.recall(id)?.isVerified != true`, and from an always-present
   "Set up this board" control (replacing the buried "Wrong holds?" link, which folds into the sheet).
   Confirm writes memory via `confirmSetup`, sets the active `kilter.layout` / `kilter.productSizeId`, and —
   when the confirmed layout matches the open climb — lights the real climb.

## Output

- `Features/Kilter/KilterBoardSetup.swift` — pure `KilterBoardSetup` + `KilterCalibration`.
- `Features/Kilter/KilterBoardSetupSheet.swift` — the sheet.
- `KilterCatalog.calibrationHolds(...)`, `KilterBoardController.connectedIdentifier`,
  `KilterBoardMemory` (`verifiedSetup` + `confirmSetup`), `KilterClimbDetailView` wiring.
- `SnappetTests/KilterBoardSetupTests.swift` — target decision + corner/center pick + dedup edges.
- `docs/knowledge-graph/data.js` node + edge; `pdd/context/decisions.md` entry.

## Follow-up (same day): trigger from the landing-page Connect flow + filter the catalog

Extend the trigger so it also fires when the climber taps **Connect** on the Kilter landing page (not only on
first light in a climb). `KilterRootView.recognizeBoard` branches on `isVerified`: a verified board restores
layout/size + raises the existing angle-confirm ribbon; an **unverified** board raises the setup verifier on
connect (no open climb ⇒ calibration mode). Confirming there (`confirmBoardSetup`) both persists via
`confirmSetup` and sets the active `kilter.layout` / `kilter.productSizeId` — and because `layoutId` is part
of the browse `filterKey`, **the confirmed board+layout immediately filters the shown climbs**. The
detail-view light-time trigger remains as the fallback (prompt only when the board+layout isn't known yet);
both gate on the same `isVerified`.

## Acceptance criteria

- [ ] Tapping Connect on the landing page for an unverified board opens the verifier on connect; confirming
      filters the browse list to that layout.
- [ ] First light on a connected, not-yet-verified board opens the setup sheet instead of lighting blindly.
- [ ] Changing layout/size in the sheet re-lights immediately; wrong layout lights the corner+center
      calibration pattern, the climb's own layout lights the real climb.
- [ ] "This looks right" persists layout+size to `KilterBoardMemory` (verified), and a later connect restores
      it with no prompt.
- [ ] An always-available "Set up this board" control re-opens the verifier.
- [ ] Old remembered boards (no `verifiedSetup` key) still decode (treated as unverified → prompt once).
- [ ] Pure logic ships with passing tests; app type-checks (Swift 6, 0 warnings).
- [ ] `decisions.md` + knowledge graph updated.

## Constraints

- On-device only; no backend/network. `KilterBoardController` stays platform-pure ([KilterHold] in).
- BLE is hardware-dependent: type-check + unit tests verify the pure logic and the sheet builds; the actual
  "correct LEDs light on the wall" leg needs a real Kilter board (device-pending, like the rest of P1).

## Test plan

1. `xcodebuild test -scheme Snappet -only-testing:SnappetTests/KilterBoardSetupTests` — decision + pick.
2. Full `build-for-testing` on iPhone 17 Pro (Swift 6, 0 warnings).
3. Device (owed, needs a board): first light → sheet → cycle layout/size → confirm → reconnect restores.
