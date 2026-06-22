# Prompt: F1 — iOS FeedView shell + session cards + freshness kit + tab wiring

**File**: pdd/prompts/features/feed/F1-ios-feedview.md
**Created**: 2026-06-20
**Project type**: Native iOS feature (Swift / SwiftUI). Code lands in this repo.
**Chain**: PLAN.md → F1 (depends on F0; the gate for F2–F7)
**Source**: GitHub epic "Recap Feed" → issue "F1 iOS FeedView + session cards + freshness"
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`
**Design**: `/tmp/feed-dossier/_locked-design.md` §3 (IA + flow), §6.1 (Pillar 1 cards), §11 wireframes 1–7, 21–22

## Goal

Stand up the **Recap** tab and its scroll backbone: insert `FeedView` as the **middle** tab (Today · **Recap** · Apps — the new emotional center, `_locked-design.md:35-37`), render the F0 composer's a1/a2 session cards as polished Pulse-Pro cards, and ship the **freshness kit** (skeleton → Stories-rail-first paint → "N new / New recap ready" pill → optimistic insert → pull-to-refresh) plus the **Lens bar** (filter chips incl. the always-available **Sessions-only** lens). This is the surface every later phase renders into; it must page efficiently and never "lose" a session — the recency-bound + Sessions-only lens neutralize the "where did my session go?" risk (`_locked-design.md:13`, `287`).

## Context the implementer needs

- **Tab insertion** (`_locked-design.md:37`, `components.md:24-27`): add `case feed` to `SuiteTab` (`SuiteRouter.swift:5`); insert a third `TabView` case in `ShellTabs` (`RootShell.swift:160-169`) → `FeedView()`, `.tag(SuiteTab.feed)`, SF Symbol `sparkles.rectangle.stack`, label **"Recap"**, positioned **between** Today (`home`) and Apps. The router already supports a `--start-tab` initial-tab arg (`RootShell.swift:14-15`) — wire `feed` into it. Deep-link `snappet://feed` via the existing `onOpenURL`.
- **The data source is F0's composer reading F0b's persisted log.** `FeedView` calls `FeedComposer.compose(window: .allTime, …)` over plain-value snapshots (`TodayDigest` derive-on-read pattern, `ios_models.md:533`). It must **not** re-derive math. Session payloads ride `KilterSessionStats.make(...)` (`KilterSessionStats.swift:40`) and `WorkoutSession` discipline-adaptive facts (`WorkoutModels.swift:502`, `_locked-design.md:130-131`).
- **Cards (Pillar 1, `_locked-design.md:194`):** each session is one `FeedCard` built from `PulsePro.DisciplineHero` (climbing-native hero: hardest grade / mini-pyramid, **not** a route map) + `StatRibbon` (fact triad) + `.snappetCard()` on `SnappetColor` tokens with a discipline edge-accent (`SnappetColor.kilter`/`.workout`). Reuse `PulsePro.swift:11` and `SnappetCard.swift:28` verbatim. a2 is discipline-adaptive (strength volume hero / running distance-pace) per wireframe 7.
- **No HR, no media, no reactions, no share in F1** — those are F2/F3/F4. a1 cards with no media use the **generated `DisciplineHero` hero fallback** (wireframe 6); HR sparklines and the inline auto-clip are added by F2/F3 without changing F1's card shell.
- **Keyset pagination:** page on the `(published, id)` cursor — `FeedActivity.published` is the cursor key (`_locked-design.md:96`). Lazy-decode the next keyset page on scroll (`LazyVStack`).
- **Freshness kit (flow narrative `_locked-design.md:75`, wireframe 4):** skeleton cards on cold open; the **Stories rail fades in first** (cheap) — F1 ships the rail's *placeholder slot* but the Story Player itself is F6, so F1 renders a non-interactive period-cover strip that F6 will activate (never a dead button — show real period labels). A new session logged while away surfaces a **"New recap ready / N new" pill** that scrolls-to-top **without yanking** the user's position; dismiss/return restores the exact scroll offset.
- **Lens bar (`_locked-design.md:42`):** client-side filter chips *All · Climbing · Strength · Effort · Milestones · Sessions-only*, applied via F0's pure lens post-filters. **Sessions-only** is the chronological A-style stream and must always be available (the recency-float mitigation, `_locked-design.md:287`).
- **Grid toggle** to the Wall exists in the header per IA (`_locked-design.md:42`), but `WallView` is F7 — F1 ships the toggle affordance routed to a Stage-0 "Wall coming" target or simply hidden behind F7; prefer wiring the toggle now to a placeholder that F7 replaces (no dead button).
- New dir is `ios/App/Snappet/Features/Feed/` (F0 created it).

## Approach

- `SuiteRouter.swift`: add `case feed`. `RootShell.swift`: insert the third `TabView` case (`FeedView()`, `.tag(.feed)`, `sparkles.rectangle.stack`, "Recap") between home and apps; extend the initial-tab/`--start-tab` mapping; ensure `snappet://feed` routes via `onOpenURL`.
- `Feed/FeedView.swift`: a `LazyVStack` inside a `ScrollViewReader` (for scroll-to-top-without-yank); top → pinned Stories-rail placeholder strip (real period labels, F6 activates), Lens bar (chips bound to F0 post-filters), then the composed stream. Header has the grid-toggle affordance.
- `Feed/FeedSessionCard.swift`: the a1/a2 card view (`DisciplineHero` + `StatRibbon` + `.snappetCard()` + edge accent + generated-hero fallback). Discipline-adaptive a2 variants.
- `Feed/FeedPagination.swift`: a small pure keyset `(published,id)` cursor + page loader over the activity log; lazy next-page on scroll.
- `Feed/FeedFreshness.swift`: skeleton state, the "N new / New recap ready" pill, optimistic-insert, pull-to-refresh, and scroll-offset restoration.
- Pure helpers (cursor math, lens application wiring, "N new" diff) go in testable files; XCUITest covers the tab → scroll → lens → pill flow.

## Output

- `SuiteRouter.swift` + `RootShell.swift` — `feed` tab inserted (middle), deep-link wired.
- `Feed/FeedView.swift` — root scroll: Stories-rail placeholder + Lens bar + composed stream + grid-toggle affordance + freshness states.
- `Feed/FeedSessionCard.swift` — a1/a2 Pulse-Pro session cards (+ generated-hero fallback, discipline-adaptive a2).
- `Feed/FeedPagination.swift` — keyset `(published,id)` cursor + page loader.
- `Feed/FeedFreshness.swift` — skeleton / "N new" pill / optimistic insert / pull-to-refresh / scroll restore.
- `SnappetTests/FeedPaginationTests.swift` + `SnappetTests/FeedFreshnessTests.swift` — pure cursor + "N new" diff + lens-filter tests.
- `SnappetUITests/FeedViewUITests.swift` — tab → cards → lens → Sessions-only → pill flow.
- `docs/knowledge-graph/data.js` — add `tab-feed` (shell) + `feed` (screen) nodes; `contains` edge RootShell→tab-feed, `navigate` edge tab-feed→feed, `feeds` edge feed-composer→feed.

## Acceptance criteria

- [ ] A third **"Recap"** tab (`sparkles.rectangle.stack`) sits **between** Today and Apps; `snappet://feed` opens it; `--start-tab feed` works.
- [ ] `FeedView` renders a1 Kilter + a2 Workout session cards from `FeedComposer.compose(window:.allTime)` on `PulsePro.DisciplineHero` + `StatRibbon` + `.snappetCard()` with discipline edge accents; a card with no media uses the generated `DisciplineHero` fallback; a2 adapts to strength/running.
- [ ] Keyset `(published,id)` pagination lazily loads the next page on scroll; the pure cursor is unit-tested (stable, no dup/skip across page boundaries).
- [ ] Freshness kit works: cold open shows skeleton → Stories-rail placeholder (real period labels, not a dead button) paints first → stream; a session logged while away surfaces a "New recap ready / N new" pill that scrolls to top **without yanking**; returning restores the exact scroll offset.
- [ ] The Lens bar filters via F0's pure post-filters; **Sessions-only** always available and yields the chronological stream; no card floats older than its trigger (recency bound visible).
- [ ] No HR/media/reactions/share added in F1 (deferred to F2–F4); the card shell is open for them. App type-checks (Swift 6, 0 warnings); `decisions.md` updated.

## Constraints

- On-device only; derive-on-read (no card persistence). Reuse `PulsePro`/`SnappetCard`/`SnappetColor` — no new brand tokens. Reuse F0's composer + lens filters; do not re-derive stats in the view.
- Stories rail and grid toggle render as honest placeholders routed to F6/F7 (never dead buttons). "N new" must not yank scroll position.

## Test plan

1. Unit: `FeedPaginationTests` (cursor stability across page boundaries) + `FeedFreshnessTests` ("N new" diff + lens filtering) green; build-for-testing.
2. XCUITest: launch `--start-tab feed` → assert a1/a2 cards render → tap Lens chips incl. Sessions-only → inject a new session → assert the "N new" pill appears and scroll-to-top doesn't yank → return restores offset. Sim wedge → `xcrun simctl shutdown all`, re-run.