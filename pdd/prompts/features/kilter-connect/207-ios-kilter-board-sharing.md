# Prompt: Don't hog a shared Kilter board (prompt 207)

**File**: pdd/prompts/features/kilter-connect/207-ios-kilter-board-sharing.md
**Created**: 2026-10-26
**Project type**: Native iOS feature (Swift / SwiftUI / CoreBluetooth) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Builds on**: prompts 204 (#398) and 205 (#399) — stacked on 205.
**Wireframe (approved 2026-10-26)**: `docs/ux-research/kilter-board-sharing/wireframes.html` / `.png`

## Goal

User's real-board test (2026-10-26): "connection was quick but other surrounding users were not able to connect
because my app was hogging the connection." A board takes one Bluetooth connection, and a connected board stops
advertising, so while Snappet held it for the whole session nobody else (Snappet or the Kilter app) could find it.

## Approach (user's picks)

- Hold the board only while lighting climbs. After an idle time with nothing lit, let go; the climb stays lit
  (user-confirmed: Aurora boards keep the last climb after a disconnect) and the session carries on.
- Idle time: **10 s by default**, choice of 10 s / 30 s / 1 min / 2 min / 5 min (user: "default 10 seconds and give
  users option"). On for every board by default; switch off per board (home) → stays connected as before.
- The next light reconnects to the same board directly (no scan, no chooser, no second "recognized" ribbon); no
  answer within 5 s ⇒ "Someone else is on <board>" with Try again / Another board.
- Going to the background lets go at once (when sharing is on).
- UI: countdown + "Let go now" under the light button; "Still lit — board free for others" + "Light this climb"
  when let go; "Lighting on <board>…"; the session bar reads "<board> · free"; the board pill "Board free · Light";
  Settings → Remembered boards: per-board toggle + idle time. Every "light" gate that used `isConnected` now uses
  `canLight` (connected or let go), so swiping to a climb / building a draft still lights it.

## Acceptance

- [x] `KilterBoardSharingTests` (defaults, per-board storage, legacy decode, let-go time, labels) green; full unit
      suite green; Kilter UI slice green.
- [ ] Device (owed — real board, ideally with a second phone): after 10 s idle another phone can connect while the
      climb stays lit; lighting the next climb reconnects in ~1 s; with the other phone connected, Snappet says
      "Someone else is on …" within ~5 s; a board with sharing off stays connected; backgrounding lets go.
