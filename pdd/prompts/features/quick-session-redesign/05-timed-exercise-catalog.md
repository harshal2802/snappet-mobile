# Prompt: Quick Session — timed-exercise hierarchy + catalog (Phase 5)

**File**: pdd/prompts/features/quick-session-redesign/05-timed-exercise-catalog.md
**Created**: 2026-06-18
**Chain**: `quick-session-redesign/PLAN.md` → Phase 5 (independent of the climbing phases; builds on the shared session model)
**Context**: `pdd/context/*`; design references (by title) in `docs/ux-research/quick-session-redesign/wireframes.md`: **"Timed exercise — pick or create"** and **"Timed exercise — live timed-set screen"**.

## Goal

Give **timed exercises** the same first-class hierarchy as climbs: tapping **Timed** opens a
**pick-or-create** sheet (searchable catalog + "Create new" + recents + seeded suggestions like
*7s max hang*, *Dead hang*, *Plank*, *Wall sit*, *Repeaters*); selecting/creating one drops a **named
timed-exercise card** with timed **sets logged underneath it** (replacing today's unnamed "Timed
exercise" row). Named timed exercises **persist** for reuse across sessions. This is the timed analogue
of the climb-first hierarchy.

## Context the implementer needs

- Today (`FreeformPlayerView.swift`): the empty-state **Timed** card (`freeform.cardTimed`) and the
  add-menu "Timed exercise" call `addExercise(kind:.duration, name:"Timed exercise")`; sets are logged
  via the existing `LogSetSheet(.duration)` (Timer/Manual). Phase 5 routes these entry points through the
  new pick-or-create sheet instead, and names the card.
- Persistence is **SwiftData** via `SnappetCore`/`SnappetSchema.models` (in `Core/SnappetCore.swift`).
  ANY new `@Model` MUST be added to `SnappetSchema.models` AND to `SnappetBackup` (an enforced invariant
  — see `Core/SnappetBackup.swift` + `SnappetBackupTests`). Shared phone↔watch↔widget value types live in
  `ios/App/Shared/` and are compiled into every target via `project.yml`.
- `SessionExercise` already nests timed sets (`kind == .duration`, `sets: [SetLog]` with `durationSec`)
  and carries `displayName`. Add additive optionals for the spec (migration-safe).

## Approach

1. **`TimedExerciseSpec`** (value type in `ios/App/Shared/`, `Codable`/`Sendable`/`Hashable`): `mode`
   (`enum: openCountUp, maxHang, countDown, repeaters, tabata, emom`), `workSec`, `restSec`, `reps`,
   `sets`, `restBetweenSetsSec`, `leadInSec` (default 3). Plus pure helpers: `totalSeconds` and a
   one-line summary ("7:3 × 6 · 3 sets" / "10s" / "count up"), and **protocol presets** (static
   factories: `.repeaters7x3x6`, `.maxHang10`, `.tabata`, `.emom`, …). Unit-test the pure spec
   (`TimedExerciseSpecTests` in SnappetTests — total time, preset values, summary). NEVER silently snap a
   user-entered value to a preset (the Tindeq antipattern) — presets only pre-fill.
2. **`TimedExerciseCatalog`** (`@Model`, SnappetCore): `id` (UUID), `name`, `categoryRaw` (Hangboard/
   Core/Legs/Other), `specData: Data?` (encoded `TimedExerciseSpec`), `createdAt`, `lastUsedAt: Date?`.
   Add to `SnappetSchema.models` + `SnappetBackup`. Seed a handful of built-ins on first run (or provide
   them as in-memory suggestions if seeding is heavy) so the catalog is never an empty void.
3. **`SessionExercise`** additive fields: `timedSpecData: Data?` → `timedSpec: TimedExerciseSpec?`,
   `timedCategory: String?`. (Migration-safe like the climb fields.)
4. **`PickTimedExerciseSheet`** (new): a searchable list — **"Create new timed exercise"** pinned top
   (`timed.createNew`), then recents/favorites, then category groups, then seeded suggestions. Selecting
   a row (`timed.pick.<id>` or `.suggested`) drops a named `.duration` `SessionExercise` (displayName =
   the exercise name, `timedSpec`, `timedCategory`) onto the canvas. **Create-new** (`timed.create.*`)
   captures NAME + category + STRUCTURE (segmented: Count up / Count down / Repeaters …) with
   protocol-preset chips that pre-fill, a live "Total …" readout, and a "Save to my exercises" toggle
   (persists a `TimedExerciseCatalog`). Search that finds no match shows an inline "Create '<query>'".
5. **Named timed card** in the canvas: the `.duration` exercise renders like a climb card — header
   (timer icon · name · the spec summary · "N sets" · total hold time) with its timed sets underneath;
   "Add set" runs the timer (for `.openCountUp`/`.maxHang`/`.countDown`: the existing `StopwatchView`
   Timer path is fine this phase — the **structured** repeaters/tabata/emom runner is **Phase 6**). On
   finishing a set, auto-create the `SetLog(durationSec:)` (the timer measurement IS the log — one-tap
   confirm, no manual min/sec as the primary path; keep Manual as a fallback). Keep one-tap Repeat.
6. Update the empty-state **Timed** card + add-menu "Timed exercise" to present `PickTimedExerciseSheet`.

## Output
- `ios/App/Shared/TimedExerciseSpec.swift` (+ `TimedExerciseSpecTests.swift`).
- `TimedExerciseCatalog.swift` (@Model) + registration in `SnappetCore.swift`/`SnappetBackup.swift`.
- `PickTimedExerciseSheet.swift` (new); `WorkoutModels.swift` (SessionExercise additive fields);
  `FreeformPlayerView.swift` (entry points + named timed card rendering).
- `decisions.md` entry; `docs/knowledge-graph/data.js` nodes/edges (catalog model + pick sheet).

## Acceptance criteria
- [ ] Tapping **Timed** opens pick-or-create; selecting/creating drops a NAMED timed card; sets log under it.
- [ ] "Create new" persists a reusable `TimedExerciseCatalog` entry that appears in later sessions' recents.
- [ ] Protocol-preset chips pre-fill the spec WITHOUT overriding a value the user then edits; live total updates.
- [ ] New `@Model` is in `SnappetSchema.models` AND `SnappetBackup` (SnappetBackupTests green).
- [ ] `xcodegen generate` + `build-for-testing` clean (Swift 6, 0 new warnings); full `SnappetTests` green
      (incl. new `TimedExerciseSpecTests`).
- [ ] A UITest drives: Timed → create "10s hang" (count-down, preset) → it lands as a named card → log a set.
      (Update `TimedSetTimerTests` or add `TimedExerciseCatalogTests`.)

## Test plan
`xcodegen generate`; `simctl shutdown all`; `build-for-testing`; `test-without-building -only-testing:SnappetTests`; then the timed UITest. Commit (changed files only) only if green; message `feat(quick-session): Phase 5 — timed-exercise hierarchy + catalog (pick or create, named cards)`. Report files/build/tests/SHA + device-only/deferred (the structured interval runner is Phase 6).
