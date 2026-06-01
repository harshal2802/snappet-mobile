# Prompt: Expense — edit expenses/groups & record manual settlements

**File**: pdd/prompts/features/16-ios-expense-edit-settle.md
**Created**: 2026-05-31
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: suite feature-completeness pass (P9 follow-up); one of six parallel mini-app increments.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md` (§"Adding a mini-app"), `pdd/context/decisions.md`.

## Goal

Close the two biggest gaps in Split Expenses: expenses and groups are **immutable after creation** (only
deletable), and there's **no way to record that someone actually paid someone back** — the settle-up plan
suggests transfers but balances never clear. Add **editing** (expense fields + group name/participants)
and **manual settlement records** that zero out balances.

## Context the implementer needs

- Folder: `ios/App/Snappet/Features/Expense/` — `ExpenseRootView.swift`, `ExpenseModels.swift`
  (`ExpenseGroup`, `ExpenseRecord`), `ExpenseGroupView.swift`, `NewExpenseSheet.swift`,
  `NewGroupSheet.swift`, `SettleUp.swift` (greedy min-transfer algorithm), inline `ExpenseModule`.
- `ExpenseGroup` (`id`, `name`, `participants: [String]`, `createdAt`) and `ExpenseRecord` (`groupID`,
  `title`, `amount`, `payer`, `participants: [String]`, `date`) are registered in `Core/SnappetCore.swift`.
- **Model change (additive, safe):** add `var isSettlement: Bool = false` to `ExpenseRecord`. A settlement
  record represents "payer paid the (single) participant `amount`" and feeds the balance math as a direct
  transfer. Do **not** change `SnappetSchema.models` (type already registered) or existing fields.
- Balance math currently derives `paid − owed` from records; a settlement (`isSettlement == true`) must
  subtract from the payer's "owes" and the recipient's "owed" so the plan converges to zero. Update the
  balance/settle-up computation in `SettleUp.swift` / `ExpenseGroupView.swift` accordingly.
- Pushed into the App Library's `NavigationStack`; **no nested `NavigationStack`**. Editors are sheets.

## Approach

- **Edit expense** — reuse `NewExpenseSheet` for editing (pass an optional `ExpenseRecord`); save updates
  title/amount/payer/split in place. Add an Edit affordance (swipe / context menu / detail button) in
  `ExpenseGroupView`.
- **Edit group** — reuse `NewGroupSheet` for editing name + participants (guard: don't drop a participant
  who appears as a payer/split on an existing record without warning).
- **Manual settlement** — new `RecordSettlementSheet.swift`: pick payer, recipient, amount → insert an
  `ExpenseRecord(isSettlement: true, payer:, participants: [recipient], amount:)`. Show settlements
  distinctly in the list and factor them into balances + the settle-up plan.
- Keep `core.log(module: "expense", action: "expense"/"settle", …, metric: amount)`.
- Add `.accessibilityIdentifier(...)`: new-group (`expense.newGroup`), new-expense (`expense.newExpense`),
  edit-expense (`expense.editExpense`), settle button (`expense.settle`), settlement sheet fields
  (`expense.settle.payer`/`.recipient`/`.amount`/`.save`), participant toggles (`expense.participant.<name>`).
  Keep the existing `expenseGroupRow` identifier.

## Output

- New `Features/Expense/RecordSettlementSheet.swift`; `isSettlement` on `ExpenseRecord`
  (`ExpenseModels.swift`); edits to `NewExpenseSheet.swift`/`NewGroupSheet.swift` (edit mode),
  `ExpenseGroupView.swift` + `SettleUp.swift` (settlement-aware balances + edit affordances, identifiers).
  New `SnappetUITests/ExpenseUITests.swift`. This prompt asset; a `decisions.md` note on the settlement model.

## Acceptance criteria

- [ ] An existing expense can be edited (title/amount/payer/split) and balances recompute.
- [ ] A group's name and participants can be edited.
- [ ] Recording a settlement inserts a settlement record, shows distinctly, and moves balances toward zero
      (a settlement equal to the suggested transfer clears that pair).
- [ ] new-group/new-expense/edit/settle controls carry stable `accessibilityIdentifier`s; `expenseGroupRow` kept.
- [ ] `xcodegen generate` + `xcodebuild build-for-testing` (iPhone 17 Pro sim) → clean (Swift 6, 0 warn);
      `ExpenseUITests` compiles.
- [ ] No nested `NavigationStack`; `SnappetSchema.models` unchanged; no platform imports in `HighlightEngine`.

## Constraints

- On-device only; no new dependencies. Additive model change only. Keep the greedy settle-up algorithm.

## Test plan

1. `cd ios/App && xcodegen generate && xcodebuild -scheme Snappet -sdk iphonesimulator -destination 'id=F1A2B6B8-C609-47F8-8D55-44D94C5577B4' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build-for-testing` → succeeds.
2. `ExpenseUITests`: create a group → add an expense → edit its amount → record a settlement → assert the
   balance label / settle-up plan reflects both.
