# Prompt: Cut money-entry friction — keypad Done, prefilled settlements, direct Add Expense, known names + "me"

**File**: pdd/prompts/features/37-ios-money-entry-ux.md
**Created**: 2026-06-10
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Product-review roadmap [#100](https://github.com/harshal2802/snappet-mobile/issues/100) → Wave 1
**Source**: GitHub issue [#82](https://github.com/harshal2802/snappet-mobile/issues/82)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Tip was the only money surface with a keyboard Done toolbar; every other numeric form used
a decimal/number pad with no way off it, and the value-formatted money fields could save a
stale, uncommitted amount. In Split Expenses the app computes exact transfers but recording
one took 5+ steps including retyping the displayed amount; Add Expense hid in a menu; new
groups started blank; and balances could never say "you" because the app had no notion of
"me". Make money entry feel one-tap-everything.

## Approach

- **`DesignSystem/KeypadDoneToolbar.swift`**: Tip's `placement: .keyboard` Done pattern as
  two `keypadDoneToolbar` overloads (`FocusState<Bool>` for single-field forms, a
  `Hashable?` overload for multi-field ones). Applied to: NewExpenseSheet,
  RecordSettlementSheet, AddTransactionView, BudgetCategoryEditor, NewReceiptSheet
  (discount/tax/each item price via one `MoneyField` enum), UserHRProfileView,
  RoutineExerciseEditor, FreeformPlayerView's LogSetSheet.
- **Commit-then-save** on every value-formatted money form: Save resigns focus first and
  performs the save on the next runloop tick, so it can never read a stale binding.
- **Tappable transfers**: settle-up rows open `RecordSettlementSheet` **prefilled**
  (new `payer:recipient:amount:` initializer) — recording the suggested transfer is two
  taps. Add Expense promoted to a direct toolbar button; the rarer actions stay behind an
  ellipsis menu (same identifiers, so UI tests keep working).
- **Known names + "me"** (`@AppStorage("expense.myName")`): new groups prefill slot 1 with
  the remembered name and offer tappable suggestions collected across existing groups
  (pure `SettleUp.participantSuggestions`); saving a new group stores slot 1 as "me", and
  balances/settle-up read in the second person via pure `SettleUp.transferLabel` /
  `balanceName` ("You owe Bob" / "Bob owes you" / "You").

## Output

- New: `DesignSystem/KeypadDoneToolbar.swift`, `SnappetTests/FinanceUXTests.swift`.
- Modified: `SettleUp.swift` (pure helpers), `NewExpenseSheet`, `RecordSettlementSheet`,
  `ExpenseGroupView`, `NewGroupSheet`, `NewReceiptSheet`, `AddTransactionView`,
  `BudgetCategoryEditor`, `UserHRProfileView`, `RoutineEditorView`, `FreeformPlayerView`.
- `ExpenseUITests` updated: direct Add Expense, second-person assertions, and the
  settlement recorded via the tapped prefilled transfer.
- Knowledge graph intentionally untouched: no new surface or nav edge — the prefilled
  sheet is the existing `expense-settlement` node reached from an existing screen.

## Acceptance criteria

- [ ] Every money/number field can dismiss its keypad via Done; Save never acts on a
      stale amount (commit-then-save on all value-formatted forms).
- [ ] Tapping a computed transfer records it in two taps with the exact amount prefilled.
- [ ] Add Expense reachable in one tap from the group screen.
- [ ] New groups offer known names; balances read "You owe / are owed" when "me" is set.
- [ ] Phrasing/suggestion logic is pure and unit-tested without a simulator.
- [ ] App type-checks against the iOS 18 SDK (Swift 6, 0 warnings).

## Constraints

- "Me" stays a device-local `@AppStorage` convention (slot 1 of a group you create) — no
  accounts, no contacts access.

## Test plan

1. `xcodegen generate` + full `SnappetTests` (new `FinanceUXTests`).
2. `ExpenseUITests` (updated flow: direct button → second-person plan → tap transfer →
   prefilled save → settled), `BudgetUITests`, `TipUITests` unchanged-green.
3. By hand on the sim: keypad Done on each listed form; type-then-Save-immediately saves
   the typed amount.
