# Prompt: Workout tracker mini-app (gym/strength suite app)

**File**: pdd/prompts/features/09-ios-workout-tracker.md
**Created**: 2026-05-31
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: standalone suite addition (parallels the Pomodoro/Habit/Budget mini-apps).
**Source**: web Snappet suite `src/frontend/apps/workout/` (the port target).
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md` (§"Adding a mini-app to the suite").

## Goal

Port the web Snappet suite's `workout` app to iOS as a self-contained gym/strength tracker —
**distinct** from the flagship "Workout Reels" module (HR highlight videos). It gives the suite a
real fitness-logging app: browse a large exercise catalog, build routines, run a guided session with
per-set logging + a rest timer, and review history / PRs / progress. Proves the daily-app-suite
thesis with one more compounding on-device app.

## Context the implementer needs

- The web app (`types.ts`, `starters.ts`, `progress.ts`, `WorkoutPlayer.tsx`) defines the shape:
  Exercise (Free Exercise DB schema) → Routine (exercise prescriptions) → WorkoutSession (per-set
  logs). PRs rank sets by `weightKg × reps`; weights normalise to kg.
- The exercise id "workout" is already taken by Workout Reels — this module uses id `workout-log`
  and lives in `Features/WorkoutTracker/`.
- Suite integration is two central edits only: `ModuleRegistry.all` and `SnappetSchema.models`.
- A bottom tab bar collides with the suite's Home/Apps tab bar → use a **top segmented control** for
  the 5 sections; deep navigation rides the App Library's NavigationStack; the player is a
  full-screen cover.

## Approach

- `WorkoutModels.swift` — taxonomy enums (mirror `types.ts` raw values), `Exercise` value type with
  lenient `Codable`, nested `RoutineExercise`/`SetLog`/`SessionExercise`, and `@Model`s `Routine`,
  `WorkoutSession`, `CustomExercise` (nested lists stored as Codable composites — loaded/edited whole).
- `ExerciseCatalog.swift` — load bundled `Resources/exercises.json` once; `ExerciseFilters` + search.
- `WorkoutProgress.swift` — `progress.ts` math (PR / volume / session count / unit conversion) + an
  `ExerciseResolver` merging catalog + custom and resolving ids → names.
- `StarterRoutines.swift` — the 15 starters, seeded on first launch (dismissal-aware).
- Section views (Dashboard / Browse / Routines / History / Settings) + detail/editor/player/progress
  screens. `WorkoutTrackerModule.swift` vends the descriptor and coordinates routing + session
  lifecycle.

## Output

21 files under `Features/WorkoutTracker/` (incl. bundled `exercises.json`) + the two central edits.

## Acceptance criteria

- [x] Browse the full catalog with search + filters; create/edit/delete custom exercises.
- [x] Build/edit routines (sets/reps/rest/weight/notes, sport/level); 15 starters seeded.
- [x] Guided player: per-set reps/weight logging, rest-timer ring + skip + haptics, skip-exercise,
      save/discard, resume-in-progress (progress persisted per set).
- [x] History + session detail; dashboard streak/volume/PRs + charts; per-exercise progress chart.
- [x] App builds (`xcodebuild` BUILD SUCCEEDED, iPhone 17 Pro sim); launches into the module;
      dashboard renders with starters; Browse decodes all 873 exercises.
- [x] No platform imports added to `HighlightEngine`; engine tests still 18/18.

## Constraints

- On-device only; no backend/network/accounts. Exercise catalog bundled (offline); remote exercise
  photos dropped in favour of SF Symbols.
- Persist via SwiftData / Snappet Core; log usage so the Home dashboard aggregates workout activity.
