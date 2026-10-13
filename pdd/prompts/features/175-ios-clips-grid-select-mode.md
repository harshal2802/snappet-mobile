# Prompt: Clips grid — select several covers and act on them together

**File**: pdd/prompts/features/175-ios-clips-grid-select-mode.md
**Created**: 2026-10-10
**Project type**: Native iOS feature (SwiftUI) — code lands in this repo.
**Chain**: clips-grid wireframes (`docs/ux-research/clips-grid/`, screen 3)
**Context**: `pdd/context/decisions.md` (2026-10-10 reel host for week / month / picked clips)

## Approach

- Toolbar: Select ⇄ Cancel (left), Done ⇄ All (right); title "N selected". Tap a cover to tick it (check ring);
  long-press menus are off while selecting.
- Bottom bar: **Favorite/Unfavorite** (unfavourites only when every pick already is one), **✦ Make reel** →
  `WeeklyReelHostView(scope: .clips(ids))` — the picked clips in full, **Share** (each pick's first video, raw, in one
  share sheet), **Hide** (all clips of the picks, via the feed's hide → undo toast).
- Pure helpers in `ClipGridModel` (`mediaIDs(of:)`, `shareables(of:)`, `allFavorite`) — unit-tested.
- Not done: drag-to-select across covers (tap only).

## Acceptance criteria

- [x] Select → tick → All → Hide empties the grid (UI test); bulk reel link present.
- [x] `SnappetTests` 2388 green.
- [ ] Device: a reel from picked clips across different days; multi-share.
