# Prompt: Clips — split ClipsFeedView.swift (mechanical)

**File**: pdd/prompts/features/168-ios-clips-feed-file-split.md
**Created**: 2026-10-06
**Project type**: Native iOS refactor — code lands in this repo.
**Chain**: Clips review 2026-10-05 → "still open: ClipsFeedView.swift is 1,400 lines" (1,676 after 160–167) — built overnight
**Context**: `pdd/context/conventions.md`

## Goal

Make the Clips feed safer to change: one 1,676-line file held the feed, its chrome, the post card and the poster.

## Approach (mechanical — no behaviour change)

- `ClipsFeedView.swift` (707): the feed, its state and derivation.
- `ClipsFeedChrome.swift` (291): Health offer card, Weekly hero, session header, filter chip strip — `private` →
  internal (the feed uses them).
- `ClipPostCard.swift` (689): the post card (internal) + its private helpers and `ClipPosterView` (still private to
  the file — `StudioPresentation` also exists privately in SessionDetailView).
- Code moved verbatim; only the access modifiers above changed.

## Acceptance criteria

- [x] Builds with 0 new warnings; `SnappetTests` 2373 green; Clips UI suite green.
- [x] Last PR in the stack, so it can be dropped without touching the features.
