# Prompt: Clips — favorites that survive backup and regrouping

**File**: pdd/prompts/features/162-ios-clips-durable-favorites.md
**Created**: 2026-10-06
**Project type**: Native iOS fix (Swift / SwiftUI) — code lands in this repo.
**Chain**: Clips review 2026-10-05 → item 3 of 3 (160 share with HR · 161 climb outcomes · 162 durable favorites)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Clips favorites (prompt 88) live in UserDefaults as a set of POST ids. Two silent losses follow:
1. Backup/restore drops them — the backup envelope is the SwiftData store.
2. A post id is derived (`groupKey@sessionID`); re-tagging a clip to another exercise or a festival set
   changes it and un-hearts the post.

## Approach

- Store favorites as `FeedReaction` rows — the existing, already-backed-up "private reaction on content"
  model — with `typeRaw = "clipFavorite"` and `activityContentId = "clipmedia:<SessionMedia.id>"`. No new
  `@Model`, no backup-schema change. Recap only matches reactions by its own card ids, so these never show there.
- Key by CLIP: hearting a post hearts all its clips; a post is a favorite when any clip is; un-hearting clears
  them all.
- `ClipReactionStore` keeps an in-memory cache, attaches to the feed's context on every rebuild (so a restore
  shows up), and moves prompt-88 post-id hearts onto the composed posts' clips once — only after a non-empty
  compose, then removes the legacy key.
- `ClipFeedFilter.apply(isFavorite:)` takes the post.

## Acceptance criteria

- [x] Toggle writes/removes one row per clip; favorites survive a regroup and a backup round-trip.
- [x] Legacy hearts migrate once, never on an empty compose; orphaned legacy ids map to nothing.
- [x] Recap reactions are not counted as clip favorites.
- [x] `SnappetTests` green, 0 new warnings.
- [ ] Device: an existing heart survives the update (legacy migration) and a backup/restore.

## Test plan

1. `make ios-test-unit` — `ClipReactionStoreTests` (in-memory store), `ClipFeedFilterTests`.
2. Device: heart a post on the old build, update, check it's still hearted; back up, restore, check again.
