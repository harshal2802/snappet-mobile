# Prompt: Kilter board connect reliability (prompt 204)

**File**: pdd/prompts/features/kilter-connect/204-ios-kilter-connect-reliability.md
**Created**: 2026-10-25
**Project type**: Native iOS fix (Swift / CoreBluetooth) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

User report: connecting to the Kilter board "fails often or takes a long time". Review the connect flow in
`KilterBoardController` and fix what makes it slow or fragile, without touching the lighting protocol.

## What the review found

1. **The remembered-board path was a dead end.** After the first successful connect, every attempt went to
   `retrievePeripherals(withIdentifiers:)` for the last board. That returns a peripheral even when the board is
   asleep, out of range, or its identifier has gone stale, so `connect(_:)` waited out the 12 s watchdog and
   FAILED without ever scanning. A stale identifier failed forever, since only a scan could replace it.
2. **First advert wins.** The first name-matching board was taken, even a weaker or someone else's board.
3. **No retry.** A routine transient failure (`didFailToConnect`, a drop during discovery) ended the attempt; a
   drop before the board was ready even reset to idle with no message.
4. **Silent discovery stalls.** A missing service or characteristic waited out the watchdog instead of failing.
5. **No reconnect.** A mid-session drop needed a manual tap, and the lit climb went dark.

## Approach

- Pure `KilterConnectPolicy`: pick (known board first, else strongest RSSI, far boards only as a last resort),
  immediate connect for known boards, a 1.2 s selection window otherwise, a 3 s grace for the remembered
  board, retry once for connect/discovery failures (never for an empty scan), actionable failure messages.
- `KilterBoardController`: system-connected adopt → else scan, racing a pending connect to the remembered
  board on the first attempt; auto-reconnect (`CBConnectPeripheralOptionEnableAutoReconnect`, iOS 17+) with
  "Reconnecting…" and the current climb re-lit on return; fail fast on missing service/characteristic.
- `KilterRootView`: pass `KilterBoardMemory`'s ids as known boards; "Reconnecting…" copy.

## Acceptance

- [x] `KilterConnectPolicyTests` green; build clean.
- [ ] Device (owed — needs the real board): a second connect is fast; board off → clear message in ≤ 15 s;
      switching the board off and on mid-session reconnects and re-lights the climb.
