# Prompt: Android — adopt design tokens + motion system consistently

**File**: pdd/prompts/features/65-android-design-tokens-motion.md
**Created**: 2026-06-15
**Project type**: Native Android feature (Kotlin / Jetpack Compose) — code lands in this repo.
**Chain**: 2026-06-09 dual-platform product review → Android Continuous-polish batch
**Source**: GitHub issue [#97](https://github.com/harshal2802/Snappet/issues/97)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

The suite visibly "breathes" differently on every module switch. The Pulse spacing scale had zero
screen consumers, `MaterialTheme.shapes` was effectively unused, Kilter used the motion/accent tokens
zero times (its amber accent re-hardcoded as raw hex), and the three structural transitions (tab
switch, module entry, workout phase change) hard-cut or used the sluggish 700ms nav default. This
sweep makes the suite read as one app, consuming the theme-aware status tokens shipped in #96.

## Context the implementer needs

Base: `android/app/src/main/java/com/snappet/mobile/`. The pattern to copy already existed in
`ui/home/HomeDashboardScreen.kt` (AnimatedContent + `gated()`). Tokens live in `ui/theme/`
(`Spacing.kt`, `Shape.kt`, `Color.kt`, `Motion.kt`). Keep changes additive (don't rename existing
tokens) — parallel waves touch the same files and the reviewer merges sequentially.

## Approach

- `Spacing.kt`: add `pageGutter` (16dp) + `minTouchTarget` (48dp) derived properties. Route the four
  scrolling module roots (Home, Reel, Pomodoro, Tip) and the App Library grid gutter through
  `LocalSpacing.current.pageGutter`; route the module-card icon tile to `MaterialTheme.shapes.small`.
- `Color.kt`: add a theme-aware `kilterAccent()` (the single source for the amber accent). Replace the
  remaining raw hex in Kilter (the saved star `0xFFE8A800`, the LogButton `Leaf`/`Ember` literals,
  GradeChart highlight) with `kilterAccent()` / `SnappetAccents`.
- `Motion.kt`: add `snappetSurfaceTransition(reduceMotion, forward)` → a slide+fade `ContentTransform`
  (≈220/160ms), collapsing to instant under reduce-motion. Use it for the tab switch (`RootShell`),
  the workout phase change (`WorkoutPlayerScreen`), and Kilter's sub-screen swaps. The library
  `NavHost` gets enter/exit/pop transitions in the same spirit.
- Kilter motion: animate the result count (`animateIntAsState`), fade/slide list rows
  (`Modifier.animateItem()`), spring the live-session banner (`AnimatedVisibility`).

## Output

Edits to `ui/theme/{Spacing,Color,Motion}.kt`, `ui/RootShell.kt`, `ui/library/AppLibraryScreen.kt`,
`ui/home/HomeDashboardScreen.kt`, `feature/{reel,pomodoro,tip}/…Root.kt`,
`feature/workout/WorkoutPlayerScreen.kt`, `feature/kilter/{KilterRoot,KilterDetailScreen}.kt`.

## Acceptance criteria

- [x] One page gutter + one card radius across module roots; no raw accent hex in Kilter.
- [x] Kilter list/filter/log/banner interactions animate, gated on reduce-motion.
- [x] Tab switch + module entry/exit use snappy slide+fade specs (no 700ms crossfade).
- [x] Workout EXERCISE→REST→DONE transitions animate.
- [x] Reduce-motion disables all of the above (specs route through `gated`/`snappetSurfaceTransition`).
- [x] `assembleDebug` + unit suite green.

## Constraints

On-device only. Additive token definitions over renames (parallel-wave-friendly). Reduce-motion is the
single governing flag.

## Test plan

1. `:app:assembleDebug` + `:app:testDebugUnitTest` (JVM).
2. Device/TalkBack-independent — motion is visual; spot-check on the emulator is deferred to the
   reviewer (one shared emulator; instrumented runs collide with parallel waves).
