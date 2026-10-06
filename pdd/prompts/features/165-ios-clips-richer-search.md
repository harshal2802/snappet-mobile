# Prompt: Clips — search by grade, angle, outcome and date

**File**: pdd/prompts/features/165-ios-clips-richer-search.md
**Created**: 2026-10-06
**Project type**: Native iOS feature (Swift) — code lands in this repo.
**Chain**: Clips review 2026-10-05 → item 6 ("search only matches the title and session name") — built overnight
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

People remember the grade, the angle, whether they sent it, and roughly when. Make the existing pull-down search
find all of that.

## Approach

- Pure `ClipSearch` (clock/calendar/locale injected): every whitespace word must match (AND); the haystack is
  title · subtitle · grade/angle detail · session name · outcome (+ "sent/send/sends" for flashes and sends,
  "flashed") · reel · date words (month, weekday, year, "29 sep"/"sep 29").
- Relative phrases become capture-date ranges: today, yesterday, this/last week, this/last month.
- `ClipFeedFilter.apply` builds one `ClipSearch` per apply (formatters once, not per post).
- Search prompt: "Search names, grades, sends, dates…".

## Acceptance criteria

- [x] "v5", "45°", "sent", "flash", "aug", "tuesday", "29 sep", "last week", "sent last week" all work (unit-tested).
- [x] `SnappetTests` green (2367).
- [ ] Device: typing feels instant on the real library (306 posts).
