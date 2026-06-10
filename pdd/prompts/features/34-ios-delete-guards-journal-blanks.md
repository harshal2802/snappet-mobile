# Prompt: Confirm destructive deletes + stop persisting abandoned blank journal entries

**File**: pdd/prompts/features/34-ios-delete-guards-journal-blanks.md
**Created**: 2026-06-10
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Product-review roadmap [#100](https://github.com/harshal2802/snappet-mobile/issues/100) → Wave 1
**Source**: GitHub issue [#69](https://github.com/harshal2802/snappet-mobile/issues/69)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

One mis-tap can erase months of data with zero recovery: deleting an `ExpenseGroup` (context
menu, no confirmation) instantly orphans every expense, receipt, and settlement in it;
swipe-deleting a `BudgetCategory` cascade-deletes all its transactions across all months;
Journal rows swipe-delete unconfirmed. Separately, Journal litters itself: tapping **+**
inserts an empty `JournalEntry` before navigation, and backing out via the system back
button/edge swipe skips the delete-if-empty guard behind **Done**, so "Untitled" rows
accumulate. Close both holes.

## Context the implementer needs

- The repo already ships the right confirmation pattern: `Features/Habit/HabitRootView.swift`
  (`pendingDelete` + `confirmationDialog`). Reuse it; don't invent an Undo stack (no
  `UndoManager` is configured anywhere, and a dialog is the established idiom here).
- `ExpenseRecord.groupID` is a **flat UUID reference**, not a SwiftData relationship
  (`ExpenseModels.swift` documents why) — so deleting a group does NOT cascade; today the
  records are simply orphaned and unreachable. Group deletion must clean them up explicitly.
- `BudgetRootView.deleteCategories(at:)` hard-deletes every `BudgetTransaction` whose
  `categoryID` matches — silently, from a swipe.
- `JournalRootView.createEntry()` inserts before navigation so `JournalEditorView` can take
  `@Bindable`. Keep the insert (defer-insert would lose typed content on back-swipe, since
  only **Done** persists deliberately); instead run the blank-entry cleanup when the editor
  disappears without **Done** having handled it.

## Approach

- **Expense** (`ExpenseRootView.swift`): context-menu Delete stages the group in
  `@State pendingDelete`; a `confirmationDialog(presenting:)` names the group and states how
  many expense rows go with it; confirm deletes the matching `ExpenseRecord`s **then** the
  group. Add a `@Query` for records to count/cleanup. Pure message builder
  (`ExpenseGroupDeleteImpact.message`) so pluralization is unit-testable.
- **Budget** (`BudgetRootView.swift`): `.onDelete` stages the swiped categories; the dialog
  states the total transaction count it will cascade-delete
  (`BudgetCategoryDeleteImpact.message`, pure); confirm runs the existing loop.
- **Journal** (`JournalRootView.swift`, `JournalEditorView.swift`, `JournalEntry.swift`):
  swipe-delete stages entries and confirms. Blank-entry fix: a pure
  `JournalEntry.isBlank(title:body:tags:)` used by both the existing **Done** guard and a new
  `.onDisappear` cleanup in the editor, gated by a `didFinish` flag set on every **Done** path
  so the two never double-delete.
- Knowledge graph: no new surface or navigation/data-flow edge — dialogs are guards on
  existing flows — so `docs/knowledge-graph/data.js` is intentionally untouched.

## Output

- Modified: `ExpenseRootView.swift`, `BudgetRootView.swift`, `JournalRootView.swift`,
  `JournalEditorView.swift`, `JournalEntry.swift`.
- New: `ios/App/SnappetTests/DeleteConfirmationTests.swift` (impact-message pluralization,
  `isBlank` truth table).
- Extended: `ios/App/SnappetUITests/JournalUITests.swift` — abandoning a new entry via the
  back button leaves no "Untitled" row.
- `pdd/context/decisions.md` entry for the didFinish/onDisappear choice.

## Acceptance criteria

- [ ] Deleting an expense group requires confirmation and leaves no orphaned `ExpenseRecord`s.
- [ ] Deleting a budget category states how many transactions it removes before cascading.
- [ ] Journal swipe-delete confirms.
- [ ] Abandoning a new journal entry via back-swipe/back-button leaves no blank "Untitled" row.
- [ ] Existing Habit/Kilter-settings confirmations unchanged.
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).
- [ ] `decisions.md` updated if a non-obvious choice was made.

## Constraints

- On-device only; no backend/network/accounts.
- Tip/Kilter-history single-row swipe deletes stay unconfirmed — out of this issue's
  acceptance criteria; a single low-stakes row per swipe, revisit under #80/#75 if needed.

## Test plan

1. `cd ios/App && xcodegen generate`, then unit tests:
   `xcodebuild test -scheme Snappet -only-testing:SnappetTests/DeleteConfirmationTests …`.
2. Full `SnappetTests` + the new `JournalUITests` case on the simulator.
3. By hand on the sim: delete a group with expenses → dialog names count, records gone;
   swipe a budget category → dialog names transaction count; + → back-swipe in Journal →
   no Untitled row; + → type → Done → entry persists.
