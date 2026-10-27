# Prompt: Kilter — more than one board (prompt 205)

**File**: pdd/prompts/features/kilter-connect/205-ios-kilter-multi-board.md
**Created**: 2026-10-25
**Project type**: Native iOS feature (Swift / SwiftUI / CoreBluetooth) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Builds on**: prompt 204 (connect reliability, PR #398) — stacked on it.
**Wireframe (approved 2026-10-25)**: `docs/ux-research/kilter-multi-board/wireframes.html` / `.png`

## Goal

User questions: "what happens if there are multiple boards at same location — will it make things confusing? is
there a way to tag a name to boards on first connect and/or later?" and "what happens when I open the Kilter app
the first time?". Make several boards (two walls at one gym, a home board plus a gym board) clear instead of
guessed.

## What was wrong

1. Connect silently picked a board (known first, else strongest) — with two boards in range you could light the
   neighbour's wall.
2. A new board got a generic name ("Board 4821"); renaming lived only in Settings.
3. The arrival card offered only the most recently used board at a place.
4. The catalog download kept climbs for ONE board size, so a home 8 × 12 download hid 155,073 climbs that fit the
   gym's 12 × 12.

## Approach (user's picks, Q1–Q4)

- **Q1 — name on first connect.** The setup sheet ("Set up this board") gains a name field + chips; skipping it
  names the board size + serial, "12 × 12 (#4821)" (`KilterBoardMemory.defaultLabel(sizeName:serial:)`).
- **Q2 — chooser whenever 2+ boards are in range.** `KilterConnectPolicy.nearby/showsChooser/bars`; the controller
  collects adverts for the 1.2 s window and, with two or more near boards, presents `KilterNearbyBoardsSheet`
  (strongest first, signal bars, your name or "New board #serial", last-used detail). With one board nothing
  changes.
- **Q3 — Flash = four corners for 5 s.** Flash connects briefly, lights the calibration holds for
  `flashDuration`, clears and disconnects. It replaces whatever that board was showing (honest copy says so).
- **Q4 — your boards at download.** `KilterMyBoards` (UserDefaults, scratch suite under `-uiTest*`): the download
  sheet lists named boards (layout + size each, "Add another board"); `CatalogFilter.boardFits` keeps climbs that
  fit ANY of them (OR of per-layout boxes). On first connect the setup sheet asks "Which of your boards is this?"
  from the unlinked entries and links the physical board to it.
- Arrival card: `KilterPlaceMatcher.suggestions` — with several boards at the place, it lists them and asks which.

## Not done (deviations)

- Settings shows boards by name/size, not place names — only a coarse place is stored, never a place name.
- The download sheet doesn't preview "N climbs fit" — that needs the remote file first.
- Android not ported.

## Acceptance

- [x] `KilterMultiBoardTests` + `KilterAuroraSyncTests.testBoardFitsKeepClimbsThatFitAnyListedBoard` green; full
      unit suite (2555) green; Kilter UI slice (20) green.
- [ ] Device (owed — needs real boards): two boards in range → chooser; Flash lights the right wall's corners for
      5 s then clears; naming on first connect sticks in Settings and the connected chip; a two-board download
      browses climbs for both sizes.
