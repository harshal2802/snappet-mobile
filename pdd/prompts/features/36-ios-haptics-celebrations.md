# Prompt: Haptics + celebration moments at the suite's commit and reward points

**File**: pdd/prompts/features/36-ios-haptics-celebrations.md
**Created**: 2026-06-10
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Product-review roadmap [#100](https://github.com/harshal2802/snappet-mobile/issues/100) → Wave 1
**Source**: GitHub issue [#80](https://github.com/harshal2802/snappet-mobile/issues/80)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

The suite is tactilely inert exactly where retention is built: a ready-made `Haptics`
helper exists but is private to the workout players (Pomodoro rolls its own generator),
and every other commit — Kilter log, habit check-off, expense/settlement/journal save,
favorite toggle, reel landing — is silent. No streak milestone or first-send is ever
celebrated, even though `SnappetMotion.expressive` is documented for exactly that. Give
the suite one tactile language and a single reusable celebration moment.

## Approach

- **Promote `Haptics`** from `WorkoutPlayerView` into `DesignSystem/Haptics.swift`
  (success / warning / tap, UIKit-guarded); `PomodoroTimer`'s bespoke generator routes
  through it. No per-feature generators remain.
- **Success haptics at commit points**: habit completion, Kilter log, expense save,
  settlement save, journal save, reel-export landing; `tap()` on the favorite toggle.
- **`CelebrationBurstView` + `.celebrates(on:)`** in DesignSystem: a one-shot
  TimelineView/Canvas confetti burst (~1.5 s, no frameworks), fired by incrementing a
  trigger. Under **Reduce Motion** the burst never shows — the success haptic alone
  acknowledges the moment.
- **Milestones, pure and tested**: `HabitMilestones` (streak math extracted from
  `HabitRootView` + `crossed(previousStreak:newStreak:)` over [7, 30, 100], highest
  wins on a backfill jump) and `KilterMilestones.isFirstSend(status:priorSendCountAtGrade:)`
  (prior count via one-off `fetchCount` before the new log lands).

## Output

- New: `DesignSystem/Haptics.swift`, `DesignSystem/CelebrationBurst.swift`,
  `Features/Habit/HabitMilestones.swift`, `SnappetTests/CelebrationTests.swift`.
- Modified: `WorkoutPlayerView` (enum removed), `PomodoroTimer`, `HabitRootView`,
  `KilterClimbDetailView` (+ `KilterModels` for `KilterMilestones`), `NewExpenseSheet`,
  `RecordSettlementSheet`, `JournalEditorView`, `ReelView`.
- Knowledge graph: a `design-haptics-celebrations` node wired to the consuming modules.

## Acceptance criteria

- [ ] Habit check-off, Kilter log, expense/settlement save, journal save, and
      export-landed produce a success haptic.
- [ ] Streak milestones (7/30/100) and first send of a grade trigger the celebration
      view; suppressed (haptic-only) under Reduce Motion.
- [ ] Single shared `Haptics` helper; no per-feature generators remain (repo grep).
- [ ] Milestone/streak/first-send logic is pure and unit-tested without a simulator.
- [ ] App type-checks against the iOS 18 SDK (Swift 6, 0 warnings).

## Constraints

- Haptic *feel* on a physical device is device-pending — the sim doesn't render haptics.
- No third-party particle/confetti dependencies.

## Test plan

1. `xcodegen generate` + full `SnappetTests` (new `CelebrationTests`).
2. Existing Habit/Kilter/Expense/Journal/Pomodoro UI tests stay green (no flow changes).
3. Device-pending: haptic feel; burst rendering over real content.
