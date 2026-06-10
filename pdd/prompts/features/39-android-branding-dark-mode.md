# Prompt: Launcher icon + branded splash; fix dark mode (white flash, light-locked board, illegible statuses)

**File**: pdd/prompts/features/39-android-branding-dark-mode.md
**Created**: 2026-06-10
**Project type**: Native Android feature (Kotlin / Compose + resources) — code lands in this repo.
**Chain**: Product-review roadmap [#101](https://github.com/harshal2802/snappet-mobile/issues/101) → Wave 1
**Source**: GitHub issue [#96](https://github.com/harshal2802/snappet-mobile/issues/96)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Before any screen renders the app announced itself as a prototype: no launcher icon
(stock robot everywhere), a hardcoded light XML theme that flashed a white frame on every
dark-mode cold start, a Kilter board that rendered a glaring fixed light-paper rectangle
in dark mode (at a dimly-lit gym — the module's primary context), and dark-green-on-dark
status text at ~2.6:1. Make the first five seconds — and dark mode — feel like a product.

## Approach

- **Adaptive launcher icon**: a hand-authored vector "Pulse mark" (white ECG pulse line,
  `drawable/ic_launcher_foreground.xml`) over the brand coral, via
  `mipmap-anydpi-v26/ic_launcher{,_round}.xml` (+ `monochrome` for themed icons);
  `android:icon`/`roundIcon` on the application. minSdk 26 ⇒ adaptive-only suffices.
- **Splash**: `androidx.core:core-splashscreen`; `Theme.Snappet.Starting` (brand
  background + the Pulse mark) on the launcher activity, `installSplashScreen()` before
  `super.onCreate`, posting to `Theme.Snappet`.
- **No white flash**: `Theme.Snappet` gains a `windowBackground` matching the Compose
  Pulse background, with a `values-night` variant (dark parent + dark background).
- **Dark board**: `KilterBoard`/`KilterEditableBoard` resolve a mode-aware "board paper"
  (`PulseColors.BoardPaper{Light,Dark}`) + grid in the composable (a Canvas draw scope
  can't read the theme); the lit-mode black render is unchanged.
- **Status tokens**: `PulseColors.Success/Warning {Light,Dark}` + `pulseSuccess()` /
  `pulseWarning()` accessors, all ≥4.5:1 on their mode's surfaces; every hardcoded
  green/amber status text/wash in Kilter (log confirmation, session banner, Classic chip,
  No-matching tag, create-screen statuses, history rows, FA line) now reads through them.
  Feeds the #97 token sweep. (Filled send/project button colors are #93's scope.)

## Output

- New: `res/values/colors.xml`, `res/values-night/themes.xml`,
  `res/drawable/ic_launcher_foreground.xml`, `res/mipmap-anydpi-v26/ic_launcher{,_round}.xml`.
- Modified: `res/values/themes.xml`, `AndroidManifest.xml`, `MainActivity.kt`,
  `ui/theme/Color.kt`, `KilterBoard.kt`, `KilterEditableBoard.kt`, `KilterDetailScreen.kt`,
  `KilterRoot.kt`, `KilterHistoryScreen.kt`, `CreateClimbScreen.kt`,
  `build.gradle.kts` + `libs.versions.toml` (core-splashscreen).
- Knowledge graph untouched: no new surface/edge — branding + palette work on existing nodes.

## Acceptance criteria

- [ ] Launcher, Recents, and share sheet show the Snappet icon; splash shows the brand mark/color.
- [ ] Cold start in dark mode has no white flash (`values-night` window background).
- [ ] Kilter board render and editor use the dark board paper in dark mode.
- [ ] Log confirmation, session banner, and create-screen status text read through
      4.5:1 tokens in both modes.
- [ ] Full instrumented suite stays green.

## Constraints

- No raster assets — the icon is a hand-authored vector (nothing to license or generate).
- Visual confirmation of icon/splash/dark render on the emulator (screenshots), honestly
  noted as the verification.

## Test plan

1. `:app:assembleDebug` + `:app:testDebugUnitTest`.
2. Emulator: full instrumented suite via `adb shell am instrument`; then visual checks —
   launcher icon, cold-start splash in dark mode (no white flash), Kilter board + log
   confirmation in dark mode (screenshots).
