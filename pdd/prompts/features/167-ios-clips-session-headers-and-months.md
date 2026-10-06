# Prompt: Clips — session headers in the feed, months in the grid

**File**: pdd/prompts/features/167-ios-clips-session-headers-and-months.md
**Created**: 2026-10-06
**Project type**: Native iOS feature (SwiftUI) — code lands in this repo.
**Chain**: Clips review 2026-10-05 → item 4 ("long feeds are hard to navigate") — built overnight
**Design**: `docs/ux-research/clips-navigation/wireframes.html` (made first, NOT yet reviewed by the user — review in the morning)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

On the real library (300+ posts) the feed is one long scroll with no dates, and a 6-exercise session is 6
near-identical headers in a row. Give the feed sessions and dates, and give the grid a way to jump to a month.

## Approach

- Pure `ClipFeedSections`: `sessions(posts)` groups CONSECUTIVE posts of one session (the composer orders posts by
  session) into a header — session name, "Tue 30 Sep · Kilter · 40°" (· Gym / · Festival / · Apple Watch), post
  count; `months(posts)` groups the grid by the month the session started.
- Feed: `LazyVStack(pinnedViews: [.sectionHeaders])` — the session header pins while you're inside it. Grouping is
  over the VISIBLE posts, so filters/search group too. Posts unchanged.
- Grid: `LazyVGrid` month sections with pinned headers — tap a cover to land on the post (existing behaviour).
- Posts gain `sessionAngle` (for the header).

## Acceptance criteria

- [x] Session headers with date/kind/count; pinned while scrolling; festival nights read "Festival".
- [x] Grid grouped by month with pinned headers.
- [x] `SnappetTests` 2373 green; `ClipsFeedUITests` 7/7 (festival/hide tests now scroll to posts the header pushed
      below the fold).
- [ ] Device: scroll a long real feed — headers pin and hand over smoothly; no scroll-perf regression.

## Not done (options for review)

- Collapsing a session's posts into one card, and a month-jump control inside the feed itself.
