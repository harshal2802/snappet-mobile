# Prompt: Confirm or undo destructive deletes; stop persisting blank journal entries

**File**: pdd/prompts/features/34-destructive-delete-confirmations.md
**Created**: 2026-06-10
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Data-safety hardening
**Source**: GitHub issue [#69](https://github.com/harshal2802/snappet-mobile/issues/69)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Four data-loss paths in the app can erase data with no recovery: expense groups delete without
confirmation and leave orphaned `ExpenseRecord` rows; budget-category swipe-delete silently
cascades across all months; journal swipe-delete has no guard; and tapping + in the Journal list
inserts a blank entry that persists if the user backs out via the system edge swipe. This change
plugs all four holes using the `confirmationDialog` pattern that already ships in Habit and
KilterSettings, and fixes the journal blank-entry leak via an `onDisappear` guard.

## Context the implementer needs

- `ExpenseRootView.swift:57-69` — contextMenu Delete calls `modelContext.delete(group)` directly.
  `ExpenseModels.swift:56` — `ExpenseRecord` stores a plain `groupID: UUID` (no SwiftData
  relationship), so deleting the group leaves all its records orphaned and unreachable.
- `BudgetRootView.swift:271-281` — `deleteCategories` loops and hard-deletes without a dialog.
  It should tell the user how many transactions across all months it will remove.
- `JournalRootView.swift:68` — `.onDelete` calls `deleteEntries` immediately.
  `JournalRootView.swift:72-76` — `createEntry` inserts a blank entry and navigates.
  `JournalEditorView.swift:71-94` — `save()` has the blank-entry guard, but system back-swipe
  dismisses without calling `save()`, so blank rows accumulate.
- Reference pattern: `HabitRootView.swift:53-65` — `pendingDelete`, `deleteDialogBinding`,
  `confirmationDialog` with a descriptive message.

## Approach

1. **ExpenseRootView**: add `@Query private var allExpenses: [ExpenseRecord]` and
   `@State private var pendingDeleteGroup: ExpenseGroup?`. Change the context-menu Delete to set
   `pendingDeleteGroup` instead of deleting immediately. Add a `confirmationDialog` whose message
   shows the expense count. `deleteGroupWithOrphans` deletes all matching `ExpenseRecord` rows
   then the group.
2. **BudgetRootView**: add `@State private var pendingDeleteOffsets: IndexSet?`. Rename the
   existing `deleteCategories` body to `performDeleteCategories`; the public `deleteCategories`
   now just sets `pendingDeleteOffsets`. Add `pendingDeleteTransactionCount` (sum across all
   matching transactions) and a `confirmationDialog` that cites the count.
3. **JournalRootView**: add `@State private var pendingDeleteEntry: JournalEntry?`. `.onDelete`
   calls `requestDeleteEntries` which sets the pending entry. `confirmationDialog` confirms before
   deleting.
4. **JournalEditorView**: add `@State private var didSave = false`. In `save()`, set `didSave =
   true` before the first `dismiss()` call. Add `.onDisappear` that, when `isNew && !didSave`,
   deletes the entry if it is still blank (title + body both empty, no tags).

## Output

- `ios/App/Snappet/Features/Expense/ExpenseRootView.swift` — confirmation + orphan cleanup
- `ios/App/Snappet/Features/Budget/BudgetRootView.swift` — confirmation + transaction count
- `ios/App/Snappet/Features/Journal/JournalRootView.swift` — confirmation on swipe-delete
- `ios/App/Snappet/Features/Journal/JournalEditorView.swift` — onDisappear blank-entry guard
- `pdd/context/decisions.md` — record the onDisappear choice
- `docs/knowledge-graph/data.js` — update node descriptions for affected screens

## Acceptance criteria

- [ ] Deleting an expense group requires confirmation and leaves no orphaned ExpenseRecords.
- [ ] Deleting a budget category states how many transactions it removes before cascading.
- [ ] Journal swipe-delete shows a confirmationDialog before deleting.
- [ ] Abandoning a new journal entry via back-swipe leaves no blank "Untitled" row.
- [ ] Existing Habit/Kilter-settings confirmations unchanged.
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).
- [ ] `decisions.md` updated for the onDisappear approach.

## Constraints

- On-device only; no backend/network/accounts.
- Do not use `UndoManager` (not configured anywhere in the app).
- Do not introduce new screens, sheets, or navigation destinations — `confirmationDialog` is an
  inline modifier that presents as a system action sheet.
- The `@Bindable` on `JournalEditorView.entry` requires the model to be inserted before the view
  is presented, ruling out the defer-insert approach.

## Test plan

1. `swift build` from `ios/App` (or XcodeGen + build in Xcode) — 0 errors, 0 warnings.
2. **Expense**: context-menu Delete on a group with expenses → dialog appears with expense count
   → confirm → group and all its records gone; dialog on an empty group → confirms without count.
3. **Budget**: swipe-delete a category that has transactions → dialog cites the count → confirm →
   category and all transactions removed.
4. **Journal swipe-delete**: swipe on an entry → dialog → Cancel keeps entry, Delete removes it.
5. **Journal blank entry**: tap +, do not type anything, edge-swipe back → no "Untitled" row in
   the list.
6. **Journal non-blank entry**: tap +, type body text, edge-swipe back → entry persists.
7. **Habit delete**: swipe-delete still shows existing confirmationDialog unchanged.
