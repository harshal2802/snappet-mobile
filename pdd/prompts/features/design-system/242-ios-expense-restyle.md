# Prompt: Design-system reset — Split Expenses (prompt 242)

**File**: pdd/prompts/features/design-system/242-ios-expense-restyle.md
**Created**: 2026-11-05
**Project type**: Native iOS (SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Mockup (approved)**: `docs/ux-research/design-system/small-apps.html` (Split Expenses section; the "As built" row
for all six apps lands with this PR)

## Goal

Restyle Split Expenses (small apps 6/6, stacked on 241). It is visual only: ids, the split / settle math and the
receipt parser are unchanged.

## Approach

- **Colour:** Expenses cyan becomes the user's accent (toolbar, checkmarks, swipe Edit, Add item / Scan / Paste);
  Split Expenses joins `suiteAccentModules`.
- **Groups:** each group is a `snappetPanel` with a chevron (was a grey box); the name is medium weight.
- **Balances:**
  - Owed is green (`perfFresh`) and owe is red (`perfHard`). They were the Habits / Pomodoro module colours.
  - "Settle Up" becomes "Settle up"; transfer amounts are regular weight.
  - "All settled up" is green.
- **Expense rows:** the title is medium weight and the amount regular. Settlement glyph and amount are green; the
  receipt glyph is grey.
- **Receipts:**
  - Validation pass / warn / fail use `perfFresh` / `perfModerate` / `perfHard` (warn was system orange).
  - Unassigned and the discount use the meaning tokens.
  - Totals and per-person rows are medium / regular.
- **Sheets:** picked menu values are grey, like Settings. Known-name chips are `snappetPill` outlines (were bordered
  system buttons).

## Acceptance

- [x] Affected suites: `ExpenseUITests` 1/1. As built matches the mockup.
- [ ] Unit suite alone (once for the stack).
- [ ] Device: user on MrRobot (batch).
