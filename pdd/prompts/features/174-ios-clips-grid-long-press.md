# Prompt: Clips grid — long-press a cover for a preview + its actions

**File**: pdd/prompts/features/174-ios-clips-grid-long-press.md
**Created**: 2026-10-10
**Project type**: Native iOS feature (SwiftUI) — code lands in this repo.
**Chain**: clips-grid wireframes (`docs/ux-research/clips-grid/`, screen 2) — user picked all four grid options
**Context**: `pdd/context/decisions.md`

## Approach

- `.contextMenu { … } preview: { … }` on every grid cover: a big preview (thumbnail, title, grade/angle, badges) and
  Open in feed · Play fullscreen · Favorite/Unfavorite · Share with heart rate · Edit in Studio · Go to session ·
  Hide from Clips.
- `ClipGridActions` (closures) is built by the feed from the SAME caches/style the posts use — the grid's share is
  the post's burned share (`ClipSharePlan` + `ClipShareService`), fullscreen uses the post's tile, Studio resolves the
  session's project. The grid presents fullscreen / Studio / share sheet itself; Go to session dismisses then routes.
- Menu items carry `clips.grid.menu.*` identifiers (their labels collide with the posts' own buttons behind the sheet).

## Acceptance criteria

- [x] Long-press shows the actions; Favorite toggles and sticks (UI test).
- [x] `SnappetTests` green.
- [ ] Device: share-with-HR, fullscreen, Studio and Go to session from the grid.
