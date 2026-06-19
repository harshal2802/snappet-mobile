# PLAN: Workout (Gym Tracker) redesign — Pulse Pro + discipline everywhere

**Status**: planning (implementation gated on wireframe review)
**Owner**: pdd
**Created**: 2026-06-19
**Scope**: A broad redesign of the **Gym Tracker** module (`workout-log`): a more intuitive app, a creative
**dashboard** + **session detail**, a **library of all workout types**, **routines with full type parity**,
**QR routine sharing**, **smart workout planning**, and **save-a-quick-session as a repeatable routine**.
**Design + rationale (read first)**: [`docs/ux-research/workout-redesign/README.md`](../../../../docs/ux-research/workout-redesign/README.md)
(the keystone architecture + the Pulse Pro direction + per-surface design), with
[`wireframes.html`](../../../../docs/ux-research/workout-redesign/wireframes.html) and
[`research-appendix.md`](../../../../docs/ux-research/workout-redesign/research-appendix.md).
**Tracking**: the GitHub **epic** issue (+ 8 child issues E0–E7 + a hardening follow-up) referenced in the parent PR.
**Decisions locked (user, 2026-06-19)**: **Pulse Pro** evolution (no rebrand) · first wave =
**Foundation → Dashboard → Session detail** · planner = **heuristic core + on-device Apple Intelligence
sharpener**. See `pdd/context/decisions.md` (2026-06-19 entry).

## Where we are

The freeform **Quick Session** already proved the rich model — a `WorkoutDiscipline` axis
(climb/strength/run/dance/timed/other) + orthogonal measurement axes, expandable entity cards, type-adaptive
stats/summaries (PRs #174–#178). **Every other Gym-Tracker surface is blind to it:** the dashboard
(`WorkoutDashboardSection.swift`) is reps×weight-only and has no recent-sessions surface; the session detail
(`SessionDetailView.swift`) is a flat `List`, *poorer* than the recap it follows; the "Exercises" tab is a
flat strength catalog; and **`RoutineExercise` (`WorkoutModels.swift:216`) has no discipline field at all** —
routines, the guided player, and the builder are reps×weight-locked. This initiative sits on top of the
shipped parity work and does not block anything else.

## The keystone

```
  Add disciplineRaw + per-axis targets to RoutineExercise (additive Optionals → migration-free)
                                   │
        makeSession(from:) propagates discipline ──► guided WorkoutPlayerView becomes type-aware
                                   │
   ┌───────────────┬──────────────┼───────────────┬───────────────┐
 Library feeds   Save-as-routine  QR share        Smart plan      (all routine-shaped → all unblocked)
 the builder     (actuals→presc.) (SharedRoutine) (emits a routine)
```

Everything downstream of E4 consumes the routine model. E1/E2 are visible polish over *existing* data (no
model change) — so they ship first (the chosen wave) right after the E0 foundation.

## Prompt chain

> Numbering is per-initiative (`E0…E7`, `H`) under `pdd/prompts/features/workout-redesign/`, kept out of the
> flat `01–81` series. **One prompt = one PR = one branch (`feat/workout-redesign-<slug>`)**. Author each
> prompt only when its predecessors land + the wireframe direction is approved. Each phase updates
> `docs/knowledge-graph/data.js` (nodes + edges) and `pdd/context/` in the same change.

| # | Prompt file | Scope | Depends on | Wave |
|---|---|---|---|---|
| **E0** | `E0-pulse-pro-foundation.md` | Performance-ramp tokens + the two-axis color contract; shared `SessionRecap`/`DisciplineHero`/`StatRibbon` + glass-on-chrome chrome; pure `WorkoutDashboardStats`/`WorkoutHistoryStats` seams; the 4-section IA (Dashboard/**Library**/Routines/History). **No model change. Authored below.** | — | **1** |
| **E1** | `E1-dashboard-redesign.md` | Discipline-aware dashboard: hero stat + 7-day strip + type-aware Start + the **recent-sessions feed** + per-discipline stats + discipline-aware resume. **Authored below.** | E0 | **1** |
| **E2** | `E2-session-detail-redesign.md` | Unify `SessionDetailView` with the type-adaptive recap (hero/pyramid/zone/per-exercise rollups); route all set rows through `SetMeasure`; all-axis Edit. **Authored below.** | E0 | **1** |
| **E3** | `E3-workout-library.md` | Replace "Exercises" with a discipline-spined polymorphic `LibraryItem` library; faceted filter swap; "Recent across all types"; adaptive detail. *(scope any new template `@Model` + backup wiring)* | E0 | 2 |
| **E4** | `E4-routine-parity.md` | **Keystone** `RoutineExercise` discipline + targets; discipline-aware `makeSession`; **block builder + discipline-aware guided player**; discipline→HK; backup + Android. | E3 | 2 |
| **E5** | `E5-save-as-routine.md` | "Save as routine" + pure actuals→prescription converter + pre-filled editor review. | E4 | 3 |
| **E6** | `E6-share-routine-qr.md` | `SnappetShareable` + compact `SharedRoutine` codec + generalized scanner/route + import-confirm + size fallback. | E4 | 3 |
| **E7** | `E7-smart-planning.md` | Pure `WorkoutRecommender` + `WorkoutHistoryStats` + recovery; editable draft; **Apple-Intelligence sharpener** (gated, degrading to heuristic). | E4 | 3 |
| **H** | `H-hardening-android.md` | Device burn-in (MrRobot); discipline-aware Live Activity/widget; the **Android wave**. | E1–E7 | 4 |

## Decision gates
- **After E0:** confirm the two-axis color contract reads on a real screen (light + dark) before E1/E2 lean
  on it; lock the `SessionRecap` scaffold API so E2 + the library detail + planner draft reuse one component.
- **Before E4 (the keystone):** measure a pre-change `Routine` backup blob decode + the golden-byte delta;
  confirm the Android model/Room migration plan, since E4 must land both platforms in lockstep (or stage the
  Android wave behind a tracked follow-up).
- **Before E6:** measure a realistic 10–12-exercise `SharedRoutine` byte size to fix the self-contained-QR vs
  link/file threshold; version the wire format (`/v1/`) from day one.
- **Before E7's AI pass:** the heuristic must be the always-available path; gate Foundation Models on
  capability and prove it degrades silently on older iPhones / the simulator.

## Out of scope (defer)
- **New per-entity history `@Model`** (cross-session "this movement over time") — v1 scans session blobs.
- **A server LLM** — the planner is on-device only (heuristic + optional on-device Foundation Models).
- **Coach / marketplace / social** routine tier; **GPS/route** running (manual distance, per parity).
- **Knowledge-graph nodes for unbuilt surfaces** — added per phase at build time, not in the planning PR.

## Notes
- One prompt = one PR; commit the prompt asset with its code. Branch `feat/workout-redesign-<slug>`.
- Pure cores (`WorkoutDashboardStats`, `WorkoutHistoryStats`, `WorkoutRecommender`, the actuals→prescription
  converter, the `SharedRoutine` codec) stay device-free + unit-tested; HealthKit / Foundation Models behind
  the Services edge; `HighlightEngine` stays platform-free.
- New `@Model`s register in the single `SnappetSchema.models` line **and** `SnappetBackup`; modules don't nest
  a `NavigationStack`. Device-only features state honestly what was verified. Record choices in `decisions.md`.
