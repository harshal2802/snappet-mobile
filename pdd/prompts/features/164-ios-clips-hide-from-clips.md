# Prompt: Clips — Hide from Clips (non-destructive, with undo)

**File**: pdd/prompts/features/164-ios-clips-hide-from-clips.md
**Created**: 2026-10-06
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Clips review 2026-10-05 → item 5 ("you can't remove or hide anything") — built overnight at the user's request
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

A bad clip stays in the feed unless you go to its session. Add **Hide from Clips** to the ⋯ menu: the clip leaves
the feed but stays in its session and in Photos; Undo for a few seconds; a **Hidden · N** chip lists hidden clips
so they can be unhidden.

## Approach

- Hidden clips are `FeedReaction` rows (`clipHidden`, `clipmedia:<SessionMedia.id>`) — the prompt-162 favorites
  storage, so they're backed up and keyed by clip. `ClipReactionStore` gains `hiddenIDs` / `hide` / `unhide`.
- Pure `ClipFeedFilter.withHidden(posts, hidden:, showHidden:)`: hidden clips leave their posts (empty posts go);
  with `showHidden` only hidden clips show. `filter.showHidden` drives the Hidden chip (last in the strip, only
  when something is hidden).
- ⋯ menu: "Hide this clip from Clips" + "Hide post (N clips)"; behind the Hidden chip: "Unhide this clip" /
  "Unhide all N". Toast "Clip hidden from Clips · Undo" for 4 s. The weekly hero ignores hidden clips.

## Acceptance criteria

- [x] Hide removes the clip (or post) from the feed and grid; Undo restores; Hidden chip shows them; Unhide works.
- [x] Backed up; separate from favorites.
- [x] `SnappetTests` green (2361); `ClipsFeedUITests` 5/5 incl. hide → undo toast → Hidden chip → unhide.
- [ ] Device: hide/unhide on real posts.

## Known limits

- The Weekly Highlight Reel BUILDER (its own snapshot) still includes hidden clips; only the hero ignores them.
- Rows for a deleted clip are left behind (nothing reads them).
