# Prompt: Fix — a typed weight is kept when you log (and never shown rounded)

**File**: pdd/prompts/features/192-ios-typed-weight-kept.md
**Created**: 2026-10-19
**Project type**: Native iOS bug fix (Swift / SwiftUI) — code lands in this repo.
**Context**: `pdd/context/decisions.md` (prompt 146's "show 67.5 as typed" rule)

## Bug

User (2026-10-14): "based on our recent work about making weight editable is just making the input editable but
when i click on log after editing the weight it doesn't keep the same edited value. it seem to be rounding up".

Reproduced (`QuickAddSetTests.testTypedWeightIsKeptWhenLoggingWithoutDone`): type 67.5 in the pager's weight, tap
**Log set** with the keyboard still up → the set logged "8 reps" at the OLD weight (bodyweight) and 67.5 was gone.
`TypeableWeightValue` only committed on focus loss; the Log tap logged first, and the hero re-seeds after a log
(`.id(sets.count)`), destroying the field before its commit ran. The existing test passed because it tapped the
field's ✓ first.

Second, separate cause of "rounding": five places showed ONE set's weight through `WorkoutMath.formatWeight(kg:)`,
which rounds to whole numbers (meant for volume) — the routine block row / routine detail ("67.5 → 68 kg"), the
dashboard's top set, Library Explore's top set, recent sessions' top set.

## Fix

- `TypeableWeightValue` updates the binding on every keystroke `WeightEntry.parse` accepts (focus-loss commit kept
  for closing the editor). Covers the pager hero, the timed-set cover, the protocol editor, force-sensor settings.
- `WorkoutMath.setWeight(_:enteredIn:unit:)` / `setWeight(kg:unit:)`: exact (0.01) in the entered unit, whole only
  after a kg↔lb conversion; used by the logged-set summary, the five sites above and `ActivityDashboard.weightLabel`.
  The estimated 1RM stays whole (it's an estimate).

## Acceptance criteria

- [x] `QuickAddSetTests.testTypedWeightIsKeptWhenLoggingWithoutDone` (red before, green after).
- [x] `SetWeightLabelTests`: exact in the entered unit, whole after conversion, bests in kg, parse incl. comma +
      mid-typing.
- [ ] Device: type 67.5, tap Log set → "8 × 67.5 kg"; routine builder block shows 67.5 kg.
