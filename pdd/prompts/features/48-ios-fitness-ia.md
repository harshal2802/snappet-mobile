# Prompt: iOS fitness IA cleanup — disambiguate the two Workout modules, label the tracker sections, surface the Video Studio

**File**: pdd/prompts/features/48-ios-fitness-ia.md
**Created**: 2026-06-11
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Product-review roadmap [#100](https://github.com/harshal2802/snappet-mobile/issues/100) → Wave 2 (iOS), theme: information architecture
**Source**: GitHub issue [#74](https://github.com/harshal2802/snappet-mobile/issues/74)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Three discoverability failures hide the suite's biggest fitness surface area. (1) Two
near-identically named cards — "Workout Reels" and "Workout" — sit side by side in the App
Library; after an Apple Watch run the natural tap is "Workout", which is actually the gym
tracker (both modules even produce highlight reels, so nothing downstream corrects the mistake).
(2) The tracker's five-section segmented control is icon-only SF Symbols — users learn the
suite's largest module by trial-and-error, and Settings hides *inside* the section control.
(3) The CapCut-style multi-clip Studio is reachable only via one button four levels deep
(Apps → tracker → History → session detail), disabled until the session has video, and undersold
as "Open studio (multi-clip)" — no module surface mentions a video editor exists. Fix the IA so
the first tap lands right, every section is identifiable without tapping, and the Studio is
discoverable from the module level.

## Context the implementer needs

- `WorkoutModule.swift` (id `"workout"`, title "Workout Reels") vs `WorkoutTrackerModule.swift`
  (id `"workout-log"`, title "Workout") — the colliding cards render in `AppLibraryView`.
  **Module ids are persisted** in `UsageRecord.module` rows and `ModuleRoute` deep links, and key
  `SnappetColor.moduleAccent` — rename display strings only, never ids. Check every place the
  display name renders: cards, nav titles, Home activity-feed rows (which captioned with
  `record.module.capitalized` → "Workout-Log"), knowledge-graph descs.
- The tracker's section `Picker(.segmented)` renders `Image(systemName:)` per segment with the
  title only as an `accessibilityLabel`. SwiftUI's segmented style can't mix icon+text. Four
  XCUITest files address segments via `app.segmentedControls.buttons["<title>"]`
  (`WorkoutWalkthroughTests`, `LiveWorkoutStudioWalkthroughTests`, `FreeformFlowWalkthroughTests`,
  `WorkoutPauseBackgroundTests`) — text-only segments on the *native* segmented style keep those
  queries working; a custom control would break them all. Two of the four tap a "Settings"
  segment and must follow it to wherever Settings moves.
- Exactly two `StudioEditorView` entry points exist: `SessionDetailView`'s
  `openStudio()` (find-or-create `StudioProject` + `fullScreenCover`, `.disabled(!hasVideo)`,
  identifier `openStudio`) and `Features/Kilter/KilterClipStudio.swift` — **do not touch the
  Kilter one** (a sibling worktree owns Features/Kilter, project.yml, SnappetApp, RootShell).
- `SessionMedia` rows are session-scoped by `sessionID` FK with `kind` (photo/video) — a pure
  selection over them can decide which sessions the studio can open.
- The live-workout banner is a `safeAreaInset` on `WorkoutHomeView`; whatever Settings becomes,
  pushed-screen visibility of that banner is a trade-off to record.

## Approach

1. **Disambiguate**: retitle the tracker "Gym Tracker", subtitle "Routines, sets, PRs & a video
   studio" (also advertises deliverable 3); ids untouched. Cross-link both ways: a "Looking for
   your Apple Watch workouts?" row at the bottom of the tracker dashboard (empty state included —
   that's where the misdirected tap lands) opening Workout Reels via `router.open(module:)`, and
   a mirrored footer row in `WorkoutListView` back to Gym Tracker. Home feed rows caption with
   the registry display title (fallback: capitalized raw id for retired modules).
2. **Label sections**: `WorkoutSection` drops `.settings` and gains text `segmentTitle`s
   (Dashboard / Exercises / Routines / History) rendered as `Text` segments on the native
   segmented style; nav title for the root section becomes "Gym Tracker". Settings moves to an
   always-present toolbar gear (`workout.settings`) pushing a new `WorkoutSettingsRoute` via
   `navigationDestination` (a sheet would break `WorkoutSettingsView`'s own pushes).
3. **Surface the Studio**: new `Features/WorkoutTracker/StudioEntry.swift` — pure
   `candidates(history:media:limit:)` (newest video-bearing sessions), `videoCounts` /
   `videoSessionIDs`, capture-ordered `seedClips(for:media:)`, plus the one `@MainActor`
   `findOrCreateProject(for:media:context:)` SwiftData edge extracted from
   `SessionDetailView.openStudio` so every entry resumes the same project. Render: a dashboard
   **Video Studio** card ("Open in Studio" rows, how-to hint when none); History rows get a
   Studio badge + leading-swipe shortcut when the session has video; the session-detail button is
   renamed "Edit in Video Studio" (identifier `openStudio` kept). `WorkoutHomeView` hosts the
   module-level `fullScreenCover`.

## Output

- `ios/App/Snappet/Features/WorkoutTracker/WorkoutTrackerModule.swift` — rename, text segments,
  settings route + gear, media query, studio cover + `openStudio(for:)`.
- `ios/App/Snappet/Features/WorkoutTracker/StudioEntry.swift` (new) — pure core + SwiftData edge.
- `ios/App/Snappet/Features/WorkoutTracker/WorkoutDashboardSection.swift` — Video Studio card +
  Reels cross-link.
- `ios/App/Snappet/Features/WorkoutTracker/HistorySectionView.swift` — badge + swipe shortcut.
- `ios/App/Snappet/Features/WorkoutTracker/SessionDetailView.swift` — relabel; shared
  find-or-create.
- `ios/App/Snappet/Features/Workout/WorkoutListView.swift` — Gym Tracker cross-link footer.
- `ios/App/Snappet/Features/Home/HomeDashboardView.swift` — feed-row display-title mapping.
- `ios/App/SnappetTests/StudioEntryTests.swift` (new); updates to `WorkoutWalkthroughTests` +
  `LiveWorkoutStudioWalkthroughTests` (Settings gear).
- `docs/knowledge-graph/data.js`, `pdd/context/project.md`, `pdd/context/decisions.md`.

## Acceptance criteria

- [ ] The two fitness cards are no longer title-ambiguous; module ids `workout` / `workout-log`
      unchanged (unit-tested).
- [ ] All four tracker sections are identifiable without tapping (text segments); Settings
      reachable from the toolbar gear on every section.
- [ ] The Studio is discoverable from the module level (dashboard card + History shortcut), and
      every entry opens the same `StudioProject` as the session-detail button.
- [ ] Existing UI tests updated where identifiers/affordances moved; all other identifiers
      (`moduleCard.workout-log`, `openStudio`, segment titles Exercises/Routines/History) kept.
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).
- [ ] No platform imports added to `HighlightEngine`.
- [ ] `decisions.md` updated (rename-not-re-id, native-segmented-over-custom, settings-as-push
      trade-off, shared find-or-create).

## Constraints

- On-device only; no backend/network/accounts.
- Do not touch `Features/Kilter/`, `project.yml`, `SnappetApp.swift`, `RootShell.swift` (sibling
  worktree, issue #75).
- State verification honestly: type-check ≠ simulator run; the walkthrough suite is the
  orchestrator's verification pass.

## Test plan

1. `cd ios/App && xcodegen generate` then build; `SnappetTests/StudioEntryTests` cover the pure
   selection/seeding + the disambiguation guarantees with no simulator dependency.
2. Simulator: `WorkoutWalkthroughTests` + `LiveWorkoutStudioWalkthroughTests` (Settings via gear;
   `-uiTestSeedStudioDemo` seeds video-bearing sessions, so the dashboard's Video Studio card and
   the History badge render there), `FreeformFlowWalkthroughTests`, `WorkoutPauseBackgroundTests`,
   `SuiteSmokeTests` (ids unchanged).
3. By eye: App Library shows "Workout Reels" vs "Gym Tracker"; tracker dashboard shows the Video
   Studio card + Reels cross-link; Reels list shows the Gym Tracker footer.
