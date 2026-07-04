# Prompt: Quick Session full-screen pager (one exercise per page)

**File**: pdd/prompts/features/109-ios-quick-session-pager.md
**Created**: 2026-07-02
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: follow-on to the Quick Session redesign (prompts 01–14 in `quick-session-redesign/`) and
Workout-Type Parity (00–06) — this re-homes both into a new navigation shell.
**Source**: direct user feedback — "Quick session looks very cluttery and hard to navigate."
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Wireframes**: `docs/ux-research/quick-session-pager/wireframes.html` (user-approved 2026-07-02)

## Goal

Replace the freeform Quick Session's single long scrolling `List` of expandable entity cards with a
**horizontal full-screen pager — one exercise per page**, swiped L↔R in the order exercises were
added. The current set/attempt owns each page; previous efforts collapse to a quiet one-line ghost
ledger with the full history one pull away. Add an optional **planned-sets** axis per exercise.
Chrome goes Liquid-Glass: floating translucent nav, an exercise rail that doubles as the page
indicator, and a glass dock. This is a navigation-shell rewrite: every logging capability the list
player has today must survive.

## Context the implementer needs

- `FreeformPlayerView.swift` (~2,270 lines) is the whole player: a `NavigationStack` + `List` of
  per-discipline expandable sections, a `safeAreaInset` command bar, and a large retinue of sheets /
  covers / mutations (add climb/timed/strength/run, LogSetSheet, TimedAttemptCover, TimedSetCover,
  StructuredTimedRunner, Studio presentation, clip auto-discovery + deep-tap lifecycle, remembered
  rest timer, live milestones, Live Activity pushes). **The mutations, sheets, covers, media and
  Live-Activity plumbing stay; the body and section builders are replaced.**
- `SessionExercise` is a **Codable struct** (not `@Model`), so adding `var plannedSets: Int?`
  decodes as `nil` for existing data — no migration. Beware the Codable-default gotcha recorded in
  decisions.md: optional lets it be absent in old blobs.
- 16 XCUITest files reference `freeform.*` identifiers (110 uses). Controls that survive keep their
  identifiers (`freeform.addExercise`, `freeform.quickReps.plus`, `freeform.quickLog`,
  `freeform.outcome.<status>`, `freeform.gradePill`, `freeform.setRow`, `freeform.finish`,
  `freeform.repeatSet`, `freeform.addSet`, `freeform.logLeg`, `freeform.timedName`, menus…).
  Expansion-shaped identifiers (`freeform.expand`, `freeform.climbExpand`) disappear — the pager
  makes every control visible on its page; affected tests navigate via the rail instead.
- The Clips feed taught us TabView paging hazards (memory: plain `@State` re-rendering every page).
  Session pages are light (no AVPlayer), but keep page content lazy and the selection state simple.
- Two-axis color contract (`SnappetColor.swift`): discipline accents = wayfinding only; `brand`
  coral = the single primary CTA per page; perf ramp = state. The glass kit idioms live in
  `PulsePro.swift` / the HR overlay glass work.

## Approach

1. **Pure logic first** — `QuickSessionPager.swift`: `Page` enum (`overview` / `exercise(UUID)` /
   `add`), `pages(for:)` in added order, rail-chip model (symbol · short name · progress ·
   done flag), plan progress `(done, planned?)`, `nextIncomplete(after:)` for the plan-complete
   nudge, short-name derivation. Unit-tested in `SnappetTests` without a simulator.
2. **Model** — `plannedSets: Int?` on `SessionExercise`; segments render from
   `(completedSetCount, plannedSets)`. Plan editor defaults from last session's set count for the
   same `exerciseId` (pure helper + test).
3. **Shell** — `FreeformPlayerView.loggingContent` becomes a `TabView(selection:)` with
   `.page(indexDisplayMode: .never)` inside the existing `NavigationStack` (nav bar hidden):
   glass nav (minimize ⌄ · title + elapsed/HR · Finish pill), exercise rail (tap-to-jump), glass
   dock (HR chip → metrics panel, rest chip, pause, camera on exercise pages). Auto-advance to a
   newly added exercise's page. Overview page hosts the session title field, elapsed hero,
   roll-up chips (climb ribbon re-homed), per-exercise jump rows with segments, big Finish.
   Add page hosts the type cards (`freeform.card*` preserved) + recents.
4. **Discipline pages** — one shared skeleton (title + plan row + hero + CTA + ghost ledger):
   strength (big steppers seeded by `quickAddSeed`, Log CTA, Time this set, rest-morph hero),
   climb (grade pill, outcome buttons, timed attempt, clips), timed (embedded stopwatch for simple
   modes; structured specs keep the `StructuredTimedRunner` cover, launched from the page hero),
   run (distance + time steppers → Log leg). Dance/other reuse the timed page.
5. **Drawers** — history drawer (`.sheet` + detents): full set list w/ per-set delta vs last
   session (pure helper), swipe-to-delete, edit via existing sheets; plan stepper sheet; media
   shelf (exercise-scoped strip reusing `SetMediaStrip`'s thumb + deep-tap menu) between hero and
   ledger; guide-photo drawer from ⓘ (`GuidePhotoPager`).
6. **Docs** — knowledge-graph nodes/edges for the pager surface; decisions.md entries (pager over
   list, plannedSets axis, identifier-preservation strategy, media-shelf placement).

## Output

- `ios/App/Snappet/Features/WorkoutTracker/QuickSessionPager.swift` — pure page/rail/plan logic.
- `ios/App/Snappet/Features/WorkoutTracker/FreeformPlayerView.swift` — pager shell + pages
  (mutations/sheets/covers preserved).
- New page/chrome subviews as needed (same directory), reusing SnappetColor/PulsePro tokens.
- `ios/App/Snappet/Features/WorkoutTracker/WorkoutModels.swift` — `plannedSets: Int?`.
- `ios/App/SnappetTests/QuickSessionPagerTests.swift` — pages/rail/plan/nudge/delta tests.
- Updated XCUITests where navigation changed; identifiers preserved where controls survive.
- `docs/knowledge-graph/data.js`, `pdd/context/decisions.md` updated.

## Acceptance criteria

- [ ] Every capability of the list player works in the pager: add all six types, log
      sets/attempts/legs/holds, timed covers, structured runner, repeat, edit details, remove,
      rest timer, milestones, Live Activity, clips (record/attach/reassign/delete/Studio),
      finish → type-adaptive summary, minimize/resume.
- [ ] Swiping L↔R pages overview → exercises (added order) → add page; rail jumps; new exercise
      auto-advances to its page.
- [ ] Planned sets: editable per exercise (strength/timed/run), segments fill as sets log,
      plan-complete nudge advances to the next unfinished exercise; climbs show no plan row.
- [ ] Current effort dominates each page; previous sets render only as the ghost ledger +
      history drawer (with vs-last-time deltas).
- [ ] Unit suite green; UI suite green after test updates.
- [ ] App changes type-check against the iOS SDK (Swift 6, 0 warnings).
- [ ] `decisions.md` + knowledge graph updated in the same change.

## Constraints

- On-device only; no backend. `HighlightEngine` untouched.
- Keep `SessionExercise` Codable-compatible (optional new field only).
- No gesture conflicts: hero inputs are tap targets, never horizontal drags.
- Single coral CTA per page; discipline accents for wayfinding only.

## Test plan

1. `make ios-test SIMULATOR='iPhone 17 Pro'` — unit suite (pager logic tests included).
2. UI suite on the simulator after test updates (real UI change ⇒ policy requires it).
3. Simulator walkthrough: start Quick Session → add strength + climb + timed → swipe/jump, log
   from each hero, plan 3 sets and complete them, open history drawer, finish → summary.
4. Device-pending: live HR chip, clip record/auto-discovery (Photos), Live Activity.
