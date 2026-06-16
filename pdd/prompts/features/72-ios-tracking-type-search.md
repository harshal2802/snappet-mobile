# Prompt: Tracking-type search facet for the workout History

**File**: pdd/prompts/features/72-ios-tracking-type-search.md
**Created**: 2026-06-16
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Workout-with-timer initiative — **PR 6 of 6** (the final slice: a tracking-type filter for History; closes the initiative that added timed sets · repeat-set · the per-attempt climb timer · named free-flow climbs). Ideated + architected 2026-06-15 on this branch.
**Source**: In-repo ideation + architecture plan — Gym Tracker "Workout with timer" (timed sets · repeat-set loop · free-flow climb sessions · tracking-type search), 2026-06-15.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Let the user filter the workout **History** by **what a past session tracked** — Reps & weight /
Timed / Climb (the three `SetKind` cases) — so a bouldering/route session, a stretch/hold session, and
a lifting session are each findable at a glance. Today History is searchable by routine name
(`.searchable`) with a one-tap routine-name chip row (issue #73); this PR adds a **second chip row** —
a tracking-type **facet** — that composes with both: a session is kept when **any** of its exercises
tracks one of the selected kinds. With nothing selected the facet is inert (all sessions through), so
the prior behavior is the default.

## Context the implementer needs

- **A session's tracking types are derived, not stored.** A `WorkoutSession`'s tracking types are the
  set of `ex.kind` across its `exercises` (`SessionExercise.kind`, which reads `kindRaw` and defaults
  to `.repsWeight` for legacy/routine data). So the facet is a **pure derivation over existing data —
  no model change** (`SetKind` and `SessionExercise.kindRaw` already exist).
- **`HistorySearch` is the pure filter funnel.** `HistorySearch.apply(_:query:routine:)` in
  `HistorySectionView.swift` is unit-tested in `SnappetTests/HistorySearchTests.swift` with no
  simulator. Extend it — keep the new tracking-type filter in the same pure enum so it's tested the
  same way and composes in the one pipeline (routine chip → facet → text query).
- **There's a chip-row pattern to mirror.** `HistorySectionView.routineChips` is a horizontal
  `ScrollView` of pill `Button`s: active = `SnappetColor.workout.opacity(0.2)` fill +
  `SnappetColor.workout` foreground, `.buttonStyle(.plain)`, `.snappetAnimation(SnappetMotion.quick,
  value: on)`, a leaf `accessibilityIdentifier`, `.accessibilityAddTraits(on ? .isSelected : [])`.
  `ExerciseFilters`/`ExerciseSearch` (`ExerciseCatalog.swift`) is the repo's faceted-filter template
  (a `Set` per facet; empty set = no filter).
- **`SetKind` already supplies the chip content.** `.display` ("Reps & weight" / "Time" / "Climb")
  and `.symbol` ("dumbbell.fill" / "timer" / "figure.climbing"). Iterate `SetKind.allCases`.
- **UI-test lessons (PR 2–5).** Do **not** put `.accessibilityIdentifier` on a composite/custom view —
  on iOS 26 it collapses the a11y subtree. Each chip is a **leaf** `Button` with its own id
  `history.kindChip.<rawValue>` (e.g. `history.kindChip.duration`). Query History rows
  **type-agnostically** (`app.descendants(matching: .any).matching(identifier: "historyRow")`, NOT
  `app.cells`) and assert a **distinctive** narrow/widen of the row set.

## Approach

Pick the cleaner of (a) add a `kinds:` param to `apply` vs (b) a composable
`filterByTrackingTypes(_:kinds:)` applied in the pipeline. **Chosen: both, layered** — a
`filterByTrackingTypes(_:kinds:)` carries the one-line "any selected kind" rule (composable + directly
testable), and `apply` gains a defaulted `kinds: Set<SetKind> = []` param that calls it in the funnel
(routine → facet → query). The default keeps the existing `apply` call site working and the existing
tests untouched.

1. **`HistorySectionView.swift` (pure `HistorySearch`)**:
   - Add `static func filterByTrackingTypes(_ sessions:, kinds: Set<SetKind>) -> [WorkoutSession]`:
     `kinds` empty ⇒ pass-through; else keep sessions where `exercises.contains { kinds.contains($0.kind) }`.
   - `apply(_:query:routine:kinds: Set<SetKind> = [])` calls it between the routine filter and the text query.
2. **`HistorySectionView.swift` (view)**:
   - Add `@State private var kindFilter: Set<SetKind> = []`; pass it into the `filtered` pipeline.
   - Add a `kindChips` row mirroring `routineChips` (label `kind.display`, icon `kind.symbol`, toggle
     insert/remove, active styling, leaf id `history.kindChip.<rawValue>`); shown once `!history.isEmpty`.
   - Render it in the existing top `.safeAreaInset` alongside the routine chips (a small `VStack`).
3. **Knowledge graph**: `wt-history` desc gains the tracking-type facet sentence. No new node/edge —
   it's another filter on the existing History section.

## Output

- Changed: `ios/App/Snappet/Features/WorkoutTracker/HistorySectionView.swift` (pure
  `filterByTrackingTypes` + `kinds:` param on `apply`; `kindFilter` state + `kindChips` facet row).
- Tests: extend `ios/App/SnappetTests/HistorySearchTests.swift` (empty kinds = all; single kind keeps
  only sessions containing it; multi-kind = union; composition with routine + query); new
  `ios/App/SnappetUITests/TrackingTypeFilterTests.swift` (Quick Start → log a Timed set → Finish →
  History → toggle the Time chip keeps the row, then narrow to Reps & weight only hides it).
- `docs/knowledge-graph/data.js`: `wt-history` desc gains the tracking-type-facet sentence.
- `pdd/context/decisions.md`: a 2026-06-16 entry — tracking-type facet as a pure derivation over
  `SessionExercise.kind` (no model change), composed in `HistorySearch`, chip row mirroring the routine
  chips, any-of-kind (union) semantics, leaf chip ids.

## Acceptance criteria

- [ ] History shows a tracking-type chip row (Reps & weight / Time / Climb) once any session exists;
      tapping a chip toggles it; the active chip is styled like the routine chips.
- [ ] A session is kept when **any** of its exercises tracks a selected kind; multiple chips = union;
      no chip selected = all sessions (the facet is inert by default).
- [ ] The facet composes with the routine chip and the text query in one pure pipeline.
- [ ] Filtering is the pure, unit-tested `HistorySearch` (no SwiftUI in the logic); no
      `SetKind`/`SessionExercise`/`WorkoutModels` change.
- [ ] `HistorySearchTests` covers empty/single/multi-kind and composition without a simulator.
- [ ] A UI test drives the real flow (or falls back to chip-render + toggle) using leaf chip ids
      `history.kindChip.<rawValue>` and a type-agnostic row query.
- [ ] The app type-checks against the iOS SDK (Swift 6, 0 warnings); `HighlightEngine`, the watch, the
      widget, and the guided `WorkoutPlayerView` are untouched.
- [ ] `docs/knowledge-graph/data.js` and `pdd/context/decisions.md` updated in this change.

## Constraints

- On-device only; no backend / network / accounts.
- **Reuse, don't re-implement.** Use the existing `SetKind` (`.display`/`.symbol`/`allCases`),
  `SessionExercise.kind`, the `HistorySearch` funnel, and the `routineChips` styling — no model field,
  no second filter funnel.
- Do not touch the watch/widget targets, `HighlightEngine`, the guided `WorkoutPlayerView`, or release
  workflows.
- Honest verification: a clean type-check ≠ a device run. The orchestrator runs the simulator suite;
  this change ships `xcodegen generate`-verified plus the pure `HistorySearchTests`.

## Test plan

1. `cd ios/App && xcodegen generate`, then
   `xcodebuild test -scheme Snappet -only-testing:SnappetTests/HistorySearchTests
   -destination 'platform=iOS Simulator,name=iPhone 16 Pro'` (orchestrator); plus
   `-only-testing:SnappetUITests/TrackingTypeFilterTests` for the facet flow.
2. By eye on the sim: finish a Timed-only Quick Start session → History → toggle "Time" (the row
   stays) → add "Reps & weight" (still shown, union) → turn "Time" off (the timed session disappears).
