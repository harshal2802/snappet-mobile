# Prompt: Kilter Board — connection reliability, swipe-to-browse, and QR climb sharing

**File**: pdd/prompts/features/kilter-board/UX-connection-swipe-qr.md
**Created**: 2026-06-05
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Kilter Board mini-app (#35) → Phase-2 UX pass (follows `kilter-board/RESEARCH.md`)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

A user reviewing the official Kilter app against ours surfaced three UX gaps. Close them:

1. **Connection.** Tapping *Connect board* doesn't connect, yet the board connects fine in the
   official Aurora/Kilter app — and once it has, our app still offers no way to light the current
   climb. Root cause: a board already connected at the **system** level (paired in Settings / held
   by the official app) stops advertising, so our scan-only path never re-discovers it and the flow
   never reaches `.connected` (so the "Light up" button never appears).
2. **Browsing a climb is a dead end.** From a climb you must tap Back to reach the next one. The
   user wants to **swipe left/right** to move through the climbs they were just browsing.
3. **No sharing.** Two people with the app can't hand a climb to each other. The user wants a
   **QR code** to share a climb and a **scanner** to open one — working offline (both phones ship
   the same catalog, so a `climb_uuid` resolves locally).

## Context the implementer needs

- `KilterBoardController` (CoreBluetooth, `@MainActor @Observable`) only ever
  `scanForPeripherals`. The GATT/wire format is community-sourced and **device-unverified** — keep
  that discipline; don't claim hardware-verified.
- `KilterClimbDetailView` is pushed via `KilterClimbRoute { uuid }` onto the App Library's shared
  `SuiteRouter` path. It owns no `NavigationStack`. `KilterRootView` builds the destination and has
  the ordered browse list (`items`) in hand at push time.
- On-device only: no network, no accounts. The scanner is camera-only.
- Decisions taken with the user: **in-app scanner only** (no `snappet://` URL scheme / `onOpenURL`
  cross-app deep link this pass); **auto-light + keep the manual button**.

## Approach

Respect the layering rule: the link **codec is a pure value type** (unit-tested, no UIKit/AV); camera
+ CoreImage live in view/platform files; BLE stays in the controller.

- **Connection** — add `retrieveConnectedPeripherals(withServices:)` ahead of scanning
  (`beginConnect()` → adopt a system-connected board directly, else `beginScan()`). Refactor the
  discover path to a shared `connect(to:)`.
- **Auto-light** — in the detail view, illuminate the on-screen holds when the board becomes
  connected (`.onChange(of: board.isConnected)`) and when the user swipes to a new climb (end of
  `load()`), keeping the manual "Light up this climb" button.
- **Swipe** — pass `siblings: [String]` (the ordered browse uuids) into the detail view; track a
  `currentUUID` `@State`, reload via `.task(id:)`, move with a horizontal `DragGesture` + chevrons +
  a "n / total" pill.
- **QR** — `KilterClimbLink` (pure codec for `snappet://kilter/climb/<uuid>?angle=<n>`),
  `KilterShareView` (CoreImage `qrCodeGenerator` + `ShareLink`), `KilterScannerView`
  (`AVCaptureMetadataOutput`, `.qr`) reachable from the catalog's More menu; a scanned link pushes
  `KilterClimbRoute`.

## Output

- `Features/Kilter/KilterDeepLink.swift` — `KilterClimbLink` value + URL codec (pure).
- `Features/Kilter/KilterShareView.swift` — QR + share sheet.
- `Features/Kilter/KilterScannerView.swift` — camera QR scanner sheet.
- Edits: `KilterBoardController.swift`, `KilterClimbDetailView.swift`, `KilterRootView.swift`.
- `Resources/Info.plist` — `NSCameraUsageDescription`.
- `SnappetTests/KilterDeepLinkTests.swift` — codec round-trip / reject cases.
- `docs/knowledge-graph/data.js` + `pdd/context/decisions.md` updated same change.

## Acceptance criteria

- [ ] A board already connected to the system (official app / Settings) is adopted by *Connect board*
      and the flow reaches `.connected`, revealing illumination — no scan required.
- [ ] When connected, the on-screen climb lights automatically on connect and on swipe; the manual
      "Light up this climb" button still works.
- [ ] From a climb you can swipe left/right (and tap chevrons) through the browsed list; a counter
      shows position.
- [ ] Share produces a scannable QR; scanning it on another phone opens the same climb; a non-Snappet
      code is rejected with a hint.
- [ ] App changes type-check (Swift 6, 0 warnings); pure codec covered by `swift`/XCTest.
- [ ] `decisions.md` + knowledge graph updated.

## Constraints

- On-device only; no backend/network/accounts.
- BLE stays **device-unverified** — the live radio path is authored on Linux/cloud and must be
  validated on a board + camera on a real device before being reported as working.

## Test plan

1. `KilterDeepLinkTests` round-trips `KilterClimbLink` and rejects foreign/garbage URLs (runs with no
   device).
2. Type-check / build on macOS (`xcodebuild`), then device-verify: adopt a Settings-connected board,
   swipe through climbs, share + scan between two phones, confirm LEDs follow the screen.
</content>
</invoke>
