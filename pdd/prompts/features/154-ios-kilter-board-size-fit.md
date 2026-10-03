# Prompt: Kilter — only list climbs your board can fully light (strict board-size fit)

**File**: pdd/prompts/features/154-ios-kilter-board-size-fit.md
**Created**: 2026-10-03
**Project type**: Native iOS fix (Swift / SQLite) — code lands in this repo. Android: download filter only.
**Builds on**: #340 (prompt 153, browse off-main) — same browse SQL.

## Problem (device feedback)

"cam pussie" (Original layout) listed on a 12 x 12 with kickboard, but its last purple (finish) hold never
lit. Its finish is hole (0,152), which only the 16 x 12 Super Wide has an LED for — so the 12 x 12 LED map
has no address for it and the hold was silently skipped, and the render clamped it into the corner.

## Root cause

1. Browse didn't filter by board size at all.
2. The download "fits this size" filter was inclusive (`edge_left >= left …`). A size's edges sit just
   outside its outermost wired holes, so a climb whose box *touches* an edge uses a bigger board's hole.
   Checked on the real Kilter catalog: on every Original-layout size, **strict** fit (`>` / `<`) = exactly
   the climbs whose every hold has an LED on that size (0 false positives, 0 false negatives); inclusive let
   in 954 bad climbs on a 12 x 12 and 14,437 on an 8 x 12.

## Fix

- `KilterSizeBox.fitSQL` / `fits(...)`: one strict rule. Used by the browse list + count (+ the off-main
  browser), Climb of the day (cached per board box too) and the catalog download filter.
- Browse passes the selected board size's box (`kilter.productSizeId`), and re-queries when it changes.
- Climb screen: if a climb reached another way (Saved, QR, History) has holds the board has no LED for,
  say so — "1 hold isn't on your 12 x 12 board, so it won't light. This climb was set for a 16 x 12." —
  instead of skipping silently.
- Android: the download filter uses the strict rule. Android browse doesn't filter by size yet (follow-up).

## Acceptance criteria

- [x] `KilterSizeFitTests` (3): cam pussie doesn't fit a 12 x 12 but fits a 16 x 12; strict on every side; SQL = Swift rule.
- [x] `KilterCatalogStoreTests.testBrowseOnlyListsClimbsThatFitTheBoardSize`; unit suite 2255 green.
- [ ] Device: "cam pussie" no longer listed for the 12 x 12; opened from Saved/History it shows the note.
