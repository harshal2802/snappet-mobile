# Prompt: Confirm or undo destructive deletes, and stop persisting abandoned blank journal entries

**File**: pdd/prompts/features/34-ios-destructive-delete-safety.md
**Created**: 2026-06-10
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: PLAN-ios-to-shippable.md — data safety / UX improvements
**Source**: GitHub issue [#69](https://github.com/harshal2802/snappet-mobile/issues/69)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

One mis-tap can silently erase months of data across four mini-apps. This prompt adds confirmation dialogs (following the existing `HabitRootView` and `KilterSettingsView` pattern) to every unguarded destructive delete: expense-group deletion (plus orphan cleanup), budget-category deletion (with transaction count), and journal-entry swipe-delete. It also fixes a blank-row accumulation bug in the journal editor where back-swiping past a new, never-filled entry skips the existing empty-guard, leaving "Untitled" rows.

## Context the implementer needs

The right pattern already ships — `Features/Habit/HabitRootView.swift:53-65` (confirmationDialog + `pendingDelete` state + `deleteDialogBinding`) and `Features/Kilter/KilterSettingsView.swift:136`. Apply it consistently.

**Files to change:**

- `ios/App/Snappet/Features/Expense/ExpenseRootView.swift` — context-menu Delete at line 58 calls `modelContext.delete(group)` immediately, no confirmation. `ExpenseModels.swift:43-46` documents that `ExpenseRecord` rows reference their group via a flat `groupID: UUID` (not a SwiftData relationship), so deleting the group orphans every record; they are unreachable and waste space.
- `ios/App/Snappet/Features/Budget/BudgetRootView.swift:271-281` — `deleteCategories(at:)` loops and hard-deletes every matching `BudgetTransaction`, no dialog.
- `ios/App/Snappet/Features/Journal/JournalRootView.swift:68` — `.onDelete(perform: deleteEntries)` fires immediately; and `JournalRootView.swift:72-76` inserts a new `JournalEntry` into the context *before* navigation, so a back-swipe skips the empty-guard in `JournalEditorView.swift:79-84` (which is only reached via the Done button).

**Non-goals:** Tip-history and Kilter-history individual-row swipe-deletes are low-stakes (they're computed values, not primary records) and are out of scope here. The Habit `.onDelete` bypass is a latent dead path (no EditButton) — no action needed per the issue notes.

## Approach

### 1. ExpenseRootView — add confirmation + orphan cleanup

- Add `@Query private var allExpenseRecords: [ExpenseRecord]` so the view can count and delete orphans.
- Add `@State private var pendingDeleteGroup: ExpenseGroup?`.
- Change the context-menu button from calling `delete(group)` directly to `pendingDeleteGroup = group`.
- Add a `deleteGroupDialogBinding: Binding<Bool>` computed property (same pattern as `HabitRootView.deleteDialogBinding`).
- Add `.confirmationDialog("Delete '\(pendingDeleteGroup?.name ?? "")'?", ...)` with a message showing how many expense records will also be removed.
- Update `delete(_ group:)` to first delete all `allExpenseRecords` whose `groupID == group.id`, then delete the group.

### 2. BudgetRootView — add confirmation for category delete

- Add `@State private var pendingDeleteOffsets: IndexSet?` and computed `deleteCategoryDialogBinding`.
- Change `.onDelete(perform: deleteCategories)` to `.onDelete { pendingDeleteOffsets = $0 }`.
- Add computed `pendingDeleteTransactionCount: Int` that counts across `transactions` for the pending offsets.
- Add `.confirmationDialog("Delete category?", ...)` whose message states how many transactions across all months will be removed.
- The existing `deleteCategories(at:)` function stays; it is called from the dialog's confirm action.

### 3. JournalRootView — swipeActions + confirmation for entry delete

- Add `@State private var pendingDeleteEntry: JournalEntry?` and `deleteEntryDialogBinding`.
- Replace `.onDelete(perform: deleteEntries)` with explicit `.swipeActions(edge: .trailing)` on each row: tapping sets `pendingDeleteEntry`.
- Add `.confirmationDialog("Delete this entry?", ...)` following the Habit pattern.
- Replace `deleteEntries(at:)` with `deleteEntry(_ entry:)` (the offset-mapping workaround is no longer needed).

### 4. JournalEditorView — clean up abandoned blank entries on back-swipe

- Add `@State private var savedExplicitly = false`.
- Set `savedExplicitly = true` at the top of `save()` so it remains `false` if the user exits via back-swipe.
- Add `.onDisappear { cleanupIfAbandoned() }` to the outer Form.
- `cleanupIfAbandoned()` checks `isNew && !savedExplicitly` then, only if `title`, `body`, and `tags` are all empty, deletes the entry and saves. This mirrors the existing empty-guard in `save()`, extending it to the navigation-pop path.

**No new tests needed** — the views are UI-only (confirmationDialog bindings, swipeActions). All existing logic in `deleteCategories`, `delete`, etc. is unchanged. The HighlightEngine is not touched.

## Output

Changed files only — no new files except the PDD prompt:

| File | Change |
|---|---|
| `ios/App/Snappet/Features/Expense/ExpenseRootView.swift` | Confirmation dialog + orphan `ExpenseRecord` cleanup |
| `ios/App/Snappet/Features/Budget/BudgetRootView.swift` | Confirmation dialog + transaction count message |
| `ios/App/Snappet/Features/Journal/JournalRootView.swift` | swipeActions + confirmation dialog |
| `ios/App/Snappet/Features/Journal/JournalEditorView.swift` | `onDisappear` blank-entry cleanup |
| `docs/knowledge-graph/data.js` | Update `desc` for the four affected screen nodes |
| `pdd/context/decisions.md` | Record the onDisappear-guard approach |

## Acceptance criteria

- [ ] Deleting an expense group shows a confirmation dialog naming the group and the number of records inside; confirming leaves no orphaned `ExpenseRecord` rows.
- [ ] Deleting a budget category shows a confirmation dialog stating how many transactions across all months will be removed.
- [ ] Swipe-deleting a journal entry shows a confirmation dialog; swiping does not immediately delete.
- [ ] Abandoning a new journal entry via back-swipe (without tapping Done) leaves no blank "Untitled" row in the list.
- [ ] Existing Habit confirmation dialog and Kilter-settings confirmation dialog are unchanged.
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).
- [ ] `decisions.md` updated with the `onDisappear` guard approach.

## Constraints

- No backend/network. On-device SwiftData only.
- Keep every existing `@Query`, `modelContext`, and `try? context.save()` call pattern intact.
- Do not add platform imports to `HighlightEngine`.

## Test plan

1. Type-check: `cd ios/App && xcodegen generate && xcodebuild build -scheme Snappet -destination 'platform=iOS Simulator,name=iPhone 16 Pro' | xcpretty` — 0 errors, 0 warnings.
2. On device / sim: create an expense group with 2 expenses → swipe-delete the group → confirm the count in the dialog → verify no `ExpenseRecord` orphans remain (SwiftData inspector or re-querying in a debug breakpoint).
3. Create a budget category with 3 transactions → swipe-delete → confirm the dialog says "3 transactions" → verify they're gone.
4. Create a journal entry → immediately back-swipe without typing → verify no "Untitled" row appears.
5. Create a journal entry → tap Done without typing → verify no "Untitled" row appears (existing guard still works).
6. Create a journal entry → type text → back-swipe → verify the entry IS preserved (cleanup only fires on truly empty entries).
