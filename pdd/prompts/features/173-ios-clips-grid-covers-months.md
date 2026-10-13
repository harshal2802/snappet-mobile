# Prompt: Clips grid — covers that say what they are; months you can act on

**File**: pdd/prompts/features/173-ios-clips-grid-covers-months.md
**Created**: 2026-10-10
**Project type**: Native iOS feature (SwiftUI) — code lands in this repo.
**Chain**: user: "we can make month grid more feature rich. give users more ways to interact with that grid" —
wireframes `docs/ux-research/clips-grid/` (user picked all four: 173 covers+months · 174 long-press · 175 select · 176 move fast)
**Context**: `pdd/context/decisions.md`

## Approach

- Pure `ClipGridModel`: months (from `ClipFeedSections.months`) with sessions · sends · peak HR summary, posts-by-day
  for the day strip, `firstPost(onDay:)` jump target, the calendar-month interval; cover duration labels.
- Covers: video length (the kept range), SENT/FLASH, ✦ REEL, peak ♥ (max over the post's clip payloads), favourite ♥,
  multi-clip marker.
- Month header: summary line, a tappable day strip (shaded by posts that day → scroll to that day's first cover),
  **✦ Make reel** → the shared reel builder over the month (`ReelSource.collection`, trimmed to highlights).
- The feed's chip strip sits at the top of the grid on the SAME filter binding — grid and feed always agree.
- `WeeklyReelHostView(scope:)` generalised: `.week` (unchanged), `.month(interval, title)`, `.clips(ids)` (175).

## Acceptance criteria

- [x] Covers + month header + day strip + month reel (UI test opens the reel builder).
- [x] `SnappetTests` 2387 green (`ClipGridModelTests`).
- [ ] Device: month reel renders on a real month; day-strip jumps land.
