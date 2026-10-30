# Prompt: Design-system reset, step 3c — Clips feed (prompt 216)

**File**: pdd/prompts/features/design-system/216-ios-clips-feed-restyle.md
**Created**: 2026-10-29
**Project type**: Native iOS (SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Mockup (approved, user: "use accent for reels too, lets implement")**: `docs/ux-research/design-system/clips-feed.html`

## Goal

Restyle the Clips feed: the feed top, posts, the grid and the Exercises albums. Every element keeps its place and
behaviour (checklist in the mockup). Reels take the user's accent instead of coral.

## Approach

- `SnappetColor.reels` is now an alias of `brand`. That covers the highlights card, ✦ Reel, Make reel, the grid
  badge and the reel editor app-wide.
- `kilterPill` → `snappetPill` (DesignSystem/SnappetPill.swift), shared by Kilter + Clips.
- Feed top:
  - Health offer → one quiet row (Connect pill + ✕).
  - Weekly highlights → calm panel (accent ▶, plain filmstrip).
  - Session headers → neutral glyph tiles at regular weights.
  - Filter chips → outlined pills, accent when on (no per-activity colours on chrome).
  - The Autoplay control keeps its word label (prompt 166 found a bare glyph didn't read as autoplay); it's now a
    pill.
- Post card:
  - neutral avatar, medium title;
  - status as coloured words (✓ Sent), ✦ Reel / ⌚ Apple Watch as small outline tags;
  - thin action icons;
  - stats medium weight, #tags in the accent, activity / set / ★ PR chips as pills;
  - View all in the accent, grey meta, Tag artist pill;
  - page dots in the accent.
- Albums: neutral header, accent Open / Progress reel, sentence-case Then / Now.
- Poster placeholder: neutral, was a Kilter-amber wash on every loading post.

## Acceptance

- [x] Dark screenshots: feed top, a post, grid, Exercises albums — match the mockup.
- [ ] Full UI suite + unit suite.
- [ ] Device: scroll + autoplay on real clips.
