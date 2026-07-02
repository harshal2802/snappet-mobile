# Prompt: Clips — optional search & filter

**File**: pdd/prompts/features/107-ios-clips-search-filter.md
**Created**: 2026-07-02
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Clips feed line (82 → 98 → 106). Closes the prompt-88 "favorites-only filter" follow-up.
**Source**: User request — "add an optional search and filter option on clips … intuitive and user friendly."
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Let the user find past Clips posts by name and narrow the feed by what kind of post they want —
without adding any weight to the default browse. The feed must look and cost exactly what it does
today until the user pulls down to search or taps a chip.

## Context the implementer needs

- Posts are composed derive-on-read (`ClipFeedComposer` → `cachedPosts` in `ClipsFeedView`); a post
  carries `kind` (kilter | gym), `title` (climb/exercise name), `subtitle` (session title), and its
  clips with `media.kind` ("video" | "photo"). Favorites already exist (`ClipReactionStore`,
  prompt 88) with a written follow-up: "a favorites-only filter".
- The #264 Kilter UX round established the pattern: filters must be VISIBLE (chips), not a hidden
  toolbar glyph. Wireframes for this feature: `docs/ux-research/clips-search-filter/wireframes.html`
  (4 frames: default chip strip · search · stacked chips + count · no-match recovery).
- The explore grid (`ClipsGridView`, prompt 86) renders the same posts — it must inherit the filter
  or the two surfaces disagree.

## Approach

- **Keystone (pure)**: `ClipFeedFilter` — value state (`query`, `discipline` all|climbs|gym, `kind`
  all|videos|photos, `favoritesOnly`) + `apply(posts:isFavorite:)`. Query matches title OR subtitle
  via `localizedStandardContains` (case/diacritic-insensitive). Media kind matches a post when ANY
  clip is that kind (posts stay whole — never filter clips within a post). Inactive ⇒ return the
  input untouched and never call `isFavorite` (zero cost, no extra SwiftUI dependency).
- **View**: `.searchable` (navigationBarDrawer, automatic — hidden until pulled) binding
  `filter.query`; a `ClipFilterChipStrip` as the first LazyVStack row (scrolls away; hides while
  `isSearching`); an "N of M posts · Clear" line while active; a `ContentUnavailableView` no-match
  state with one-tap "Clear search & filters"; the grid sheet gets the filtered posts. Narrowing
  the feed stops the active inline clip (`playback.playing = nil` on filter change) so playback
  never points at a filtered-out card.
- Session-scoped state (resets on relaunch) — like IG search, deliberately not persisted.

## Output

- `ios/App/Snappet/Features/Feed/ClipFeedFilter.swift` — the pure keystone.
- `ios/App/Snappet/Features/Feed/ClipsFeedView.swift` — searchable + chip strip + result line +
  no-match state + filtered grid handoff.
- `ios/App/SnappetTests/ClipFeedFilterTests.swift` — query/chips/stacking/fast-path coverage.
- `docs/ux-research/clips-search-filter/` — wireframes (HTML + PNG), committed as the reference.
- `docs/knowledge-graph/data.js` — `clips-filter` node + edges; prompt-88 follow-up closed.

## Acceptance criteria

- [ ] Default feed renders pixel-identical cost: inactive filter returns `cachedPosts` untouched.
- [ ] Search matches climb/exercise names AND session titles, case/diacritic-insensitive.
- [ ] Chips: Favorites stacks with anything; Climbs/Gym and Videos/Photos each mutually exclusive;
      tapping an active chip turns it off.
- [ ] Active filter shows "N of M posts · Clear"; no-match shows a recovery action; the grid sheet
      shows the same filtered set.
- [ ] Unit suite green; no UI regression in `ClipsFeedUITests`.
- [ ] Knowledge graph updated in the same change.

## Constraints

- No new store/@Model — filter state is `@State`, favorites stay in `ClipReactionStore`.
- Pure logic stays pure (`ClipFeedFilter` has no platform imports).
- Don't regress prompt-106/97 perf: no per-swipe work added; filtering runs only on filter/data
  changes (body evaluation), O(posts) string checks.

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'` — `ClipFeedFilterTests` + full suite.
2. `ClipsFeedUITests` on the sim (feed chrome unchanged on fresh store).
3. Device (MrRobot): search a climb name, stack ♥+Climbs, Videos/Photos toggle, no-match recovery,
   grid agreement.
