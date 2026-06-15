# Prompt: iOS — design-consistency sweep (tokens, module accents, paper canvas, Pulse app icon)

**File**: pdd/prompts/features/53-ios-design-consistency.md
**Created**: 2026-06-15
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: 2026-06-09 product review → iOS tracker [#100](https://github.com/harshal2802/Snappet/issues/100), Wave 3 (landed after the feature-heavy issues, as the issue advised).
**Source**: GitHub issue [#77](https://github.com/harshal2802/Snappet/issues/77)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

One tap from the warm, tokenized Home/App Library into a module and everything turned flat stock-gray
with drifting corner radii (10/12/14/16); module accent colors died one tap deep (only the library
card used them); the warm "paper" background existed for ~1 s at cold start; and the home-screen icon
was a script-generated "S" gradient disagreeing with the in-app waveform brand mark. Make the suite
read as one product.

## Approach

1. **Module accent one tap deep.** `AppLibraryView.moduleDestination` applies `.tint(module.tint)`, so a
   module's controls inherit its wayfinding accent inside the module, not just on its card.
2. **Token card sweep.** In the cited Kilter / WorkoutTracker / Pomodoro views, the hand-rolled
   `Color(.secondarySystemBackground)` + ad-hoc-radius cards become `SnappetColor.surfaceMuted` +
   `SnappetRadius.md` (keeps padding/structure — lower layout-risk than swapping to `.snappetTile()`'s
   different padding, while killing the token + radius drift).
3. **Purge stray module-chrome colors.** Hardcoded `.tint(.blue)` in Habit/Budget/Expense and `.orange`
   in `WorkoutDashboardSection` (the module's own accent, hardcoded as a system colour) → the module
   token. Kept genuinely-semantic colours (Kilter no-match amber, live-record green).
4. **Paper canvas.** `SnappetColor.paper.ignoresSafeArea()` on the Home and App Library shell screens.
5. **Pulse app icon.** Replace the "S" gradient with the `waveform.path.ecg` brand mark (the in-app
   loading glyph) in the three iOS 18 luminosity slots — light (white on coral→ember, opaque), dark
   (coral on near-black), tinted (grayscale). Rendered by `generate-pulse-icon.swift`; `Contents.json`
   declares the appearance slots.

## Output

- `Features/AppLibrary/AppLibraryView.swift` — module tint + paper canvas.
- `Features/Home/HomeDashboardView.swift` — paper canvas.
- `Features/Kilter/KilterSessionDetailView.swift`, `KilterCatalogSyncView.swift`, `KilterClimbDetailView.swift`,
  `Features/WorkoutTracker/WorkoutDashboardSection.swift`, `Features/Pomodoro/PomodoroFocusChart.swift` — token card sweep.
- `Features/Habit/HabitRootView.swift`, `Features/Budget/BudgetRootView.swift`, `Features/Expense/ExpenseGroupView.swift` — color purge.
- `Resources/Assets.xcassets/AppIcon.appiconset/` — Pulse icon (light/dark/tinted) + `Contents.json` + generator.
- `pdd/context/decisions.md` + `docs/knowledge-graph/data.js`.

## Acceptance criteria

- [ ] No `Color(.secondarySystemBackground)` + ad-hoc radius cards remain in the cited Kilter/WorkoutTracker views.
- [ ] Each module's chrome/tint matches its accent inside the module, not just on its library card.
- [ ] Light mode shows the warm paper canvas on shell screens.
- [ ] App icon has light/dark/tinted variants and matches the in-app brand mark.

## Constraints

- Token substitution keeps the existing padding/structure (no layout shift), so the screenshot/UI tests
  stay green; visual polish is verified by eye (the suite is the regression net).
- The light icon stays opaque (App Store); dark/tinted carry alpha; tinted is grayscale for the system tint.

## Test plan

`xcodebuild test -scheme Snappet -destination 'platform=iOS Simulator,id=…iPhone 17 Pro…'` stays green
(the asset catalog compiles the new appearance slots; the screenshot launch args still drive the same
identifiers). By eye on the sim: module accents inside each module, the paper canvas in light mode, the
new icon in light/dark/tinted home-screen modes.
