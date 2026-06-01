# Prompt: Budget — edit transactions, month switcher & 6-month trends

**File**: pdd/prompts/features/17-ios-budget-edit-trends.md
**Created**: 2026-05-31
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: suite feature-completeness pass (P9 follow-up); one of six parallel mini-app increments.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md` (§"Adding a mini-app"), `pdd/context/decisions.md`.

## Goal

Make Budget useful beyond the current month: let users **edit a transaction** (amount/note/date — only
delete exists today), **navigate to other months** (everything is hard-scoped to the current calendar
month), and see a **6-month spending trend** chart. The donut-by-category and per-category progress already
work for "this month".

## Context the implementer needs

- Folder: `ios/App/Snappet/Features/Budget/` — `BudgetRootView.swift`, `BudgetModels.swift`
  (`BudgetCategory`, `BudgetTransaction`), `BudgetCategoryRow.swift`, `BudgetCategoryEditor.swift`,
  `AddTransactionView.swift`, plus the inline summary tiles, `SpendByCategoryChart`, `MonthScope`, and
  `BudgetModule`. Both `@Model`s are registered in `Core/SnappetCore.swift` — **no model change needed**.
- `MonthScope` (the current-month window) drives all filtering. Generalize it to an arbitrary
  selected month (`Date` anchor) instead of always `.now`; keep deletions cascade-correct.
- `BudgetTransaction` already supports a backdated `date`, so the data spans months — only the UI is
  pinned to "now".
- Pushed into the App Library's `NavigationStack`; **no nested `NavigationStack`**. Editors are sheets;
  trends can be a pushed screen.

## Approach

- **Month switcher** — a header with prev/next chevrons + the month label; drive the selected month from
  `@State` and feed it through `MonthScope` so summary tiles, category progress, and the donut reflect the
  chosen month. Disable "next" beyond the current month (optional).
- **Edit transaction** — reuse `AddTransactionView` for editing (pass an optional `BudgetTransaction`);
  saving updates amount/note/date. Add an Edit affordance (swipe / context menu) wherever transactions are
  listed; if there's no transaction list yet, add a per-category transactions list reachable from the row.
- **6-month trend** — new `BudgetTrendsView.swift`: a Swift Charts `BarMark` of total spend per month for
  the last 6 months (optionally stacked/segmented by category). Aggregate in a helper, not the view body.
- Add `.accessibilityIdentifier(...)`: month prev/next (`budget.prevMonth`/`budget.nextMonth`), add-category
  (`budget.addCategory`), add-transaction (`budget.addTxn`), edit-transaction (`budget.editTxn`), trends
  link (`budget.trends`), summary tiles (`budget.total`/`budget.spent`/`budget.remaining`), and the
  category rows (`budget.category.<name>`).

## Output

- New `Features/Budget/BudgetTrendsView.swift`; generalized `MonthScope` + month header in
  `BudgetRootView.swift`; edit mode in `AddTransactionView.swift`; identifiers throughout. New
  `SnappetUITests/BudgetUITests.swift`. This prompt asset; a `decisions.md` note if `MonthScope`'s contract changes.

## Acceptance criteria

- [ ] Tapping prev/next changes the displayed month; summary tiles, category progress, and donut all
      reflect the selected month (and transactions backdated to that month show up).
- [ ] An existing transaction can be edited (amount/note/date) and totals recompute.
- [ ] A 6-month spending-trend bar chart renders.
- [ ] month/add/edit/trends/summary/category controls carry stable `accessibilityIdentifier`s.
- [ ] `xcodegen generate` + `xcodebuild build-for-testing` (iPhone 17 Pro sim) → clean (Swift 6, 0 warn);
      `BudgetUITests` compiles.
- [ ] No nested `NavigationStack`; no new `@Model`; no platform imports in `HighlightEngine`.

## Constraints

- On-device only; no new dependencies (Swift Charts is system). Keep deletion cascade-correct.

## Test plan

1. `cd ios/App && xcodegen generate && xcodebuild -scheme Snappet -sdk iphonesimulator -destination 'id=F1A2B6B8-C609-47F8-8D55-44D94C5577B4' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build-for-testing` → succeeds.
2. `BudgetUITests`: add a category → add a transaction → edit its amount → step to the previous month and
   back → assert totals and the displayed month behave.
