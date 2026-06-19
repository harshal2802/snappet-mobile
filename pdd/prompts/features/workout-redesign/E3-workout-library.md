# Prompt: E3 — Workout Library (a discipline-spined library of all workout types)

**File**: pdd/prompts/features/workout-redesign/E3-workout-library.md
**Created**: 2026-06-19
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: `workout-redesign/PLAN.md` → E3 (wave 2; depends on E0; feeds E4's routine builder)
**Source**: GitHub issue [#183](https://github.com/harshal2802/Snappet/issues/183) · Part of epic #179
**Design**: `docs/ux-research/workout-redesign/README.md` §4 "Workout Library", §9 scope guards, §10 Q5/Q6;
`wireframes.html` Flow 3 (library browse + adaptive detail)
**Context**: `pdd/context/project.md`, `conventions.md`, `decisions.md` (2026-06-19 E3 entry)

## Goal

The "Exercises" tab was a flat, strength-only catalog of 873 Free-Exercise-DB rows; climbing, timed/
hangboard, running and dance had no home there, and three disconnected "libraries" (the strength catalog,
`TimedExerciseCatalog`, ad-hoc climbs) never cross-linked. Replace it with a **library organized by workout
TYPE as the top facet** (Apple-Fitness+-style), in the Pulse Pro language — so a hangboard protocol, a
bouldering style and a 5 km run sit beside a bench press. This is the cross-discipline browse surface that
E4's block-based routine builder consumes.

## Context the implementer needs

- The discipline axis (`WorkoutDiscipline`) + its view-layer `accent` already exist (E0/parity). The pure
  recap/recents selectors (`SessionRecap`, `RecentSessions`, `FreeformClimbStats`, `WorkoutMath`) are reusable.
- The browse segment is `WorkoutSection.browse` (`WorkoutTrackerModule.swift`), rendered by the flat
  `ExerciseBrowserView`. The **"Exercises → Library" display rename was deferred from E0 to here**: change
  `browse.title` to "Library" but KEEP the `browse` case id + the `workout.sectionPicker` a11y id stable, and
  re-point the UITests that tap the segment by the literal label.
- `ExerciseResolver` (`WorkoutProgress.swift`) merges the bundled catalog + custom exercises. The persisted
  identity is a `String exerciseId` (routines/history store it) — the new value type must WRAP, never replace it.
- Scope guard (README §9/§10 Q5): a saved climb/run **template `@Model`** would have to be wired into BOTH
  `SnappetSchema.models` AND `SnappetBackup` (the golden-byte tripwire). Make a clear new-@Model-vs-templates call.

## Approach

- **Pure core** (`Library.swift`, `LibraryBuilder.swift` — Foundation only, unit-tested):
  - `LibraryItem` ({id, title, subtitle, discipline, symbol, isCustom, source}) where `id` carries the
    `exerciseId` verbatim for strength, `timed:<uuid>` / `timed.seed:<key>` for timed, and the starter key for
    climb/run. A `Source` enum holds the backing value (strength `Exercise`, timed spec+category, climb/run
    starter) for the detail + the E4 builder.
  - In-memory `ClimbStarter`/`RunStarter` + `RunTerrain` starter templates (NO new `@Model` — the scope call).
  - `LibraryBuilder.items(strength:timed:)` merges all sources + seeds; `discipline(for: ExerciseCategory)`
    reconciles the two "type" vocabularies (cardio→run, rest→strength); `apply(...)` = free-text + the
    discipline-aware faceted filter; `LibraryFacets` swaps facets by discipline (`keepOnly(_:)` drops stale ones).
  - `LibraryRecords` = best-effort discipline-adaptive records from session blobs (no per-movement @Model — deferred).
- **Views**: `WorkoutLibraryView` (discipline chip bar = top facet · "Recent across all types" band reusing
  `RecentSessions.rows` · faceted-filter sheet that swaps sections by discipline · `LibraryItemRow`).
  `LibraryItemDetailView` routes strength → existing `ExerciseDetailView`; climb/run/timed → an adaptive
  detail (discipline header → metadata/how-to → records `StatRibbon`). **Muscle map is strength-only** (no
  faked anatomy). `ExerciseResolver.library(timed:)` is the thin I/O edge; `LibraryItemRoute` the push target.
- **IA rename**: `browse.title` → "Library" (case id + a11y id unchanged); UITests re-pointed.

## Output

- `Library.swift` (`LibraryItem` + `ClimbStarter`/`RunStarter`/`RunTerrain`).
- `LibraryBuilder.swift` (`LibraryBuilder` + `LibraryFacets` + `LibraryRecords`).
- `WorkoutLibraryView.swift`, `LibraryItemDetailView.swift`; `ExerciseResolver.library(timed:)`;
  `LibraryItemRoute` + the `.browse` swap + the navigationDestination in `WorkoutTrackerModule.swift`.
- `ExerciseBrowserView.swift` trimmed to the still-shared `ExerciseRow` + the `ExerciseFilters` extension.
- `SnappetTests/LibraryTests.swift`; UITest rename in `WorkoutWalkthroughTests.swift`.

## Acceptance criteria

- [x] Discipline is the top facet (a chip row); the faceted filter swaps per discipline (strength muscle/
      equipment/"no equipment"; climb style; timed protocol; run terrain).
- [x] A "Recent across all types" band surfaces mixed-discipline sessions, deep-linking to detail.
- [x] Detail is discipline-adaptive with a records header (StatRibbon); muscle map strength-only.
- [x] `LibraryItem` wraps the `exerciseId` contract; the builder + filter + records are pure value types with
      unit tests; views thin. No new `@Model` (climb/run = in-memory templates — the documented scope call).
- [x] `browse` case id + `workout.sectionPicker` a11y id unchanged; the Library rename UITest passes.
- [x] App type-checks against the iOS SDK (Swift 6, 0 warnings); no platform imports added to `HighlightEngine`.

## Constraints

- On-device only; no new network. No new `@Model` / backup change (scoped to in-memory templates).
- The per-movement cross-session history `@Model` is DEFERRED (README §9) — records read session blobs best-effort.

## Test plan

1. `xcodebuild build-for-testing` + `SnappetTests/LibraryTests` (builder/filter-swap/category-seam/records).
2. Re-run `WorkoutWalkthroughTests` (the Library rename) — green.
3. Eyeball Flow 3 of `wireframes.html` against the chip bar + adaptive detail (light + dark).
