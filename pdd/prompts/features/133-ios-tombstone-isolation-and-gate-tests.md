# Prompt: UI tests must not write real tombstones — and the import gate needs a test

**File**: pdd/prompts/features/133-ios-tombstone-isolation-and-gate-tests.md
**Created**: 2026-08-31
**Project type**: Native iOS fix + tests (Swift) — code lands in this repo.
**Chain**: from testing the watch-import delete-stickiness leg owed by prompt 125 (#308)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Two gaps found while trying to test "a deleted Health import stays deleted":

1. **UI tests can permanently affect the user's real data.** `-uiTestFreshStore` swaps in an
   IN-MEMORY SwiftData store, so a test's deletes are throwaway — but tombstones live in
   `UserDefaults.standard`, which that swap does not isolate. A UI test that deleted an imported
   session would write a REAL tombstone, permanently excluding that workout from the user's actual
   app long after the test store evaporated.
2. **The gate that makes deletes stick had no test.** Prompt 125 proved deleting RECORDS a
   tombstone; nothing asserted the import path then HONOURS one. That half was inline plumbing
   inside `reconcile`.

## Approach / Output

- `WatchImportTombstones.store`: a scratch suite (`uitest.watchImport`) under `-uiTestFreshStore`,
  `.standard` otherwise; both `all`/`record` and `SessionCascade.deleteWorkoutSession` default to it.
- Extract the inline filter to pure `WatchWorkoutReconciler.importable(_:tombstones:candidate:)`
  (tombstones first, then the own-source gate) and call it from `reconcile`.
- `WatchImportGateTests`: tombstoned workouts never return, an untombstoned one would, own-source
  still refused, the two compose, and the scratch-suite isolation holds for the current launch mode.

## Acceptance criteria

- [ ] A UI-test launch writes tombstones to the scratch suite; the shipped app uses `.standard`.
- [ ] A tombstoned workout is filtered out of the import set; others pass.
- [ ] `reconcile` behaviour is unchanged (pure extraction).

## Constraints

- Tombstones stay device-local bookkeeping — never SwiftData, never the backup.

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'`.
2. Device leg (still owed, inherently destructive — needs the user to pick the row): delete an
   imported session → force-quit → relaunch → it stays gone.
