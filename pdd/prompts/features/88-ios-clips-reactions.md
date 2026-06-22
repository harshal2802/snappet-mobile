# Prompt: Clips — react (favorite a post)

**File**: pdd/prompts/features/88-ios-clips-reactions.md
**Created**: 2026-06-22
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: prompt 82 Clips feed → its deferred "reactions" follow-up (#1c)
**Context**: `pdd/context/project.md`, `pdd/context/decisions.md`

## Goal

A ❤️ **favorite** reaction on a Clips post — tap the heart in the post header to mark it; favorited posts
show a filled heart. For a PERSONAL on-device feed (your own clips), a social "like" records nothing, so
"reactions" = favoriting your best clips. Persisted minimally in **UserDefaults** (a Set of post ids) —
**no new `@Model` / no schema change** (the session stays the source of truth for the clips themselves;
favorites are a thin UI-layer overlay), honouring the spirit of the Clips "no new persistence" principle.

## Context the implementer needs

- `ClipFeedPost.id` is stable (`groupKey@sessionID`) — the favorite key.
- `ClipsFeedView` owns the feed; `ClipPostCard.header` has the title + ⋯ menu (room for a heart).
- A button (not a double-tap) avoids any conflict with the single-tap-to-play poster gesture.

## Approach

- New `Features/Feed/ClipReactionStore.swift`: an `@Observable @MainActor` UserDefaults-backed store —
  `isFavorite(_ postID:) -> Bool`, `toggle(_ postID:)` (persists a `[String]` under one key). No SwiftData.
- `ClipsFeedView`: own it (`@State`), pass to `ClipPostCard`.
- `ClipPostCard.header`: a heart button (`heart` / `heart.fill`, red when set) between the title and ⋯;
  `.symbolEffect(.bounce)` on toggle for a little delight.

## Output

- `ios/App/Snappet/Features/Feed/ClipReactionStore.swift` (+ a pure unit test of the store logic).
- `ios/App/Snappet/Features/Feed/ClipsFeedView.swift` — own the store + the header heart.
- `docs/knowledge-graph/data.js`, `pdd/context/decisions.md`, `pdd/context/project.md`.

## Acceptance criteria

- [ ] A heart in each post header toggles favorite; the state persists across launches; the heart fills
      when favorited.
- [ ] Persisted in UserDefaults only — no new `@Model` / no schema change.
- [ ] The store logic is unit-tested. App type-checks (Swift 6, 0 warnings); full `SnappetTests` green.

## Constraints

- On-device only; no backend/accounts. A "Favorites filter" (browse only favorites) is a follow-up.

## Test plan

1. `xcodegen generate && xcodebuild test … -only-testing:SnappetTests` — `ClipReactionStoreTests` + the
   suite green; 0 warnings; `ClipsFeedUITests` green.
2. On a device: favorite a post, relaunch → it's still favorited.
