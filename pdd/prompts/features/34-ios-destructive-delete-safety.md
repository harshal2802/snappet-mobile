# Prompt: Destructive-delete safety — confirmations and orphan cleanup

**File**: pdd/prompts/features/34-ios-destructive-delete-safety.md
**Created**: 2026-06-10
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: PLAN-ios-to-shippable.md → data safety / P1
**Source**: GitHub issue [#69](https://github.com/harshal2802/snappet-mobile/issues/69)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

One accidental swipe or context-menu tap can permanently erase large amounts of data with no
recovery path. This prompt hardens every destructive delete in the app: expense groups (whose
deletion also orphans `ExpenseRecord` rows), budget categories (cascade-deletes all transactions),
journal entries (swipe or new-entry abandonment), tip history rows, and Kilter ascent rows.
All six surfaces now require a confirmation step, and the expense-group delete also cleans up
orphaned records that were previously left stranded.

## Context the implementer needs

- The reference pattern is `HabitRootView.swift` (lines 53–65): `@State private var pendingDelete`,
  `confirmationDialog` bound to `pendingDelete != nil`, destructive button calls `delete()` then
  nils out the pending value.
- `ExpenseRootView` uses a `contextMenu` (not `.onDelete`) because the list is a `ScrollView +
  LazyVStack` for XCUITest reliability (see decisions.md). The group view has no `@Query` for
  `ExpenseRecord` today — add one so orphans can be found and removed.
- `BudgetRootView` uses `.onDelete` on a `List` row. The confirmation must report the transaction
  count: store the `IndexSet` in `@State` and compute the count only when the dialog fires.
- `JournalRootView` also uses `.onDelete`. Same store-then-confirm approach.
- `JournalEditorView` inserts the `JournalEntry` into the context immediately on + tap (before
  navigation). The `Done` button's `save()` already deletes blank new entries, but a system
  back-swipe skips that path. Fix: track `savedOrDiscarded`, and in `onDisappear` delete the
  entry if it is still blank and `savedOrDiscarded` is false. `@Bindable` requires an inserted
  model, so defer-insert is not feasible; `onDisappear` is the right hook.
- `TipHistoryView` and `KilterHistoryView` have `.onDelete` on their log rows with no dialog.
  Same store-then-confirm approach.
- The knowledge graph does not change — no new screens, sheets, or edges. The affected nodes'
  runtime behavior changes but their structural graph entries stay the same.

## Approach

Six targeted edits, all in the Features layer:

1. **`ExpenseRootView.swift`** — add `@Query private var allRecords: [ExpenseRecord]`;
   add `@State private var pendingDeleteGroup: ExpenseGroup?`; wire `confirmationDialog`;
   change context-menu action to `pendingDeleteGroup = group`; update `delete()` to first
   remove matching `ExpenseRecord`s.
2. **`BudgetRootView.swift`** — add `@State private var pendingDeleteCategoryOffsets: IndexSet?`;
   wire `confirmationDialog` with transaction-count message; change `.onDelete` to store offsets.
3. **`JournalRootView.swift`** — add `@State private var pendingDeleteOffsets: IndexSet?`;
   wire `confirmationDialog`; change `.onDelete` to store offsets.
4. **`JournalEditorView.swift`** — add `@State private var savedOrDiscarded = false`; set it
   before both `dismiss()` calls in `save()`; add `.onDisappear` guard that deletes blank new entries.
5. **`TipHistoryView.swift`** — add `@State private var pendingDeleteOffsets: IndexSet?`;
   wire `confirmationDialog`; change `.onDelete` to store offsets.
6. **`KilterHistoryView.swift`** — add `@State private var pendingDeleteEntryOffsets: IndexSet?`;
   wire `confirmationDialog`; change `.onDelete` in `ascentsSection` to store offsets.

## Output

Modified versions of the six files above. No new files needed beyond this prompt and a
`decisions.md` entry.

## Acceptance criteria

- [ ] Deleting an expense group requires confirmation and leaves no orphaned `ExpenseRecord`s.
- [ ] Deleting a budget category shows "removes N transaction(s)" before cascading.
- [ ] Journal entry swipe-delete requires confirmation.
- [ ] Abandoning a new journal entry via back-swipe leaves no blank "Untitled" row.
- [ ] Tip history row swipe-delete requires confirmation.
- [ ] Kilter ascent row swipe-delete requires confirmation.
- [ ] Existing Habit and KilterSettings confirmations are untouched.
- [ ] App type-checks (Swift 6, 0 warnings, iOS 18 SDK). No HighlightEngine changes.

## Constraints

- Confirm-then-delete only; no UndoManager (that requires `NSUndoManager` wiring through the
  scene and is a separate concern).
- Keep the pattern consistent with `HabitRootView` (the established precedent).
- The "Clear all" toolbar actions in Tip and Kilter history are not in scope — they are not
  the same as row-level swipe-delete and can be addressed separately.

## Test plan

1. `xcodebuild -scheme Snappet -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build`
   — zero errors and zero warnings.
2. Simulator smoke-test: swipe-delete on a journal entry → confirmation dialog appears → Cancel
   leaves the row; Delete removes it.
3. Simulator smoke-test: create a new journal entry, immediately swipe back → no blank row.
4. Simulator smoke-test: delete an expense group → confirm → group AND its records are gone.
5. Simulator smoke-test: delete a budget category → dialog shows correct transaction count → confirm.
