# Prompt: Android Today daily home — cards, deep-linking feed, Glance widgets, shortcuts

**File**: pdd/prompts/features/64-android-today-daily-home.md
**Created**: 2026-06-15
**Project type**: Native Android feature (Kotlin / Compose / Glance). Code lands in this repo.
**Chain**: Android Wave 3 → #99
**Source**: GitHub issue [#99](https://github.com/harshal2802/Snappet/issues/99)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

The Today tab was a read-only usage odometer: feed rows weren't tappable and leaked raw module ids,
there were no quick actions, and no nav path from Home into a module existed. Off the app there were
no widgets or shortcuts. Turn Today into a daily home: actionable cards, a deep-linking feed, Glance
launcher widgets, and static launcher shortcuts — cards and widgets reading the same Room flows.

## Context the implementer needs

- Builds on the #86 nav hoist (the hoisted Apps-tab NavHost owns module navigation).
- Dashboard previously consumed only `UsageRecord`; every module already exposes reactive flows
  (Habit, Pomodoro, Budget, Kilter, Workout).
- `ModuleRegistry.byId(...).title` gives proper display names (was using raw ids).

## Approach

- Shared pure aggregator `ui/home/TodayData` (JVM-tested) read by BOTH the in-app cards and the Glance
  widgets so they never drift.
- In-app: feed rows → display names + deep-link via `onOpenModule`; actionable cards (habits with
  inline check-off, focus minutes) that deep-tap in. Align scaffold titles with card titles.
- Navigation: a process-wide `SuiteRouter` (shared with #91) carries module routes; RootShell flips to
  the Apps tab and the NavHost honors the route. MainActivity maps shortcut/widget/deep-link intents.
- Widgets (Jetpack Glance): `HabitWidget` (headless check-off via ActionCallback → Room) +
  `FocusWidget` (today minutes + Start focus → opens Pomodoro). Widget UI is device-pending to render.
- Shortcuts: 4 static launcher shortcuts via `snappet://module/<id>` data URIs.

## Output

`ui/home/TodayData.kt`, `core/SuiteRouter.kt`, `widget/HabitWidget.kt`, `widget/FocusWidget.kt`,
`widget/WidgetReceivers.kt`, `widget/WidgetKeys.kt`, `res/xml/{habit,focus}_widget_info.xml`,
`res/xml/shortcuts.xml`, `res/values/strings.xml`; edits to `HomeDashboardScreen`, `RootShell`,
`AppLibraryScreen`, `MainActivity`, `AndroidManifest`, `WorkoutRoot` (title). Unit tests for TodayData.

## Acceptance criteria

- [x] Feed rows show module display names and open the source module.
- [x] Today shows actionable cross-module cards; habit check-off works from Home.
- [x] Habit + Focus Glance widgets defined; habit check-off is headless (no app open). **Launcher
  render/check-off verification device-pending.**
- [x] Long-press launcher shortcuts open the right module (via snappet://module/<id>).
- [x] Knowledge graph gains the new surfaces.

## Constraints

On-device only. Cards and widgets MUST read the same Room flows (via TodayData).

## Test plan

1. `./gradlew :app:testDebugUnitTest` — TodayDataTest green.
2. `assembleDebug` — widget receivers + shortcuts + manifest merge.
