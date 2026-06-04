# Design Review: Dynamic Sessions + Kilter-Driven Climbing

**Created**: 2026-06-04
**Type**: PDD design review (direction → decomposed prompt chain). **Design only — no code yet.**
**Extends**: `09-ios-workout-tracker.md` (the routine-locked tracker) and the Kilter mini-app
(`decisions.md` 2026-06-02, which deliberately kept Kilter *separate* from WorkoutTracker).
**User direction (2026-06-04)**: two asks — (1) *dynamic* sessions where you add work on the fly
(e.g. gym climbing — "I don't know what climb is next"); (2) WorkoutTracker should be able to
**pick climbs/attempts from my Kilter logs** ("based on my Kilter session it picks the climbing").

> This note is the high-value, boundary-crossing piece, so it is written up **before** any code per
> the repo's PDD convention. iOS code can only be compiled/tested on a Mac+Xcode (the
> on-device/verification rules in `decisions.md`), so this captures the model, the decisions, and the
> decomposition that a Mac session then implements + verifies.

---

## 0. Where we already are (don't rebuild this)

| Built | File | Shape it models |
|---|---|---|
| `Routine` → `RoutineExercise` (sets × reps × rest × weight) | `WorkoutModels.swift:180,235` | **① rep/load sets** only |
| `WorkoutSession` → `[SessionExercise]` → `[SetLog]` | `WorkoutModels.swift:202,288` | the live log of ① |
| `WorkoutPlayerView` (walks a **fixed** `exerciseIndex`/`setIndex`) | `WorkoutPlayerView.swift:28,53` | a frozen snapshot |
| `KilterLogEntry` (climb + angle + `KilterAscentStatus` + `attempts`) | `KilterModels.swift:165` | **③ graded attempts**, catalog-backed |
| `KilterSession` (`startedAt`/`endedAt`/`angle`) groups entries | `KilterModels.swift:199` | a board session |
| Grade pyramid (filters `status.isSend`) | `KilterHistoryView.swift:94,115` | raw material for a recommender |

**The single most important fact for both asks:** `Routine`, `WorkoutSession`, `KilterLogEntry`,
`KilterSession` are **all registered in the same store** (`SnappetCore.swift:36`,
`SnappetSchema.models`). So WorkoutTracker reading Kilter data is an in-process `@Query` — **not** a
sync, network call, or new data source. That keeps the on-device-only rule (#1) intact for free.

**Two gaps the user is asking us to close:**
1. **Every session is routine-locked.** The only entry point is `startWorkout(from: Routine)` →
   `makeSession(from:)` (`WorkoutTrackerModule.swift:217,292`). The player then marches through a
   `session.exercises` array frozen at start — it mutates set slots in place
   (`session.exercises[exerciseIndex].sets[setIndex] = …`, `WorkoutPlayerView.swift:530`) but **never
   appends**. There is no "quick start empty," no "add exercise mid-session," no open-ended end state.
2. **Kilter and WorkoutTracker don't talk.** Board climbs carry no HR series, no live metrics, and no
   highlight reel (that pipeline lives only on `WorkoutSession`); and nothing uses your Kilter history
   to drive a session.

---

## 1. The framing: three tracking shapes (recap)

A *session* is a container; the *unit of work* inside it has one of three shapes. The sport is
cosmetic — the **shape** decides the model, the live UI, and the summary.

| Shape | Atomic unit | Logged per unit | Status today |
|---|---|---|---|
| ① rep/load sets | a *set* | reps × load + `completedAt` | `SetLog` — fully built |
| ② continuous distance/duration | a *split/lap* on a stream | distance, duration, pace | not modeled (only `hrSeries`) |
| ③ graded attempts | an *attempt* | grade + outcome + attempt count | `KilterLogEntry` — built, Kilter-only |

Dynamic gym climbing is **Shape ③ without a catalog**. So "add climbing attempts in WorkoutTracker"
needs the *unit* of a session to be able to be a climb attempt — not reps×weight. That is the crux.

---

## Part A — Dynamic / freeform sessions

### A.1 The model is ~80 % ready — this is mostly a player + entry-point job

The persistence already permits a growing, routineless session:
- `WorkoutSession.routineID` is **`UUID?`** — a routineless session is already legal
  (`WorkoutModels.swift:289`).
- `session.exercises` is a plain `[SessionExercise]` Codable composite on the `@Model`; **appending is
  an additive write** — no migration. Same for `SessionExercise.sets: [SetLog]`.

So "freeform" needs **no schema change** for the lifting case. The work is UI:
1. **Quick Start** entry → `WorkoutSession(routineID: nil, routineName: "Quick session", exercises: [])`,
   inserted + live-metrics started, exactly like `startWorkout` but from an empty session.
2. **"+ Add exercise"** in the player → reuse the existing `ExercisePickerView`; append a
   `SessionExercise` (with a sensible `targetSets`/`targetReps` or an open-ended one) to
   `session.exercises` live.
3. **"+ Add set"** on the current exercise → append a `SetLog` (today the set count is fixed at start).
4. **Open-ended end state.** The player assumes a known total to reach the "Done" screen
   (`WorkoutPlayerView.swift:479,545`). A freeform session ends only when the user taps **Finish** —
   so the index logic must tolerate "no next exercise yet" without auto-finishing.

**Decision A.1:** ship freeform **lifting** first because it's self-contained and needs **zero**
schema change — it's the lowest-risk slice and de-risks the player changes (#4 above) that climbing
also needs.

### A.2 Making a "set" polymorphic (the climbing unlock) — `SetKind` + optional `SetLog` fields

For dynamic climbing the logged unit must be a graded attempt, not reps×weight. **Decision:** tag the
*exercise* with a kind, and let `SetLog` carry optional per-kind fields. (An exercise is one shape;
attempts within it are all the same shape — so kind belongs on `SessionExercise`, not per set.)

```swift
enum SetKind: String, Codable, Sendable { case repsWeight, duration, distance, climbAttempt }
// nil rawValue ⇒ legacy reps/weight, so old data needs no rewrite.

// SessionExercise gains:
var kindRaw: String?            // SetKind; nil = .repsWeight (legacy)

// SetLog gains (ALL optional → see the migration note):
var durationSec: Double?        // ② / time-based ① (plank, hang)
var distanceM:   Double?        // ② distance unit
var climbGradeLabel: String?    // ③ ad-hoc grade ("V4", "6c+")
var climbStatusRaw: String?     // ③ reuse KilterAscentStatus ("flash"/"sent"/"project"/"attempt")
var climbAttempts: Int?         // ③ tries
```

> **Migration nuance (don't get this wrong):** `SetLog`/`SessionExercise` are **nested `Codable`
> composites** inside `WorkoutSession`, *not* `@Model`s. SwiftData's lightweight migration only covers
> `@Model` stored properties (the `hrSeries` / Journal-`tags` precedent). For a field **inside** an
> encoded Codable blob, a new **non-optional** key makes `Codable` decoding of old blobs *throw*.
> Therefore every added field here is **`Optional`** (decodes to `nil` when absent) — or uses
> `decodeIfPresent` if a custom decoder is added. This is why `SetKind` is stored as `kindRaw: String?`
> with "nil ⇒ legacy reps/weight", not a non-optional enum.

**Rejected alternative:** a single `measure: SetMeasure` enum *with associated values*
(`.repsWeight(Int, Double)` / `.climb(String, KilterAscentStatus)` …). Conceptually cleanest, but a
Codable enum-with-payloads needs a hand-written `Codable` and is a larger blob-migration surface for no
user-visible gain over optional fields. Revisit only if a fourth+ shape lands.

**Pure + testable:** the per-kind **formatter** ("how does a set/attempt render & summarize") and the
**validator** ("what input does this kind accept") are pure functions over `SetKind` + `SetLog` — no
SwiftData, no UI — so they unit-test on the cloud box (the repo's "pure logic at a thin edge" rule).
The player just switches its input row + complete-action on `exercise.kind`.

---

## Part B — Kilter-driven climbing (the high-value, boundary-crossing ask)

There are two separable features in the user's sentence; B2 is the gold.

### B.1 Mirror — board sessions enter the unified workout world

**Why:** a `KilterSession` today has **no HR, no live metrics, no highlight reel** — that machinery
only exists on `WorkoutSession`. Surfacing Kilter sessions in WorkoutTracker's history/dashboard (and,
later, letting them ride live-HR + the reel pipeline) is the payoff.

Two implementation stances:
- **B.1a Read-only adapter (recommended first):** a pure `ClimbSessionView` value built by querying
  `KilterSession` + its `KilterLogEntry`s (join on `sessionId`) and presenting them through the same
  history/summary surfaces. **No new `@Model`, no duplication, no write path** → no double-source-of-
  truth risk. Kilter stays the owner of board data.
- **B.1b Unified `WorkoutSession` projection:** generate a `WorkoutSession` whose `SessionExercise`s
  are `.climbAttempt` (from A.2), so board climbs literally appear as workouts and can carry
  `hrSeries`. More power (reels/HR) but introduces a sync/ownership question. **Defer** until A.2 ships
  and B.1a proves the surfaces.

**Decision B.1:** start with **B.1a** (adapter), keep Kilter the data owner, no migration.

### B.2 Recommend — build a climbing session from the Kilter grade pyramid

The fun one, and fully on-device. The Kilter history already computes sends/projects per grade
(`KilterHistoryView`). A **pure recommender** turns that into a suggested session:

```
input:  [KilterLogEntry]  (the user's history)  + target angle + session length
output: [SuggestedClimb]  (climbUUID/grade + suggested goal: flash | send | project)
```

Heuristics (all pure, all unit-testable, no device):
- **Working grade** = highest grade with ≥ N sends; **project grade** = one/two above it.
- Mix: mostly working-grade *send* targets + a few project-grade *attempt* targets + a warm-up tier
  below working grade (the classic pyramid).
- Bias toward **unsent** catalog climbs at those grades (cross-ref `KilterCatalog` by difficulty),
  optionally `KilterFavorite`-weighted.

This `KilterRecommender` is the ideal Snappet shape: a deterministic pure function over logged data,
seedable, testable on the cloud box; the UI just renders its output and lets you start a session
pre-populated with the picks (feeding A.2's `.climbAttempt` exercises).

---

## 2. Decomposition (suggested prompt chain)

| Step | Scope | Schema? | Verifiable where |
|---|---|---|---|
| **D1** | Freeform **lifting**: Quick Start + add-exercise/add-set live + open-ended end | none | sim UI test |
| **D2** | `SetKind` + optional `SetLog` fields + pure per-kind formatter/validator (+ tests) | additive (optional) | **cloud** (pure tests) + sim |
| **D3** | Dynamic **climbing** in the player (`.climbAttempt` input row, grade/outcome) | uses D2 | sim UI test |
| **D4** | **B.1a** Kilter→WorkoutTracker read-only history adapter | none | cloud (pure adapter) + sim |
| **D5** | **B.2** `KilterRecommender` pure engine (+ tests) → "Suggested session" → start it | none | **cloud** (pure tests) |
| **D6** | Knowledge-graph + `decisions.md` per shipped step (the standing instruction) | — | review |

D2 + D5 are the pure cores that can be **built and tested on this Linux box**; everything else is
device/sim-gated and lands in a Mac session.

---

## 3. Open forks (product calls — not decided here)

1. **Boundary reversal.** B.1/B.2 partly walk back `decisions.md` 2026-06-02 ("keep Kilter separate").
   Is the intent a one-way read (Workout reads Kilter — low coupling, recommended) or a two-way merge?
2. **Where does the recommender live** — a new tab inside WorkoutTracker, or a "Start a session" button
   inside the Kilter app that hands off? (Leaning: a climbing entry in WorkoutTracker's Quick Start.)
3. **Ad-hoc gym climbing grade scale** — free text, or a fixed V-scale/Font picker? (Leaning: a picker
   per the existing `KilterGradeFormat` precedent so stats are computable.)
4. **Do board climbs need HR/reels** (B.1b) or is read-only history (B.1a) enough for v1?

## 4. What this rules out (for now)

- Continuous **GPS** cardio (running routes/elevation) — Shape ② distance is sketched in A.2 but full
  GPS/splits is its own initiative, not this one.
- A two-way Kilter↔Workout write/sync (B.1b) until A.2 + B.1a prove out.
- The enum-with-payloads `SetMeasure` (chose optional fields — §A.2).
- Any cloud/account path — everything above is an in-process `@Query` over the existing on-device store.
