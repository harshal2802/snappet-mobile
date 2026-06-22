# Prompt: Clips — explore grid (browse all posts, jump to one)

**File**: pdd/prompts/features/86-ios-clips-explore-grid.md
**Created**: 2026-06-22
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: prompt 82 Clips feed → its deferred "explore-grid" follow-up (#1 of the post-inline follow-ups)
**Context**: `pdd/context/project.md`, `pdd/context/decisions.md`

## Goal

An IG-profile-style **grid** to browse all Clips posts at a glance and jump to one. A grid button in the
Clips nav bar opens a sheet of post **covers** (the post's first clip thumbnail + name + a clip-count
badge for multi-clip posts), newest first. Tapping a cover dismisses the grid and **scrolls the feed to
that post**. Derive-on-read over the same `ClipFeedComposer` posts — no new persistence.

## Context the implementer needs

- `ClipsFeedView` already composes `[ClipFeedPost]` (`composedPosts()`); each post has `clips`
  (`ClipFeedItem.media: MediaInput`), `title`, `captureAt`, `clipCount`, `id` (`groupKey@sessionID`).
- `ClipThumbnail(localIdentifier:kind:size:)` (MediaBrowserView) is the shared poster-frame loader.
- The feed is a `ScrollView { LazyVStack { ForEach(posts) … } }` — add `ScrollViewReader` + `.id(post.id)`
  so a target post id can scroll into view.

## Approach

- New `Features/Feed/ClipsGridView.swift`: a `LazyVGrid` (3 columns, square cells) of post covers —
  `ClipThumbnail(post.clips.first.media)` + the post title (lower-third) + a `rectangle.stack` badge when
  `clipCount > 1`. Takes the `[ClipFeedPost]` + an `onPick: (String) -> Void` (the post id). A
  `NavigationStack` with a "Done" + the grid; empty state when no posts.
- `ClipsFeedView`: a nav-bar grid button (`square.grid.3x3`) → `.sheet` presenting `ClipsGridView`;
  wrap the feed's `LazyVStack` in `ScrollViewReader`, tag each card `.id(post.id)`, and on pick set a
  `scrollTarget` that `proxy.scrollTo(_, anchor: .top)` honours (then clear it). Keep the existing inline
  playback / ⋯ menu untouched.

## Output

- `ios/App/Snappet/Features/Feed/ClipsGridView.swift`.
- `ios/App/Snappet/Features/Feed/ClipsFeedView.swift` — grid button + sheet + ScrollViewReader.
- `docs/knowledge-graph/data.js`, `pdd/context/decisions.md`, `pdd/context/project.md`.
- A `SnappetUITests` flow (grid button opens the grid / empty state) if it fits the sim.

## Acceptance criteria

- [ ] A grid button in the Clips nav bar opens a grid of post covers, newest first; a multi-clip post
      shows a stack badge.
- [ ] Tapping a cover dismisses the grid and scrolls the feed to that post.
- [ ] No new `@Model` / no persistence — derived from the same composer posts.
- [ ] App type-checks (Swift 6, 0 warnings); full `SnappetTests` green.

## Constraints

- On-device only; no backend. Reuse `ClipThumbnail` + `ClipFeedComposer`; no new player here (the grid is
  still covers — tap jumps to the feed, where inline playback lives).
- Real thumbnails only render with Photos on device — the sim covers wiring + the empty state.

## Test plan

1. `xcodegen generate && xcodebuild test … -only-testing:SnappetTests` — build 0-warning, suite green.
   A `ClipsGridUITests` smoke (grid button → grid sheet / empty state) on the sim.
2. On a device with clips: open the grid, tap a cover → the feed scrolls to that post.
