# Prompt: Wire up the missing delete/edit affordances across the Android modules

**File**: pdd/prompts/features/41-android-crud-verbs.md
**Created**: 2026-06-10
**Project type**: Native Android feature (Kotlin / Compose) — code lands in this repo.
**Chain**: Product-review roadmap [#101](https://github.com/harshal2802/snappet-mobile/issues/101) → Wave 1
**Source**: GitHub issue [#88](https://github.com/harshal2802/snappet-mobile/issues/88)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Users couldn't fix mistakes anywhere: a typo'd settlement corrupted who-owes-whom
forever, a fat-fingered Kilter Flash inflated the pyramid permanently (the only remedy
wiped all history), and habits, groups, expenses, budget rows, tip history, routines,
and finished sessions were undeletable. The DAO verbs mostly existed — no UI reached
them. One mechanical Compose+DAO sweep, mirroring iOS's affordances.

## Approach

- **One confirmation component** (`ui/ConfirmDialog.kt` — `ConfirmDeleteDialog`): static
  title, consequence in the message, destructive confirm; every flow below uses it.
- **Long-press = the secondary-action idiom** (the Budget category row already
  established it): Tip history rows, Kilter ascent rows, budget transactions, expense
  rows (incl. settlements, which weren't even tappable), expense groups.
- Per module: **Tip** (new `TipDao.delete`); **Kilter** (new `deleteLog` +
  `updateLogStatus`; long-press an ascent → status-correction dialog with Delete;
  Clear-all now confirms); **Habit** (delete via the edit sheet, cascading completions);
  **Budget** (category delete via the editor with the cross-month cascade count;
  transaction long-press delete); **Workout** (routine + finished-session delete via a
  trash action on their detail screens); **Expense** (group long-press → Edit/Delete:
  edit finally reaches the dead `NewGroupSheet(existing)` mode with cross-group
  known-name suggestion chips (`SettleUp.participantSuggestions`, pure); delete cascades
  records via new `deleteExpensesFor` — `groupId` is a flat reference, mirroring iOS).
- "Remembered me" (the iOS #82 second-person framing) is deliberately deferred — it's
  parity polish beyond this issue's ACs; the suggestion chips land here because group
  editing required touching the sheet anyway.

## Output

- New: `ui/ConfirmDialog.kt`, `test/.../CrudRecomputeTest.kt`.
- Modified: Tip (Dao + history), Kilter (Dao + history screen), Habit (root + editor),
  Budget (root + editor + transactions screen), Workout (root + both detail screens),
  Expense (Dao + root + group sheet + SettleUp).

## Acceptance criteria

- [ ] Habit, expense group, expense, settlement, budget category/transaction, tip-history
      row, finished workout session, routine, and individual Kilter ascent are deletable
      with confirmation.
- [ ] A Kilter ascent's status can be corrected (Flash → Attempt etc.).
- [ ] An existing group can be renamed and gain/lose participants; the sheet suggests
      known names.
- [ ] Kilter History "Clear all" confirms.
- [ ] Balances/stats recompute correctly after deletion — locked at the pure layer
      (`CrudRecomputeTest`: settlement deletion restores the exact pre-settlement
      balances; expense deletion; streak-over-empty; suggestion dedup).

## Test plan

1. `:app:testDebugUnitTest` (new `CrudRecomputeTest`).
2. Emulator: full instrumented suite via `adb shell am instrument` (existing module
   walkthroughs must stay green — no tap flows changed, only long-press additions).
