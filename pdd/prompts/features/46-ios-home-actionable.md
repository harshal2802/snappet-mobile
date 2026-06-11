# Prompt: Turn Home into an actionable daily home with a first-run flagship spotlight

**File**: pdd/prompts/features/46-ios-home-actionable.md
**Created**: 2026-06-10
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Product-review roadmap [#100](https://github.com/harshal2802/snappet-mobile/issues/100) → Wave 2 (iOS)
**Source**: GitHub issue [#71](https://github.com/harshal2802/snappet-mobile/issues/71)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

The default tab is 100% read-only telemetry: activity-feed rows aren't tappable, stat tiles
do nothing, and Home structurally *cannot* navigate — `SuiteRouter` lives as `@State` inside
the Apps tab's `NavigationStack`, so nothing outside that tab can push a route. First launch
is an empty dashboard pointing at the Apps tab, where the flagship pitch (workout highlight
reels) is one of 9 equal cards; the Home glyph (`square.grid.2x2.fill`) reads as "app grid"
and invites the wrong first tap. Make Home the place the day starts: actionable Today cards
over live module data, feed rows that open their module, and a first-run flagship CTA that
lands in Workout Reels onboarding.

## Context the implementer needs

- `RootShell.ShellTabs` owns the tab selection (`--start-tab apps` QA hook = a literal
  `"apps"` launch argument — Kilter/Tip UI tests pass it); `AppLibraryView` creates the
  `SuiteRouter` and injects it only into its own subtree. Mini-app roots are pushed into
  that stack and read `@Environment(SuiteRouter.self)`.
- The hoist is the prerequisite for #75 (QR deep links) and #81 (App Intents / Spotlight) —
  design it so a deep link could enter from **outside** any tab.
- Today-card data already lives in the shared store: `Habit`/`HabitCompletion`,
  `PomodoroSession` (completed focus blocks), `BudgetCategory`/`BudgetTransaction` +
  `MonthScope`, `WorkoutSession` (`completedAt == nil` = the active session WorkoutTracker's
  own resume banner uses), `KilterLogEntry` → `KilterClimbLog.from` → the pure
  `KilterRecommender.workingDifficulty`.
- On a fresh install `AppModel.phase == .onboarding`, so deep-linking into the `workout`
  module *is* landing in Workout Reels onboarding — no new onboarding state needed.
- XCUITests to keep green: `SuiteSmokeTests` (taps `moduleCard.*` by id),
  `JournalUITests.testTabSwitchWhileComposingKeepsTheEntry` (tab switch must not reset the
  Apps stack), every test that taps `tabBars.buttons["Apps"]`, and the `apps` /
  `-uiTestFreshStore` / `-screenshotModule` launch args.

## Approach

1. **Hoist the router.** `SuiteRouter` gains the top-level tab (`SuiteTab`) and an
   `open(module:)` deep-link entry (jump to Apps, *replace* the path with the module root —
   repeated entries can't pile a stale stack; deeper screens are typed `push`es on top).
   `RootShell` owns it (`apps` launch arg seeds the initial tab) and injects it shell-wide;
   `ShellTabs` binds `TabView(selection:)` to `router.tab`; `AppLibraryView` binds its
   `NavigationStack` to the hoisted path — Apps-tab navigation behaves identically.
2. **`TodayDigest`** (new, `Features/Home/`, Foundation-only): pure functions over model
   rows — `habitsToday`, `resumeWorkout`, `focusToday`, `budgetPace`, `climbPlan` — each
   returning `nil` when the module has no data (the card's render gate), with `now` +
   `calendar` injected. Unit-tested in `SnappetTests/TodayDigestTests` (in-memory
   `ModelContainer`, held for the test's lifetime).
3. **Home**: an "Up next" section of tappable cards (habits left / resume workout / focus
   minutes / budget pace / plan a climb session) that `router.open(...)` into their module
   (the Kilter card pushes `KilterPlanRoute` on top); feed rows become Buttons that open
   the module that logged them (rows for retired module ids stay plain); the empty state
   becomes a flagship CTA hero (`home.flagshipCTA`) deep-linking into `workout`.
4. **App Library**: a featured flagship hero card above the category grid (same
   `ModuleRoute` push, so opening it logs identically; the grid card stays — the smoke
   test and muscle memory both expect it). Home tab glyph → `house.fill`.
5. Knowledge graph: `today-digest` node + Home→module `navigate` edges, updated shell/router
   descriptions, in the same change.

## Output

- `ios/App/Snappet/Core/SuiteRouter.swift` — `SuiteTab`, `tab`, `open(module:)`.
- `ios/App/Snappet/Features/Shell/RootShell.swift` — router ownership + injection,
  tab binding, `house.fill` glyph, screenshot hook binds the same router path.
- `ios/App/Snappet/Features/AppLibrary/AppLibraryView.swift` — environment router +
  featured flagship card (`appLibrary.flagship`).
- `ios/App/Snappet/Features/Home/TodayDigest.swift` (new) — the pure derivations.
- `ios/App/Snappet/Features/Home/HomeDashboardView.swift` — Up next cards
  (`home.today.*`), tappable feed rows (`home.feedRow.<module>`), flagship hero.
- `ios/App/SnappetTests/TodayDigestTests.swift` (new) — derivation coverage.
- `docs/knowledge-graph/data.js`, `pdd/context/decisions.md`, `pdd/context/project.md`.

## Acceptance criteria

- [ ] Tapping an activity-feed row opens the corresponding module.
- [ ] At least three Today cards render from live queries and route correctly
      (habits remaining, resume workout, start focus).
- [ ] Fresh install shows a flagship CTA that lands in Workout Reels onboarding.
- [ ] Existing Apps-tab navigation unchanged; `apps` / `-uiTest*` / `-screenshotModule`
      launch args still work; the listed XCUITests stay green.
- [ ] `docs/knowledge-graph/data.js` gains the new Home→module edges.
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).
- [ ] No platform imports added to `HighlightEngine` (untouched).
- [ ] `decisions.md` updated (hoist shape, render gates, two-level Kilter push).

## Constraints

- On-device only; no backend/network/accounts. `TodayDigest` stays Foundation-only —
  no SwiftUI/SwiftData imports, no clock reads (callers pass `now`/`calendar`).
- New interactive elements carry `accessibilityIdentifier`s.
- State verification honestly: parse/typing ≠ a simulator run; the two-level Kilter
  push (module root + `KilterPlanRoute` in one transaction) needs a simulator check.

## Test plan

1. `SnappetTests/TodayDigestTests` — every derivation incl. the `nil` render gates,
   month proration at a fixed clock, orphaned-transaction exclusion, working-grade label.
2. Simulator (orchestrator): fresh store → flagship hero → CTA lands in Workout Reels
   onboarding; seed habit/workout/pomodoro data → three cards render + route; feed row
   tap opens its module; full XCUITest suite (smoke + journal tab-switch + kilter `apps`
   launches) stays green.
