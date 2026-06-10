# Prompt: Confirm destructive deletes and clean up blank journal entries

**File**: pdd/prompts/features/34-ios-destructive-delete-safety.md
**Created**: 2026-06-10
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: PLAN-ios-to-shippable.md — data safety / UX polish
**Source**: GitHub issue [#69](https://github.com/harshal2802/snappet-mobile/issues/69)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Prevent accidental data loss from unguarded destructive actions. A single mis-tap
could wipe months of expense, budget, or journal data with no confirmation or undo.
This prompt applies the confirmationDialog pattern (already established in
`HabitRootView` and `KilterSettingsView`) consistently to Expense, Budget, and
Journal, and fixes the Journal back-swipe path that bypassed the blank-entry guard.

## Context the implementer needs

- `ExpenseRootView.swift:57-69` — contextMenu Delete goes straight to
  `modelContext.delete(group)`. `ExpenseModels.swift` uses a flat `groupID`
  foreign key on `ExpenseRecord` rather than a SwiftData relationship, so deleting
  a group leaves all its records orphaned and unreachable.
- `BudgetRootView.swift:271-281` — `.onDelete` calls `deleteCategories` which
  hard-deletes every matching `BudgetTransaction` with no confirmation dialog.
- `JournalRootView.swift:68` — `.onDelete` deletes immediately.
- `JournalRootView.swift:72-76` — `createEntry()` inserts a blank entry immediately
  before navigating; `JournalEditorView.swift:71-94` — the Done button deletes blank
  entries, but the system back-swipe skips Done entirely.
- Reference pattern: `HabitRootView.swift:53-65` — `confirmationDialog` with
  `pendingDelete: Habit?` state and a `deleteDialogBinding` computed property.

## Approach

1. **ExpenseRootView**: add `@State private var pendingDeleteGroup: ExpenseGroup?`;
   contextMenu sets it instead of deleting directly. Add `confirmationDialog` on
   the body. `delete()` uses a `FetchDescriptor<ExpenseRecord>` predicate on
   `groupID` to fetch and delete orphaned records before deleting the group.

2. **BudgetRootView**: add `@State private var pendingDeleteCategory: BudgetCategory?`;
   change `.onDelete` closure to capture `categories[offsets.first!]` into state.
   Add `confirmationDialog` whose message dynamically shows
   `transactions.filter { $0.categoryID == cat.id }.count`. The confirmed action
   calls a new `deleteCategory(_ category:)` helper.

3. **JournalRootView**: add `@State private var pendingDeleteOffsets: IndexSet?`;
   change `.onDelete` to set state. Add `confirmationDialog` that calls
   `deleteEntries(at:)` on confirm.

4. **JournalEditorView**: add `@State private var didSave = false`; set it at the
   top of `save()` before any dismiss. Add `.onDisappear` that runs the
   blank-entry guard only when `isNew && !didSave`.

## Output

- `ios/App/Snappet/Features/Expense/ExpenseRootView.swift` — confirmation + orphan cleanup
- `ios/App/Snappet/Features/Budget/BudgetRootView.swift` — confirmation with transaction count
- `ios/App/Snappet/Features/Journal/JournalRootView.swift` — confirmation before delete
- `ios/App/Snappet/Features/Journal/JournalEditorView.swift` — back-swipe blank-entry guard
- `pdd/prompts/features/34-ios-destructive-delete-safety.md` — this file

## Acceptance criteria

- [x] Deleting an expense group requires confirmation and leaves no orphaned ExpenseRecords
- [x] Deleting a budget category states how many transactions it removes before cascading
- [x] Journal swipe-delete confirms before removing any entry
- [x] Abandoning a new journal entry via back-swipe leaves no blank "Untitled" row
- [x] Existing Habit/Kilter-settings confirmations unchanged
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).
- [ ] `decisions.md` updated if a non-obvious choice was made.

## Constraints

- No backend/network. Pure SwiftData + SwiftUI.
- Do not add platform imports to `HighlightEngine`.
- `HighlightEngine` is not touched by this change.

## Test plan

1. Type-check: `xcodebuild build -scheme Snappet -destination 'generic/platform=iOS Simulator'`
2. Device: create an expense group with records → swipe-delete → confirm dialog appears →
   confirm → group and all its ExpenseRecords gone.
3. Device: add a budget category with transactions → swipe-delete → dialog shows correct
   transaction count → confirm → category and transactions removed.
4. Device: journal list → swipe a row → confirm dialog appears → cancel → row stays;
   swipe again → confirm → row removed.
5. Device: tap + in Journal → immediately swipe back without typing → no blank row in list.
