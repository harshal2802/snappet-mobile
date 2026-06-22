# Prompt: F0 — FeedComposer + FeedCard keystone (pure, cross-platform)

**File**: pdd/prompts/features/feed/F0-feedcomposer-keystone.md
**Created**: 2026-06-20
**Project type**: Native iOS feature (Swift) — pure value type, code lands in this repo; the Kotlin port is FA0.
**Chain**: PLAN.md → F0 (no dependencies; the keystone — spine of every later phase, both platforms)
**Source**: GitHub epic "Recap Feed" → issue "F0 FeedComposer keystone (pure)"
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`
**Design**: `/tmp/feed-dossier/_locked-design.md` §2 (keystone), §4.2 (`FeedCard`), §4.3 (derivation), §5 (taxonomy), §7 (degradation)

## Goal

Build the keystone the entire Recap Feed renders: a pure, golden-vector-tested **`FeedComposer.compose(...)`** that turns raw session/log/all-time inputs into an ordered set of ephemeral `FeedCard`s, where each card declares its own `eligibility(predicate) -> Bool` and `salience(score) -> Double` so the feed **degrades by construction** (`_locked-design.md:19-28`). This is "the engagement engine and the graceful-degradation mechanism in one file" — exactly as `KilterAllTimeStats` was the keystone for the Kilter initiative. It has **zero UI and zero store**: it consumes plain values and emits pure `FeedCard` values, so it runs in `SnappetTests` with no simulator and yields the **identical eligible card set on iOS and Android** from one golden corpus (`_locked-design.md:25`). F0 covers the Wave-1 derive-on-read cards only — **a1/a2 session, b1 Grade PR, b3 Most-Climbs, b5 Streak, c1 Pyramid, d1 Weekly-Volume** — with **no HR and no media predicates yet** (those arrive in F2/F3/F5 by *adding* registry entries, never editing the engine).

## Context the implementer needs

- The pure-aggregation template to mirror is `TodayDigest` (`ios/App/Snappet/Features/Home/TodayDigest.swift`, `ios_models.md:533`) and `KilterAllTimeStats` (`KilterAllTimeStats.swift:27`, a computed struct, Foundation-only, no SwiftData/UI — `ios_models.md:93`). `FeedComposer` follows this exact shape: plain-value in, value-type out, fully unit-testable.
- The composer **reads existing engines and only surfaces their numbers** — it must not re-derive math. Session card payloads come from `KilterSessionStats.make(...)` (`KilterSessionStats.swift:40`, `_locked-design.md:130`); PR/pyramid/volume/streak facts come from `KilterAllTimeStats` (`KilterAllTimeStats.swift:27`, `_locked-design.md:263`). Workout cards read `WorkoutSession` (`WorkoutModels.swift:502`) discipline-adaptively via `disciplineRaw` (strength→volume; running→`SetLog.distanceMeters`/pace; timed→work/rounds) (`_locked-design.md:131`).
- **Inputs must be plain values, not `@Model`s** — pass `[KilterClimbLog]` / plain session snapshots (the `KilterClimbLog.from` bridge pattern from `KilterSessionStats`), so the engine has no SwiftData/device dependency and the same signature compiles in Kotlin.
- **`FeedCard` is ephemeral — derived on read, NEVER persisted** (`_locked-design.md:115`). It carries a discipline-typed `payload` snapshot so the view renders without re-query.
- **Salience is recency-bounded:** a card's `anchorDate` is its trigger date and it may **never** float older than that trigger; ordering is `salience × recencyDecay(anchorDate, now)` with PR > trend > routine session (`_locked-design.md:13`, `122`, `287`). v1 ordering is **simple and temporal** — no banded memoization (`_locked-design.md:219`, `283`).
- **Degrade-by-absence:** a predicate that needs a field the platform lacks (`hrSeries`, `SessionMedia`, `attemptTimestamps`) is simply never eligible — there is no stub and no greyed card (`_locked-design.md:24`, `188`, `208`). The flagship F0 cards (Grade PR, Pyramid) ride `KilterAllTimeStats`, which exists on both platforms, so Android ships a real card and isn't second-class (`_locked-design.md:188`).
- **Banded-memoization invalidation, if ever added, must be byte-identical across platforms or the golden corpus passes while real scrolling diverges** (`_locked-design.md:219`) — so v1 explicitly does NOT band; keep composition temporal.
- **One engine, two callers:** the infinite feed calls `compose(window: .allTime)`; the Story Player (F6) calls `compose(window: .thisWeek/.thisMonth/.thisYear)` — design the `window` parameter now even though only `.allTime` is exercised in F0 (`_locked-design.md:28`).

## Approach

- Add a new dir `ios/App/Snappet/Features/Feed/` with the pure engine files (no views, no `@Model`):
  - `FeedCard.swift` — the `FeedCard` value type (`Codable`/`Sendable`): `kind: FeedCardKind`, `category: FeedCategory`, `salience: Double`, `anchorDate: Date`, `sourceRefs: [ActivityRef]`, `payload: FeedCardPayload`, `shareHint: ShareTemplate?` (`_locked-design.md:117-126`). `FeedCardKind` enum seeded with the F0 cases (`a1Session`, `a2Session`, `b1GradePR`, `b3MostClimbs`, `b5Streak`, `c1Pyramid`, `d1WeeklyVolume`) — open for additive extension. `FeedCategory` = `climbing | strength | effort | milestone | trend | recap | memory`. `FeedCardPayload` = a discipline-typed enum carrying the snapshot each view needs (no re-query).
  - `FeedComposer.swift` — `compose(window:kilterSessions:workoutSessions:logs:allTimeStats:now:) -> [FeedCard]`. Internally: a **registry** of card recipes, each a `(eligibility: (Context) -> Bool, salience: (Context) -> Double, build: (Context) -> FeedCard?)`. Run every recipe over the input context, keep the eligible ones, build payloads, then order by `salience × recencyDecay(anchorDate, now)` clamped so `anchorDate ≤ now` and a card never outranks a strictly-newer trigger (recency bound). Filtering by `FeedCategory` (the Lens bar) and the `Sessions-only` lens are pure post-filters on the result so F1 reuses them.
- Keep the registry **append-only by design** — F2/F3/F5/F6 add HR/media/milestone/insight recipes by registering new entries, never by editing the F0 ordering core (this is what makes the engine a true keystone).
- Everything is a value type with **no `@Model`/SwiftData/UIKit/SwiftUI import**. No persistence. No views.

## Output

- `ios/App/Snappet/Features/Feed/FeedCard.swift` — `FeedCard` + `FeedCardKind` + `FeedCategory` + `FeedCardPayload` + `ActivityRef` + `ShareTemplate` enum stubs.
- `ios/App/Snappet/Features/Feed/FeedComposer.swift` — the pure composer + eligibility/salience registry + recency-bounded ordering + lens post-filters, with the F0 recipe set (a1/a2/b1/b3/b5/c1/d1).
- `SnappetTests/FeedComposerTests.swift` — unit tests **including the cross-platform golden corpus** (a fixed set of raw sessions/logs/all-time inputs → the exact ordered eligible `FeedCard` kinds + salience tiers), authored as a shared fixture FA0 will replay verbatim (mirror the `KilterCreatedClimb` golden-vector discipline, `_locked-design.md:25`, `140`).
- `docs/knowledge-graph/data.js` — add the `feed-composer` node (type: engine) + a `feeds` edge placeholder (wired to surfaces in F1).

## Acceptance criteria

- [ ] `FeedComposer.compose(window: .allTime, …)` emits a1/a2 session cards (1:1 with sessions), plus b1 Grade PR, b3 Most-Climbs, b5 Streak, c1 Pyramid, d1 Weekly-Volume cards **only when their eligibility predicate is true**; an input lacking the trigger emits no card (no stub).
- [ ] Cards are ordered by `salience × recencyDecay`, **recency-bounded** so no card's effective position is older than its `anchorDate` trigger and PR > trend > routine session in salience.
- [ ] The Lens post-filters (`All` / per-category / `Sessions-only`) are pure and return the expected subsets.
- [ ] The golden-corpus test fixes raw inputs → an exact ordered list of `FeedCardKind`s + salience tiers; the fixture is structured so FA0 replays it byte-for-byte (shared-field inputs only).
- [ ] Tests cover: empty corpus (→ no cards, graceful), single session, multi-session ordering, a new send that *is* a Grade PR vs one that is not, a streak boundary, a pyramid below/at the ≥15-sends/≥3-grades threshold, and the recency-bound (an old high-salience PR never outranks a fresh session). XCTest green.
- [ ] **No HR, media, `attemptTimestamps`, or `SessionMedia` reference in F0** (those predicates are deferred to F2/F3/F5); adding them later requires only new registry entries, not engine edits.
- [ ] No `@Model`, no SwiftData/UIKit/SwiftUI import, no persistence, no view. App type-checks (Swift 6, 0 warnings). `decisions.md` updated (recency-bound formula + "no banding in v1" choice).

## Constraints

- On-device only; pure value type; plain-value inputs (no `@Model` parameters). Reads existing engines (`KilterSessionStats`, `KilterAllTimeStats`) — does **not** re-derive their math.
- Cross-platform golden corpus uses **shared fields only** (no iOS-only `hrSeries`/`SessionMedia`/`attemptTimestamps` in the F0 corpus) so FA0 reproduces it exactly.
- `FeedCard` is derive-on-read — no caching, no persistence in F0. v1 ordering stays simple/temporal; no banded memoization unless profiling later demands it (and only if byte-identical across platforms).

## Test plan

1. `xcodebuild test -scheme Snappet -destination 'platform=iOS Simulator,name=iPhone 16 Pro'` (or build `SnappetTests`) — `FeedComposerTests` green, existing `KilterAllTimeStatsTests`/`KilterSessionStatsTests` stay green.
2. Sanity: feed the golden corpus, print the ordered `FeedCardKind` list + salience tiers, and confirm by eye that PRs lead fresh sessions but never out-float a strictly-newer trigger; confirm an empty corpus yields zero cards.