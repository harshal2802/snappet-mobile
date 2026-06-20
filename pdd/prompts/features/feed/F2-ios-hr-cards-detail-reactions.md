# Prompt: F2 — iOS HR-deepened cards + CardDetailView + reactions/save + deep-link

**File**: pdd/prompts/features/feed/F2-ios-hr-cards-detail-reactions.md
**Created**: 2026-06-20
**Project type**: Native iOS feature (Swift / SwiftUI). Code lands in this repo.
**Chain**: PLAN.md → F2 (depends on F1 and F0b; the gate alongside F3/F5 for the iOS rich-card wave)
**Source**: GitHub epic "Recap Feed" → issue "F2 iOS HR cards + detail + reactions"
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`
**Design**: `/tmp/feed-dossier/_locked-design.md` §5 (e1/e2/e3 rows), §6.2 (Pillar 2: HR-deepened stats), §7 (degradation), §9 (reuse), §11 wireframes 11, 14, 19

## Goal

Deepen the feed with **heart-rate intelligence** and give every card a home: compose the three HR cards — **e1 Session Effort / Zones** (zone bar + Edwards TRIMP from `KilterSession.hrSeries`), **e2 Hardest-Effort Send** (the send that aligned to the session's effort peak, from `KilterSessionStats.timeline[].effort`), and **e3 Avg & Peak HR Trend** (across the last sessions with HR) — as new `FeedComposer` registry entries; build **`CardDetailView`** (the full polished card + climb-by-climb timeline + HR zone chart) reachable by tap; wire **inline reactions/save** (double-tap → `Reaction`, long-press → `SaveItem`, both append-only rows from F0b); and **deep-link** any session card into `KilterSessionDetail` / `WorkoutSessionDetail`. HR is iOS's flagship delight (Pillar 2, `_locked-design.md:196`): the feed only *surfaces* engine numbers — it never re-computes them — and e1's payload is a *simpler band* on Android by absence, never a chart that renders empty (`_locked-design.md:217-218`). New cards are added **only** as composer registry entries + `FeedCardKind` cases; the F0 ordering core is not edited (keystone rule, `_locked-design.md:228`).

## Context the implementer needs

- **Keystone rule — additive only.** e1/e2/e3 are new `FeedCardKind` cases (`e1Effort`, `e2HardestEffort`, `e3HRTrend`) + new `category` mappings (`.effort`/`.trend`) + new eligibility/salience registry entries inside `FeedComposer`. **Do not touch** F0's ordering/recency-bound/salience-sort core — register predicates, let the engine compose them (`_locked-design.md:24`, `228`). Each predicate declares its data dependency so it simply never composes when the field is absent (graceful degradation by construction, `_locked-design.md:24`).
- **e1 Session Effort / Zones** (`_locked-design.md:172`): eligible when the session has HR. iOS payload rides `HRStats.secondsByZone` + `edwardsTRIMP` derived from `KilterSession.hrSeries` (`HighlightEngine`; mirror of Android `HRSeries.kt:12`). Render a **stacked zone bar** banded on `HeartRateZone` colors via the `SnappetColor` performance/zone ramp (`SnappetColor.swift`, reuse — no new tokens). **Android note for the shared composer:** e1 degrades to an `avg/max/redline` *summary payload* — F2 is the iOS branch that fills the rich payload; do not assume the rich payload always exists.
- **e2 Hardest-Effort Send** (`_locked-design.md:173`, **iOS only**): eligible when `hrSeries` is non-empty AND a send aligns to an effort peak. Source is `KilterSessionStats.timeline[].effort` (`KilterSessionStats.swift:40`) — find the send entry coinciding with the peak `effort` window. Payload: `{grade, effortPeakBpm, zoneAtSend, sendTimeOffsetSec}`. Hard-gate to iOS via the *specific field absence* check (`hrSeries`/per-climb timing), not merely "has HR" (`_locked-design.md:219`).
- **e3 Avg & Peak HR Trend** (`_locked-design.md:174`): eligible with ≥3 sessions carrying HR. Payload is per-session HR summary points `{date, avgBpm, maxBpm}[]` → a small trend line. This one degrades cleanly to Android (summary fields exist), so keep its payload built from summary-level fields only.
- **`CardDetailView` (push, `_locked-design.md:44`):** the full polished stat card at top, then expandable deeper stats — **climb-by-climb timeline** (from `KilterSessionStats.timeline`) and an **HR zone chart** (from `HRStats.secondsByZone`). Media row and reactions strip render here too (media is F3-populated; in F2 it's the empty/absent slot). Reuse `KilterSessionStats`/`HRStats` verbatim — `CardDetailView` re-renders the same engine snapshot the card carried, it does not re-query math.
- **Reactions / Save (`_locked-design.md:59-60`, `105-111`, wireframe 19):** **double-tap** a card appends a `Reaction` row; **long-press** appends a `SaveItem` row to a collection — both via F0b's append-only writers keyed by `activityContentId`. Frame reactions as **private memory/curation** (react-as-note to your own session), NOT a hollow social like (`_locked-design.md:111`, `292`). `actorRef` stays `"self"`; `visibility` stays `private`. Show the reactions strip on both the card and the detail view.
- **Deep-link (`_locked-design.md:63`):** the card's "Open in module" / tap-through routes to `KilterSessionDetail` (for a1/e1/e2 Kilter cards) or `WorkoutSessionDetail` (for a2 cards) via the existing module navigation — dereference `FeedActivity.objectRef`/`objectKind` to the source session id. Do not duplicate the session model; navigate to the real screen.
- **No share, no auto-clip in F2** — `ShareComposerCover`/Animate is F4, inline media auto-clip is F3. The reactions strip and detail media row are the open slots those phases populate.
- **Files land in** `ios/App/Snappet/Features/Feed/` (F0/F1 created it). The card shell from `FeedSessionCard.swift` (F1) gains the HR sparkline slot and the double-tap/long-press gestures without changing its hero/ribbon layout.

## Approach

- `Feed/FeedHRCards.swift`: the e1/e2/e3 `FeedComposer` registry entries — pure eligibility predicates (HR presence / peak-alignment / ≥3-HR-session count), salience scores (e2 hardest-effort > e1 effort > e3 trend), and payload builders that *read* `HRStats.secondsByZone`/`edwardsTRIMP` and `KilterSessionStats.timeline[].effort`. Add `e1Effort`/`e2HardestEffort`/`e3HRTrend` to `FeedCardKind` and map their `FeedCategory`. **No edits to F0's ordering core.**
- `Feed/FeedHRCardViews.swift`: the SwiftUI card bodies — the stacked zone bar (e1), the hardest-effort send callout (e2), the avg/peak trend line (e3) — all on `.snappetCard()` + `SnappetColor` zone ramp, slotting the HR sparkline into the F1 `FeedSessionCard` shell.
- `Feed/CardDetailView.swift`: push destination — full card + expandable climb-by-climb timeline (`KilterSessionStats.timeline`) + HR zone chart (`HRStats.secondsByZone`) + reactions strip + media-row slot + "Open in module" button.
- `Feed/FeedInteractions.swift`: double-tap/long-press gesture wiring → F0b `Reaction`/`SaveItem` append writers; the reactions-strip view; optimistic local toggle. Pure "reaction/save state diff" helper kept testable.
- `Feed/FeedDeepLink.swift` (or extend F1's routing): `objectRef`/`objectKind` → `KilterSessionDetail`/`WorkoutSessionDetail` navigation mapping (pure, testable).
- Pure logic (peak-alignment for e2, zone-bar fractions for e1, trend-point reduction for e3, reaction/save diff, deep-link target mapping) goes in testable files; XCUITest covers tap-to-detail, double-tap react, long-press save, and Open-in-module.

## Output

- `Feed/FeedHRCards.swift` — e1/e2/e3 composer registry entries + `FeedCardKind` cases + category mapping (additive; no F0 core edits).
- `Feed/FeedHRCardViews.swift` — e1 zone bar / e2 hardest-effort callout / e3 trend-line card bodies on Pulse-Pro + zone ramp.
- `Feed/CardDetailView.swift` — full card + climb-by-climb timeline + HR zone chart + reactions strip + media slot + Open-in-module.
- `Feed/FeedInteractions.swift` — double-tap `Reaction` / long-press `SaveItem` gesture wiring + reactions strip + pure state-diff helper.
- `Feed/FeedDeepLink.swift` — `objectRef`/`objectKind` → `KilterSessionDetail`/`WorkoutSessionDetail` target mapping.
- `SnappetTests/FeedHRCardTests.swift` — e1 zone-bar fractions, e2 peak-alignment selection, e3 trend reduction, and eligibility-gating (no HR → e1/e2 never compose; <3 HR sessions → e3 never composes).
- `SnappetTests/FeedInteractionTests.swift` — reaction/save append + state-diff; deep-link target mapping.
- `SnappetUITests/FeedHRCardUITests.swift` — tap card → CardDetailView (timeline + zone chart) → double-tap react → long-press save → Open-in-module.
- `docs/knowledge-graph/data.js` — add `card-detail` (screen) node; `navigate` edge feed→card-detail, `navigate` edges card-detail→kilter-session-detail and card-detail→workout-session-detail, `uses` edges feed-composer→hr-stats and feed→feed-activity (reaction/save writes).

## Acceptance criteria

- [ ] e1/e2/e3 are added **only** as `FeedComposer` registry entries + new `FeedCardKind` cases — the F0 ordering/salience/recency core is unchanged (diff shows no edits to F0's compose loop).
- [ ] e1 renders a stacked HR zone bar (`HRStats.secondsByZone`) + Edwards TRIMP from `KilterSession.hrSeries`, banded on the `SnappetColor` zone ramp; with no HR, e1 never composes (no empty chart).
- [ ] e2 (iOS-only) surfaces the hardest-effort send chosen by peak alignment over `KilterSessionStats.timeline[].effort`; it never composes when `hrSeries`/per-climb timing is absent (specific-field gate, not "has HR").
- [ ] e3 composes only with ≥3 HR sessions and draws an avg/peak trend from summary-level fields; the math is unit-tested.
- [ ] Tapping a session card pushes `CardDetailView` = full card + expandable climb-by-climb timeline + HR zone chart, re-rendering the carried engine snapshot (no re-query).
- [ ] Double-tap appends a `Reaction` and long-press appends a `SaveItem` (F0b rows, `actorRef="self"`, `visibility=private`), framed as private memory/curation; the reactions strip reflects the new state.
- [ ] "Open in module" deep-links a1/e1/e2 cards to `KilterSessionDetail` and a2 cards to `WorkoutSessionDetail` via `objectRef`/`objectKind`.
- [ ] No share/auto-clip added in F2 (deferred to F3/F4); the card/detail media + reactions slots are open. App type-checks (Swift 6, 0 warnings); `decisions.md` updated.

## Constraints

- On-device only; derive-on-read (no card persistence). Reuse `HRStats`/`HeartRateZone`/`HRVMetrics`/`KilterSessionStats` and `PulsePro`/`SnappetCard`/`SnappetColor` verbatim — no new brand tokens, no re-derived stats in the view. New cards via the composer registry only — never by editing F0's ordering core (keystone rule).
- Reactions stay private memory/curation (`actorRef="self"`, `visibility=private`) — no social-like mimicry; `Reaction`/`SaveItem` are append-only rows from F0b. Hard-gate e2 to iOS by specific-field absence, not "has HR."

## Test plan

1. Unit: `FeedHRCardTests` (e1 zone fractions, e2 peak-alignment, e3 trend reduction, eligibility gating) + `FeedInteractionTests` (reaction/save append + diff, deep-link mapping) green; build-for-testing.
2. XCUITest: launch `--start-tab feed` on a seed with HR → assert e1 zone bar + e2 hardest-effort + e3 trend cards render → tap a card → assert `CardDetailView` shows timeline + zone chart → double-tap to react and long-press to save (assert strip updates) → "Open in module" lands on `KilterSessionDetail`. Sim wedge → `xcrun simctl shutdown all`, re-run.
3. Device-burn (flag, not sim-verifiable): real `hrSeries`/per-climb effort alignment for e1/e2 and module deep-link transitions on hardware — confirm zone bands and the chosen hardest-effort send match a real session.
