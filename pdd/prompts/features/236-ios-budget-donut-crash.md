# Prompt: Budget crashes once the month has spend in two categories (prompt 236)

**File**: pdd/prompts/features/236-ios-budget-donut-crash.md
**Created**: 2026-11-05
**Project type**: Native iOS (SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Found while taking the small-apps restyle before shots:
1. Add two Budget categories.
2. Log spend in both.
3. The app dies: `Swift/IntegerTypes.swift: Fatal error: Double value cannot be converted to Int because it is either
   infinite or NaN`.

The trap is inside Charts, drawing `SpendByCategoryChart` while the List updates.

## Cause

- The donut animated its sector angles whenever the month's total changed (`.animation(_, value: total)`).
- When a second slice arrived, Charts interpolated the sectors and produced a NaN angle.
- The sweep-in also started every slice at angle 0, an all-zero total.
- One category alone never crashed, so `BudgetUITests` stayed green.

## Fix

- Drop the total-change animation.
- Start the sweep-in at 0.1% of each slice instead of 0, so the total is never zero.
- The donut still sweeps in on appear.

## Acceptance

- [x] New `BudgetUITests.testSpendingInTwoCategoriesDoesNotCrash` fails on main (the app crashes) and passes with the
  fix. `BudgetUITests` 2/2.
- [ ] Device: user on MrRobot.
