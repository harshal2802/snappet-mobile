# Design + Plan: Dynamic Sessions + Kilter-Driven Climbing

**Created**: 2026-06-04 · **Refreshed**: 2026-06-07 (re-baselined against `main`; recommender + freeform/ad-hoc climbing shipped)
**Type**: PDD design review → decomposed plan, with one slice implemented.
**Extends**: `09-ios-workout-tracker.md` (routine-locked tracker) + `18-ios-kilter-rich-session.md`
(the rich Kilter session that `main` shipped 2026-06-05).
**User direction**: (1) *dynamic* sessions you grow on the fly (gym climbing — "I don't know the next
climb"); (2) pick climbs/attempts **from my Kilter logs**.

---

## 0. Re-baseline — what `main` already shipped (read this first)

Between the first draft of this doc and now, `main` landed **`18-ios-kilter-rich-session`**, which builds
most of the original "Part B" — and builds it *better* than this doc first proposed:

| Capability | Where `main` put it | Effect on this plan |
|---|---|---|
| Live HR on a climbing session (Watch/BLE) | `LiveMetricsContext` (generalized `MetricsSource`) + `KilterSessionManager` | **done** — climbing rides HR without being a `WorkoutSession` |
| Per-climb timing & attempts (dynamic logging) | `KilterLogEntry.{startedAt,endedAt,attemptTimestamps}` | **done** — a board session is *already dynamic* |
| Media + auto highlight reel | `KilterWorkoutBuilder` → `HighlightEngine.Workout(.climbing)` | **done** — same reel pipeline as workouts |
| Live Activity + rich summary | `KilterActivityAttributes`, `KilterSessionDetailView`, `KilterSessionStats` | **done** |

**Consequences for the original plan:**
- ❌ *Stale premise* — "board climbs have no HR/reel pipeline" is **no longer true**.
- ❌ **Drop B.1a/B.1b** (projecting Kilter into WorkoutTracker history) — `main` chose to make Kilter
  *self-sufficient* (honoring the 2026-06-02 "keep Kilter separate" decision) rather than unify. Re-unifying
  would now be redundant and fight that call. **Decision: Kilter stays the rich climbing home.**
- ✅ Your first example ("dynamic gym climbing") is **served for board climbing** — a Kilter session is
  inherently grow-as-you-go.

**What's genuinely left** (the re-scoped, sharper feature):

| # | Piece | Shape | Status |
|---|---|---|---|
| **B.2** | `KilterRecommender` — suggest a session from the user's logs | ③ graded attempts | **SHIPPED** |
| **A.1** | Freeform/Quick-Start session in WorkoutTracker | ① rep/load | **SHIPPED** (`FreeformPlayerView`) |
| **A.2** | Polymorphic `SetKind` → **ad-hoc** (non-catalog) climbing log | ③ | **SHIPPED** (user confirmed: climbs outside Kilter) |

---

## 1. SHIPPED — Kilter-driven session recommender (B.2)

The standout remaining idea, and the most on-brand: a **pure function over data the app already keeps**.

### 1.1 Pieces

| File | Role | Verifiable |
|---|---|---|
| `Features/Kilter/KilterRecommender.swift` | **pure** core — history + candidates → a goal-tagged `Plan` | XCTest (Mac) |
| `SnappetTests/KilterRecommenderTests.swift` | 11 cases — working-grade detection, banding, prefer-unsent, determinism, cold start, allocation | XCTest (Mac) |
| `Features/Kilter/KilterPlanView.swift` | the I/O screen — reads logs, queries catalog, renders + starts a session | sim/device |
| `KilterRootView.swift` | More-menu entry (`kilter.plan`) + `KilterPlanRoute` destination | sim/device |
| `docs/knowledge-graph/data.js` | nodes `kilter-recommender` + `kilter-plan`, wired | integrity-checked here |

### 1.2 Algorithm (all pure, deterministic)

- **Working grade** = the hardest *rounded-difficulty bucket* with ≥ `sendThreshold` (default 2) sends;
  else the hardest single send; else `nil` (cold start). Buckets match `KilterCatalog.gradeLabel` rounding.
- **Allocation** of `targetCount` (default 6) → ~⅓ warm-up, the bulk sends, one project. Sums to target.
- **Banding** relative to the working bucket `w`: warm-ups `{w−2,w−1}` (fallbacks `{w−3},{w−4}`), sends
  `{w}` (fallback `{w−1}`), project `{w+1}` (fallback `{w+2}`). `preferUnsent` keeps already-sent climbs
  out of send/project goals (warm-ups may revisit classics).
- **Ranking** within a band: quality → ascents → easiest → uuid (stable ⇒ reproducible). No climb appears
  in two goals.
- **Reuse, not reinvent:** history input is the existing `KilterClimbLog` value type (from
  `KilterSessionStats`); candidates are catalog `KilterListItem`s. No new persistence, no new `@Model`.

### 1.3 Flow

More menu → **Plan a session** → `KilterPlanView` reads `KilterLogEntry`s, computes the working grade,
queries `catalog.list(layout/angle, [anchor−3 … anchor+2])`, runs `KilterRecommender.recommend`, and
shows picks grouped **Warm up / Send / Project**. **Start session** begins a manual `KilterSession` (the
same `KilterSessionManager` → live HR / Live Activity / media) and jumps to the first pick; each pick
taps through to its climb detail (existing log flow), with a live "logged this session" check.

### 1.4 Verification honesty

No Swift toolchain exists on the authoring (Linux) box — **nothing here was compiled or run**. The pure
core + tests are written to the repo's tested-pure-edge convention; **`xcodebuild test` on a Mac is owed**
to turn the 11 `KilterRecommenderTests` green and to sim-verify `KilterPlanView`. Graph integrity (160
nodes / 279 edges, no orphans/dups) *was* checked here.

---

## 2. Open forks (product calls)

1. **Recommender home** — shipped inside **Kilter** (the rich climbing surface). The user originally
   imagined it in WorkoutTracker; placing it in Kilter follows `main`'s "Kilter is the climbing home"
   direction and reuses all the session infra. (Reversible — the pure core is UI-agnostic.)
2. **Is ad-hoc climbing logging (A.2) still wanted?** `main` covers *board* climbing richly; A.2 only adds
   value for **non-catalog** gym/outdoor bouldering. Worth confirming before building.
3. **Tunables** — `targetCount`/`sendThreshold` are defaulted; a Kilter Settings control is a later add.

---

## 3. SHIPPED — freeform sessions + ad-hoc climbing (D3/D4/D5)

How it was built (chosen to **not** destabilize the device-verified guided player):

- **D4 — model + pure logic.** `SetKind` (`repsWeight` / `duration` / `climbAttempt`) on
  `SessionExercise.kindRaw: String?` (nil ⇒ legacy reps/weight) + **optional** `SetLog` fields
  (`durationSec`, `climbGradeLabel`, `climbStatusRaw`, `climbAttempts`). **Migration nuance held:** these
  are nested **Codable** composites, not `@Model`s, so SwiftData lightweight migration doesn't reach
  inside the blob — every added field is `Optional` (synthesized `Codable` decodes a *missing* optional
  key as nil; a non-optional key would throw). The climb outcome **reuses `KilterAscentStatus`** (shared
  vocabulary with the recommender). Pure `SetMeasure` (summary/format/validate) + `SetMeasureTests`
  (14 cases). **Rejected** a `SetMeasure` enum-with-payloads (bigger hand-written-Codable surface).
- **D3/D5 — `FreeformPlayerView`** (a **new, self-contained** logbook, not a rewrite of the guided
  player): routineless sessions (`routineID == nil`) grow on the fly — **Add exercise** (Lifting via
  `ExercisePickerView` · Climbing · Timed), per-exercise **Add set/attempt** via a kind-adaptive
  `LogSetSheet`, swipe-to-delete, finish. Reuses the existing finish/HR/Live-Activity path. **Quick
  Start** (`startFreeform()`) creates the empty session; the player cover branches on `routineID == nil`.
  `SessionDetailView` now renders climb/timed sets too (via `SetMeasure`).

### Decomposition (all shipped)

| Step | Scope | Schema | Verify |
|---|---|---|---|
| ✅ D1 | `KilterRecommender` core + tests | none | Mac XCTest |
| ✅ D2 | `KilterPlanView` + root entry + graph | none | sim |
| ✅ D3 | Freeform sessions (Quick Start + `FreeformPlayerView`, add live, open-ended) | none | sim |
| ✅ D4 | `SetKind` + optional `SetLog` fields + pure `SetMeasure` (+ tests) | additive (optional) | Mac XCTest |
| ✅ D5 | Ad-hoc climb/timed input (`LogSetSheet`) + detail rendering | uses D4 | sim |

### Known v1 limitations / follow-ups
- The freeform player doesn't push per-set updates to the **Live Activity** (the timer + coordinator HR
  still work; the exercise line stays generic). Minor; a later add.
- Distance/GPS (Shape ②) is **not** a `SetKind` yet (its own initiative).
- Rename for ad-hoc Climbing/Timed exercises defaults to a fixed name; inline rename is a follow-up.

---

## 4. What this rules out

- Re-unifying Kilter into WorkoutTracker history (superseded by `main`'s self-sufficient Kilter).
- Continuous **GPS** cardio (Shape ②) — its own initiative.
- The `SetMeasure` enum-with-payloads (chose optional fields).
- Any cloud/account path — the recommender is an in-process query over the on-device store.
