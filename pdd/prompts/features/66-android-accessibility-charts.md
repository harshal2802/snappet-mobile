# Prompt: Android — accessible custom components + readable charts

**File**: pdd/prompts/features/66-android-accessibility-charts.md
**Created**: 2026-06-15
**Project type**: Native Android feature (Kotlin / Jetpack Compose) — code lands in this repo.
**Chain**: 2026-06-09 dual-platform product review → Android Continuous-polish batch
**Source**: GitHub issue [#98](https://github.com/harshal2802/Snappet/issues/98)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

TalkBack users couldn't operate Habits' main interaction or read any chart, and sighted users couldn't
read the bar charts either. The habit day cell was a bare clickable (announced "M 9", ~28dp target),
every Canvas chart was silent to TalkBack, and the bar charts had no weekday labels, values, or
today-highlight. This makes the custom-drawn surfaces accessible and the charts legible.

## Context the implementer needs

Base: `android/app/src/main/java/com/snappet/mobile/`. The labeling pattern already existed in
`feature/habit/HabitRoot.kt` (weekday initial + day number per cell); the Budget donut already has a
text legend. Keep the color-blind shape coding (`KilterHoldShape`) untouched.

## Approach

- New pure `ui/ChartAccessibility.kt`: `weekBarSummary(...)` (lead with active-days + total + busiest
  day) and `boardSummary(roleCounts)` (lit holds by role) + `roleCountsOf`. Pure → unit-tested.
- DayCell (`HabitRoot.kt`): `Role.Checkbox` + `stateDescription` ("Done"/"Not done") + `onClickLabel`,
  one merged semantics node (`clearAndSetSemantics`), and `sizeIn(minTouchTarget)` on the cell and the
  edit IconButton (was explicitly 36dp).
- Charts: attach a `contentDescription` to Home's WeekChart, `PomodoroFocusChart`, the Budget donut,
  and `KilterBoard`. Visually label the two bar charts: weekday initials under each bar, today's bar in
  full accent vs muted others, a value annotation on today/the max bar.

## Output

New `ui/ChartAccessibility.kt`; edits to `feature/habit/HabitRoot.kt`, `ui/home/HomeDashboardScreen.kt`,
`feature/pomodoro/PomodoroChart.kt`, `feature/budget/SpendByCategoryChart.kt`,
`feature/kilter/KilterBoard.kt`. New test `ui/ChartAccessibilityTest.kt`.

## Acceptance criteria

- [x] TalkBack announces each habit day with state + toggles it; cell and edit targets ≥48dp.
- [x] Every Canvas chart exposes a meaningful `contentDescription`.
- [x] Bar charts show weekday letters, a today-highlight, and a value annotation.
- [x] Color-blind shape coding (`KilterHoldShape`) unaffected.
- [x] `assembleDebug` + unit suite green; `ChartAccessibilityTest` covers the spoken wording.

## Constraints

On-device only. The summary builders are pure (no Compose/Android) so the spoken text is unit-tested.

## Test plan

1. `:app:testDebugUnitTest` (`ChartAccessibilityTest`) + `:app:assembleDebug`.
2. **Device-pending (deferred):** real TalkBack verification of the day-cell role/state and each
   chart's spoken summary on the shared emulator (instrumented runs collide with parallel waves).
