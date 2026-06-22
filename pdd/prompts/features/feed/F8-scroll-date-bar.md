# Prompt: Recap Feed F8 — scroll date bar (time orientation)

**File**: pdd/prompts/features/feed/F8-scroll-date-bar.md
**Created**: 2026-06-21
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: PLAN.md → F0–F7 (shipped) + R13 cleanup → F8 (additive feature)
**Source**: User feedback — “as I scroll the Recap feed there's no timestamp indicator, it's easy to get lost.”
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Give the infinite Recap feed a **time anchor while scrolling** so you never lose your place. Wireframe-
approved design (`docs/ux-research/feed/wireframes-timestamp-c.html`): **one adaptive date bar** —
calm at rest, informative while moving, never covering a card.

## Context the implementer needs

`FeedView` is a single `ScrollView` whose stories rail + lens bar **scroll away** (no pinned header) and
whose large nav title collapses on scroll. So a persistent header-zone bar would either cover content or
need a layout rebuild. Instead the bar is a **top overlay on the ScrollView** that:
- is **hidden at the very top** (the large nav title is the anchor there);
- once scrolled past the header, shows an **era “whisper”** (just the bucket label, transparent);
- while **actively scrolling** reveals the **topmost visible card's exact day** + a glass backing + a
  thin progress underline, then recedes to the whisper ~1.2s after the finger lifts.

Cards are recency-bounded (≈reverse-chronological) and each carries an `anchorDate` — the bar just
surfaces that. The feed had **no** scroll-tracking code (the R2 inline-autoplay scroll-center detection
was removed in R12), so this introduces the first use of the iOS 18 scroll APIs here.

## Approach

- **Pure orientation logic** (`FeedTimeBucket.swift`, Foundation only, unit-tested — the project rule):
  `FeedTimeBucket.label(for:now:calendar:)` → `FeedDateLabel(era, day)`. Buckets: Today · Yesterday ·
  This week (2–6 days) · Earlier in `<Month>` (this calendar month) · `<Month Year>`. Day = "EEE '·' MMM d".
  Locale/timezone come from the injected calendar (tests pin en_US + UTC). Future dates clamp to Today.
- **View** (`FeedDateBar.swift`): layout-only; era whisper ↔ revealed (glass + day + progress underline).
  Maps no logic — takes a `FeedDateLabel`, a `revealed` Bool, and a `progress` 0…1.
- **Wiring** (`FeedView.swift`): track the topmost visible card via each row's **top-edge crossing** in a
  named coordinate space (`onChange(of: minY<=0 && maxY>0)` — fires per-crossing, not per-frame, action on
  the main actor, so no preference-key `@Sendable` concurrency issue); track scroll offset/depth via
  `onScrollGeometryChange`; flip `scrolling` via `onScrollPhaseChange`; a `.task(id: scrolling)` lingers the
  reveal ~1.2s after settle. Bar shown when `layout == .list && scrollY > 120 && dateLabel != nil`.

## Output

- **New**: `FeedTimeBucket.swift` (pure), `FeedDateBar.swift` (view), `SnappetTests/FeedTimeBucketTests.swift`.
- **Edited**: `FeedView.swift` (scroll state + per-row crossing + the bar overlay).
- **KG**: add the `feed-date-bar` component node + a `feed → feed-date-bar (contains)` edge; note F8 on the
  `feed` node.

## Acceptance criteria

- [ ] Bar is hidden at the very top; appears as an era whisper once scrolled past the stories/lens header.
- [ ] While scrolling it shows the **topmost visible card's** exact day + glass + progress; recedes ~1.2s after.
- [ ] Era/day strings come ONLY from the pure `FeedTimeBucket`; `FeedTimeBucketTests` pins all buckets + day format.
- [ ] No per-frame state thrash: topmost tracking fires on card-crossing only; scroll APIs are main-actor (no preference keys).
- [ ] List layout only (the masonry wall is untouched); `feed.dateBar` accessibility id + label present.
- [ ] App type-checks (Swift 6, 0 warnings); full `SnappetTests` green; Feed XCUITests green.
- [ ] Keystone untouched: `FeedComposer`/ordering unchanged. `decisions.md` + KG updated.

## Constraints

- Additive + behavior-preserving for everything else; no new card kinds, no card persistence, no store writes.
- Pure logic stays device-free; the view is layout-only; no platform imports in the pure file.
- Reuse the existing Pulse tokens (`SnappetColor.ink`/`textSecondary`/`kilter`/`workout`/`hairline`, `SnappetSpacing.lg`).

## Test plan

- `cd ios/App && xcodegen generate && xcodebuild build-for-testing -scheme Snappet …` (0 errors).
- `FeedTimeBucketTests` green; full `SnappetTests` green; FeedView/FeedWall XCUITests green (real UI change).
- Manual device burn on MrRobot — scroll a long feed and confirm the whisper→reveal→recede behavior + bucket flips.
