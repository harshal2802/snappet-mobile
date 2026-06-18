# PLAN: Quick Session redesign — climb-first / exercise-first hierarchy

**Created**: 2026-06-18
**Source**: `docs/ux-research/quick-session-redesign/` (38-agent research + wireframes) · GitHub issue (Quick Session UX)
**Context**: `pdd/context/project.md`, `conventions.md`, `decisions.md`
**Branch**: `claude/quick-session-redesign` (single branch, all phases)

## Why

Today the freeform climbing flow logs *flat* attempt rows: tapping **Climbing** drops a generic
`SetKind.climbAttempt` exercise and every attempt re-enters grade in a sheet. There's no named climb
with a **type** (boulder/top-rope/lead/sport), no scale-aware grade, no gym, no per-climb grouping,
no live stats. Timed is thinner still (an unnamed "Timed exercise" row, no catalog). The redesign
makes the **climb (or named timed exercise) a first-class parent**, with efforts logged underneath —
reusing the rich shapes that already exist for the Kilter board flow (`KilterLogEntry`,
`KilterSessionStats`) but were never wired into freeform.

## Shared data-model SPEC (the contract every phase follows)

**All new persisted fields are additive `Optional`/defaulted** → SwiftData lightweight migration
(the established `SetLog`/`hrSeries` precedent). Never make a stored climb a separate `@Model`; the
parent stays a `SessionExercise(kind: .climbAttempt)`, attempts stay its `sets: [SetLog]`.

### New pure types — `ClimbGrade.swift` (WorkoutTracker, no SwiftUI/SwiftData, unit-tested)
- `enum ClimbType: String, Codable, CaseIterable, Sendable { case boulder, topRope, lead, sport }`
  - `label` ("Boulder"/"Top-rope"/"Lead"/"Sport"), `symbol` (SF), `defaultScale: GradeScale`
    (boulder→`.vScale`, others→`.yds`), `companionScale` (V↔Font, YDS↔French toggle),
    `statusLabel(_:KilterAscentStatus) -> String` (boulder uses `.label`; routes relabel
    flash→"Onsight", sent→"Redpoint", project→"Project", attempt→"Fell"). `isRoute: Bool`.
- `enum GradeScale: String, Codable, CaseIterable, Sendable { case vScale, font, yds, french }`
  - `label`, `rungs: [String]` (ordered easiest→hardest: V0…V17; Font 4..9a+; YDS 5.6..5.15d; French
    4..9a), `difficulty(for label: String) -> Double?` (ordinal index → float; for exact pyramid /
    hardest-send math), `companion: GradeScale`.
- Reuse **`KilterAscentStatus`** (flash/sent/project/attempt, `isSend`) for ALL types — no enum
  change (route relabels are display-only). Reuse **`KilterMilestones.isFirstSend`**.

### Extend `SessionExercise` (additive optionals + computed accessors)
- `climbTypeRaw: String?` → `climbType: ClimbType?`
- `climbGradeLabel: String?` (the **climb's** grade — the source of truth, edited at climb level)
- `climbGradeScaleRaw: String?` → `climbGradeScale: GradeScale?`
- `gym: String?` (session/first-climb-level, inherited onto new climbs)
- (timed, Phase 5) `timedSpecData: Data?` → `TimedExerciseSpec?`, `timedCategory: String?`

### Logging an attempt
Each new attempt `SetLog` is **stamped with the parent climb's grade** (`climbGradeLabel`) so the
existing pure `FreeformSummary`/`KilterSessionStats`-style reads keep working unchanged and old data
still renders. Attempt owns: `climbStatusRaw`, `climbAttempts`, optional `durationSec` (timed),
`completedAt`.

### Live stats bridge — `FreeformClimbStats` (pure, unit-tested)
Map a session's `.climbAttempt` exercises → `[KilterClimbLog]` (difficulty via
`ClimbGrade`/`GradeScale.difficulty`) → `KilterSessionStats.make(...)`. One climb = one log; status =
its resolved outcome (best of its attempts); attempts = count; start/end from attempt `completedAt`.

## Design-token decisions
- Keep the **Workout module ember** (`SnappetColor.workout`) for primary CTAs/timers — the module's
  established accent (native consistency) — NOT the research's coral. Boulder grade pills use
  **Kilter amber** (`SnappetColor.kilter`); route pills a cool tint. Reuse `snappetCard`/`snappetTile`,
  the glass-HUD treatment, `StopwatchView`, `CelebrationBurst`, the docked command bar.

## Phases (each = one commit, build-green + unit-tests-green before moving on)

1. **Climb-first hierarchy (all types, scale-aware grade).** `ClimbGrade.swift` + tests; extend
   `SessionExercise`; "Add a climb" sheet (type segmented → scale-aware grade picker + recent chips,
   name, gym); climbs render as expandable cards with rolled-up header (type · grade pill · status ·
   N attempts · time-on-climb); **untimed** attempt = one inline outcome tap (no per-attempt grade).
   Update `SetMeasure`/`FreeformSummary` to read climb-level grade. Keep a11y ids stable where
   possible; update affected unit + UI tests.
2. **Timed-attempt FOCUS cover.** Lift `StopwatchView(.countUp)` into a full-screen glass FOCUS cover
   (climb name/type/grade chips + HR chip + giant Stop) → on Stop, capture duration + inline outcome
   → append attempt → auto-dismiss. Replaces the in-sheet climb timer toggle.
3. **Live stats ribbon + milestones.** `FreeformClimbStats`; ambient one-line ribbon above the climb
   cards (sends · hardest · mini-pyramid) tap-to-expand sheet (full pyramid, sends/hr, time-on-wall,
   effort); fire `CelebrationBurst` at the logging moment for genuine history bests.
4. **Route types + scales polish.** YDS/French rungs, V↔Font / YDS↔French scale toggle, route status
   relabels, sticky scale per type.
5. **Timed-exercise hierarchy + catalog.** `TimedExerciseCatalog` `@Model` + `TimedExerciseSpec`
   value (Shared); pick-or-create sheet (search · Create new · recents · seeded catalog); named timed
   cards with nested sets; "the timer is the log" capture.
6. **Structured interval runner.** Repeaters/Tabata/EMOM full-cover from `TimedExerciseSpec` (phase
   label, draining count-down, set·rep counter, next-phase chip, 3-2-1 lead-in, per-phase cues).
7. **Polish.** Remembered rest timers, recent-grade/recent-gym chip rails, type-adaptive completion
   summary (pyramid / hold-time / volume), entry type-chooser refinements.

## Test strategy
- Pure logic (ClimbGrade, FreeformClimbStats, SetMeasure/FreeformSummary updates) → `SnappetTests`
  (XCTest, no device) — the primary gate, run every phase.
- Build-for-testing green every phase (Swift 6, 0 warnings).
- Update the affected UITests to the new flow; keep them compiling. Full UITest suite is ~14–30 min +
  sim-flaky (decisions.md) — run targeted UITests where cheap; rely on unit + build + on-device for
  the rest.
- Each phase commits its code; this PLAN + a `decisions.md` entry ship alongside.
