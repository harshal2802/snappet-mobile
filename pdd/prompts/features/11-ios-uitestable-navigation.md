# Prompt: Button-driven, UI-testable suite navigation (SuiteRouter)

**File**: pdd/prompts/features/11-ios-uitestable-navigation.md
**Created**: 2026-05-31
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: follow-up to `10-ios-workout-tracker-ux-fixes.md` (born from a deep UI/UX testing pass).
**Source**: user request — "make the whole app UI-testable".
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md` (§"Adding a mini-app"), `pdd/context/decisions.md`.

## Goal

Make the suite drivable by XCUITest end-to-end. A deep UI/UX pass proved XCUITest cannot activate
SwiftUI `List` `NavigationLink(value:)` rows in this app (they expose as `Cell → StaticText`, no button
trait — no tap/cell/identifier/coordinate navigates), which blocked automated coverage of every detail
screen. Convert intra-app navigation to plain `Button`s that push onto a shared `NavigationPath` so the
rows are real, hittable controls — and add an XCUITest harness that exercises the flows + screenshots.

## Context the implementer needs

- Modules are pushed into the App Library's `NavigationStack` and must not nest their own. Programmatic
  push therefore needs a shared path the modules can reach.
- The App Library's *closure-based* `NavigationLink` cards already navigate fine under XCUITest; only the
  modules' *value-based* `NavigationLink(value:)` rows don't.

## Approach

- **`Core/SuiteRouter.swift`** (new): `@MainActor @Observable SuiteRouter { var path; push(_:); popToRoot() }`
  + `struct ModuleRoute: Hashable`. Injected via `.environment` at the App Library.
- **AppLibraryView**: `NavigationStack(path: $router.path)`; module cards become `Button { router.push(ModuleRoute) }`
  with `accessibilityIdentifier("moduleCard.<id>")`; `navigationDestination(for: ModuleRoute.self)`.
- **Every module list row** → `Button { router.push(value) } label: { Row }` + an `accessibilityIdentifier`
  (`routineRow`, `exerciseRow`, `journalRow`, `expenseGroupRow`, `workoutReelRow`, `customExerciseRow`,
  dashboard PR/quick-start). Module roots read `@Environment(SuiteRouter.self)`; the workout tracker threads
  `open`/`openRoutine`/`openProgress` closures from `WorkoutHomeView` to its section views. `navigationDestination(for:)`
  handlers stay. `RootShell`'s screenshot hook also injects a `SuiteRouter`.
- **Session detail** pushes a lightweight `SessionRoute(id:)` rather than the `WorkoutSession` model
  (which is also the player `fullScreenCover(item:)` — pushing the model type while that cover exists
  wedges the push).
- **Test target** `SnappetUITests` (via `project.yml`): `WorkoutWalkthroughTests` (deep workout flow +
  screenshots) and `SuiteSmokeTests` (every module opens from its card).

## Acceptance criteria

- [x] App type-checks (Swift 6) and `xcodebuild` for the iPhone 17 Pro sim → BUILD SUCCEEDED.
- [x] XCUITest drives App Library card → Routines/Exercises rows → detail; runs the player → finish → Dashboard.
- [x] `SuiteSmokeTests` opens all 8 mini-apps from their cards.
- [x] No module nests its own `NavigationStack`; no platform imports added to `HighlightEngine`.

## Known limitation

- The **History → session detail** row is the one row kept as a value-based `NavigationLink`: a `Button`
  there provably never fired its action on tap (a narrow SwiftUI/List quirk, confirmed via logging against
  a working control). It still works for users (NavigationLink), but is **not** XCUITest-tappable. Documented
  rather than shipping a Button that doesn't fire.

## Test plan

1. `cd ios/App && xcodegen generate && xcodebuild test -scheme Snappet -sdk iphonesimulator -destination 'id=<sim>' -only-testing:SnappetUITests CODE_SIGNING_ALLOWED=NO` → both tests pass.
2. Extract per-step screenshots via `xcrun xcresulttool export attachments`.
3. Manual sim pass: confirm Journal/Expense/Workout-Reels rows open their detail (row nav uses the same proven Button+router pattern).
