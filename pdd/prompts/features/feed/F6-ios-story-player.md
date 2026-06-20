# Prompt: F6 — iOS RecapStoryCover (Wrapped grammar) + Stories rail + insight/recap cards

**File**: pdd/prompts/features/feed/F6-ios-story-player.md
**Created**: 2026-06-20
**Project type**: Native iOS feature (Swift / SwiftUI). Code lands in this repo.
**Chain**: PLAN.md → F6 (depends on F5; the last iOS-wave insight/recap phase)
**Source**: GitHub epic "Recap Feed" → issue "F6 iOS Story Player + insight/recap cards"
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`
**Design**: `/tmp/feed-dossier/_locked-design.md` §3 (IA sub-surface 4 + flow), §5 (card taxonomy F6 rows), §6.4 (Pillar 4 cross-session insights), §7 (degradation), §8 (phase F6), §9 (reuse), §11 wireframes 8, 10, 12, 13 (#8 prototype-first)

## Goal

Activate the pinned **Stories rail** at the top of `FeedView` and ship the **`RecapStoryCover`** — a full-screen Spotify-Wrapped-grammar scene player (tap-through, hold-to-pause, tap-left/right back/forward) that **re-runs the F0 `FeedComposer` scoped to a period** (`.thisWeek` / `.thisMonth` / `.thisYear`) and composes its scenes from whatever the user actually has: sparse period = 3 scenes, rich = 8 (`_locked-design.md:45`, `186`). This is the single highest-wow, highest-execution-risk surface in the whole initiative (`_locked-design.md:286`), so it ships per-scene shareability and prototype-first. In the same PR, land the remaining cross-session **insight cards** — the full Pillar-4 menu (`_locked-design.md:200`) — as new **`FeedComposer` registry entries + `FeedCardKind` cases** and their SwiftUI views, never by editing the F0 ordering core. This closes the iOS insight/recap menu so the feed truly "composes itself from whatever the user has."

## Context the implementer needs

- **One engine, two callers (the keystone graft, `_locked-design.md:27`):** the infinite feed already calls `FeedComposer.compose(window: .allTime)`; the Story Player is the **second caller** — `FeedComposer.compose(window: .thisWeek/.thisMonth/.thisYear)`. F6 adds **no new ordering logic**; it asks the existing composer for a period-scoped eligible card set and maps those cards to full-bleed scenes. Keystone rule (`_locked-design.md:228`, F1 prompt): new cards are added **only** as registry entries + `FeedCardKind` cases — do not touch the F0 compose/sort core.
- **Stories rail (F1 left a placeholder):** F1 ships a non-interactive period-cover strip with real period labels (F1 prompt, `_locked-design.md:42`). F6 **activates** it: the three pinned covers ("This Week" · "This Month" · "Year in Climb") become live entries that present `RecapStoryCover` for their window. A cover is shown only when its recap is eligible (`weeklyRecap` ≥1 session this week; `monthlyRecap` ≥1 this month; `yearInClimb` ≥6 months history — `_locked-design.md:184-186`); an ineligible period cover degrades **by absence**, not a dead button.
- **Scene composition (`_locked-design.md:45`, wireframe 8):** map the period-scoped eligible `FeedCard`s into ordered scenes by salience, clamped to **3 (sparse) … 8 (rich)**. Year-in-Climb canonical arc (wireframe 8): cover → grade-journey/progression → pyramid reveal, growing to hardest-send, volume, angle, streak, effort, on-this-day as data allows. Each scene is a discipline-typed view built from `PulsePro` chrome (`pulseGlassChrome`, `DisciplineHero`, `StatRibbon`, `_locked-design.md:271`) on `SnappetColor` tokens — reuse, do not reinvent.
- **Wrapped grammar (sub-surface 4, `_locked-design.md:45`):** tap-right / tap-left advance/rewind; hold-to-pause the auto-advance timer; per-scene progress bars across the top (Instagram-Stories segment bars); swipe-down to dismiss. Auto-advance is a per-scene timer (pure duration policy, unit-testable) that pauses on touch-down and resumes on touch-up. This is **device-burn-light** (no AVFoundation), so most of it is sim-testable via XCUITest gestures.
- **Per-scene share (`_locked-design.md:46`, `66`, `287`):** each scene has a Share affordance that hands the *current scene's* `FeedCard` to the `ShareComposerCover` (F4) — pre-selecting that card's `shareHint` template at 9:16. F6 **does not** rebuild the composer; it routes into the F4 cover. The Story Player must feel complete even at 3 scenes because every scene is independently shareable.
- **Remaining insight cards (the F6 rows of §5, `_locked-design.md:164-186`)** — each is a new `FeedCardKind` case + registry entry (eligibility/salience/payload) + a SwiftUI view, all riding existing engines:
  - **c2 Pyramid Health** — row narrower than the row above (top-heavy heuristic over c1) → plain-language nudge over `KilterAllTimeStats.pyramid` 🟡 (wireframe 10).
  - **c3 Grade Progression** — ≥3 months of sends → `KilterAllTimeStats.maxGradeProgression` ✅.
  - **c4 Climbing Level** — ≥20 recent sends → `KilterAllTimeStats.climbingLevelLabel` ✅.
  - **c5 Angle Distribution** — sends at ≥2 angles → `KilterAllTimeStats.angleDistribution` ✅.
  - **d2 This Period vs Last** — two consecutive non-empty periods → `KilterAllTimeStats.week/monthRollups` ✅. (d1 Weekly Volume Trend is F0/F5; extend the trend family here for d2–d4.)
  - **d3 Discipline Split** — ≥2 disciplines in window → cross-session `disciplineRaw` roll-up 🟡 (the small `TodayDigest`-pattern workout aggregate, `_locked-design.md:200`, `276`).
  - **d4 Trend Arrows** — ≥90 days history → 90-day rolling avg vs baseline ✅.
  - **e4 Effort-vs-Grade Efficiency** — ≥3 sessions, full `hrSeries`, same grade band → "sending V6 at lower HR than 3 mo ago" from `KilterSessionStats.timeline[].effort` + `HRStats` 🟡 **iOS-only** (hard-gate; `hrSeries`-specific eligibility, `_locked-design.md:175`, `217-219`).
  - **e5 HRV / Recovery Nudge** — RR intervals present (chest strap) → `HRVMetrics` from `rrIntervalsMs` 🔶 (rarely eligible; `_locked-design.md:176`).
  - **consistencyMap** — ≥14 active days → per-day counts ✅ (wireframe 12).
  - **restNudge ("Go Gentler")** — N high-effort days w/o rest → HR-load 🔶; **protective framing**, never shame (`_locked-design.md:180`, `200`, wireframe 12).
  - **onThisDay** — a send/session on this date in a prior year → dated log ✅; framed as private memory (react-as-note), not a social like (wireframe 13, `_locked-design.md:111`, `292`).
  - **g1 Project Sent** — climb `.project`→`.sent`/`.flash` → iOS `attemptTimestamps` rich cadence 🟡 (iOS rich; the Android session-count fallback is FA-wave, `_locked-design.md:183`, `216`).
- **Degrade by absence, hard rules (`_locked-design.md:217-219`):** e4/e5 check the *specific field* (`hrSeries` non-empty / `rrIntervalsMs` present) in eligibility, not merely "has HR." A period-scoped recap silently drops scenes whose cards aren't eligible — a 3-scene sparse Year-in-Climb is correct, not broken. No card floats older than its `anchorDate` trigger (recency bound, `_locked-design.md:13`, `287`).
- **Wireframe-first (the rule that "applies hardest here", `_locked-design.md:286`, `299`):** prototype the Story Player (wireframe #8 Year-in-Climb) as a real-token HTML→PNG under `docs/ux-research/feed/wireframes/` **before** building the SwiftUI, per the standing wireframe-before-implementation rule.
- New views land in `ios/App/Snappet/Features/Feed/` (F0 created it; F1–F5 populated it).

## Approach

- **Wireframe first:** render `docs/ux-research/feed/wireframes/08-story-year-in-climb.png` (real `SnappetColor`/Pulse-Pro tokens, dark-mode-first, the 3-scene cover→progression→pyramid arc) before any Swift.
- `Feed/RecapStoryCover.swift`: the full-screen scene player — segment progress bars, tap-left/right, hold-to-pause, swipe-down dismiss, per-scene Share routing into the F4 `ShareComposerCover`. Presented over `FeedView` from a Stories-rail cover tap.
- `Feed/StoryScene.swift`: the per-scene view that renders one period-scoped `FeedCard` full-bleed on `PulsePro.pulseGlassChrome` + `DisciplineHero`/`StatRibbon`; a scene-type switch over `FeedCardKind`.
- `Feed/StoryComposition.swift`: a **pure** mapper — given the F0 `compose(window:)` output, produces an ordered, 3…8-clamped `[StoryScene.Model]` by salience + the canonical Year-in-Climb arc. No new card math; pure and unit-tested.
- `Feed/StoryPlayback.swift`: a **pure** auto-advance/pause state machine (per-scene duration policy, index advance/rewind, pause/resume) — unit-tested without UI.
- `Feed/FeedStoriesRail.swift`: activate F1's placeholder strip — eligible period covers that present `RecapStoryCover`; ineligible covers absent.
- **Insight cards as registry entries:** add the new `FeedCardKind` cases (c2–c5, d2–d4, e4, e5, consistencyMap, restNudge, onThisDay, g1) and register their eligibility/salience/payload builders in the F0 `FeedComposer` **registry only** (not the ordering core). Add the small cross-discipline workout aggregate following `TodayDigest`'s pure pattern (`TodayDigest.swift`) for d3. Each card gets a view: `Feed/Cards/PyramidHealthCard.swift`, `ProgressionCard.swift`, `ClimbingLevelCard.swift`, `AngleDistributionCard.swift`, `PeriodVsLastCard.swift`, `DisciplineSplitCard.swift`, `TrendArrowsCard.swift`, `EffortEfficiencyCard.swift`, `HRVRecoveryCard.swift`, `ConsistencyMapCard.swift`, `RestNudgeCard.swift`, `OnThisDayCard.swift`, `ProjectSentCard.swift`. (Group small views to keep file count sane; one file per card-family is acceptable.)
- Pure logic (scene composition, playback state, the new eligibility predicates, the d3 aggregate) lives in testable files; XCUITest covers rail → story → tap-through → hold-pause → per-scene share flow.

## Output

- `docs/ux-research/feed/wireframes/08-story-year-in-climb.png` — prototype-first Story Player wireframe (real tokens).
- `Feed/RecapStoryCover.swift` — full-screen Wrapped-grammar scene player (tap/hold/left-right/swipe-down, segment bars, per-scene Share → F4).
- `Feed/StoryScene.swift` — per-scene full-bleed `FeedCard` view (Pulse-Pro chrome, kind switch).
- `Feed/StoryComposition.swift` — pure period-scoped scene mapper (3…8 clamp, Year-in-Climb arc).
- `Feed/StoryPlayback.swift` — pure auto-advance/pause/index state machine.
- `Feed/FeedStoriesRail.swift` — activated Stories rail (eligible period covers present `RecapStoryCover`).
- `Feed/Cards/InsightCards.swift` (+ family files as above) — SwiftUI views for c2–c5, d2–d4, e4, e5, consistencyMap, restNudge, onThisDay, g1.
- `FeedComposer` registry — new `FeedCardKind` cases + eligibility/salience/payload entries for the F6 cards (registry only; ordering core untouched). Plus the small `TodayDigest`-pattern cross-discipline workout aggregate for d3.
- `SnappetTests/StoryCompositionTests.swift` + `SnappetTests/StoryPlaybackTests.swift` — pure 3…8 clamp / arc-order + advance/rewind/pause/resume tests.
- `SnappetTests/F6InsightCardEligibilityTests.swift` — eligibility predicate tests for each new card incl. e4/e5 `hrSeries`/`rrIntervalsMs`-specific gating (degrade-by-absence) and recency-bound `anchorDate`.
- `SnappetUITests/RecapStoryUITests.swift` — rail → present story → tap-through to last scene → hold-to-pause → per-scene Share opens composer → swipe-down dismiss restores feed scroll.
- `docs/knowledge-graph/data.js` — add `story-player` node; `navigate` edge feed→story-player (Stories rail), `uses` edge story-player→feed-composer, `navigate` edge story-player→feed-export (per-scene Share → ShareComposer); add the new insight cards as `feeds` edges feed-composer→feed (or a single `feed-insights` node if a cluster is cleaner).

## Acceptance criteria

- [ ] Tapping a Stories-rail cover presents `RecapStoryCover` for that window; the player re-runs `FeedComposer.compose(window:.thisWeek/.thisMonth/.thisYear)` and composes **3 (sparse) … 8 (rich)** scenes — verified by a pure composition test at both bounds.
- [ ] Wrapped grammar works: tap-right/left advance/rewind, hold-to-pause freezes the auto-advance timer and resumes on release, top segment progress bars track position, swipe-down dismisses and restores the exact `FeedView` scroll offset.
- [ ] Each scene has a Share affordance that opens the F4 `ShareComposerCover` pre-selecting that scene's card `shareHint` at 9:16 (no new composer built in F6).
- [ ] A period whose recap is ineligible shows **no** rail cover (degrade-by-absence, not a dead button); a 3-scene sparse Year-in-Climb renders correctly.
- [ ] All F6 insight cards (c2–c5, d2–d4, e4, e5, consistencyMap, restNudge, onThisDay, g1) compose as new `FeedCardKind` registry entries — **the F0 ordering core is not edited** — and render on Pulse-Pro/`SnappetColor` tokens.
- [ ] e4/e5 gate on the **specific field** (`hrSeries` non-empty / `rrIntervalsMs` present), are **iOS-only** for workout-effort paths, and never compose an empty chart on missing data; restNudge/onThisDay use protective/private-memory framing.
- [ ] No card floats older than its `anchorDate` trigger; pure scene/playback/eligibility logic is unit-tested; app type-checks (Swift 6, 0 warnings); `decisions.md` updated.

## Constraints

- On-device only; derive-on-read (no card persistence). New cards via `FeedComposer` registry + `FeedCardKind` cases **only** — never edit the F0 compose/sort core (keystone rule). Reuse `KilterAllTimeStats`/`KilterSessionStats`/`HRStats`/`HRVMetrics`/`PulsePro`/`SnappetCard`/`SnappetColor` verbatim; the feed only *surfaces* their numbers — no stat re-derivation in views.
- Story Player auto-advance/playback is pure and sim-testable; only the per-scene **Share** export tail (the F4 `ReelExporter`/`UIActivityViewController` path) is **device-burn** — flag it, do not block F6 on it. Wireframe the Story Player (#8) before coding it.
- Degrade by absence everywhere (no greyed buttons / "coming soon" stubs); recency-bound every card.

## Test plan

1. Unit: `StoryCompositionTests` (3…8 clamp + Year-in-Climb arc order from a seeded period-scoped corpus), `StoryPlaybackTests` (advance/rewind/pause/resume/index bounds), `F6InsightCardEligibilityTests` (each predicate, e4/e5 field-specific gating, recency-bound `anchorDate`) green; build-for-testing.
2. XCUITest: launch `--start-tab feed` → tap a Stories-rail cover → assert `RecapStoryCover` presents → tap-through to the last scene → hold-to-pause then release → tap a scene's Share → assert `ShareComposerCover` opens → swipe-down → assert feed scroll offset restored. Sim wedge → `xcrun simctl shutdown all`, re-run (per UITest flake memo).
3. Device-burn (flag, not gating): per-scene Share render-to-image/clip + IG Stories handoff verified on MrRobot (AVFoundation/Photos/share-sheet are not sim-faithful).
4. Sanity by eye: compare the rendered Story scenes against `docs/ux-research/feed/wireframes/08-story-year-in-climb.png`.
