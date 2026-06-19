# Workout (Gym Tracker) Redesign — every surface speaks "discipline", in one Pulse Pro language

> **Snappet Mobile** · Gym Tracker module (`workout-log`) · 2026-06-19
>
> A broad, phased redesign of the Gym Tracker: a more intuitive app, a creative **session detail** and
> **dashboard**, a **library of all workout types** (not just strength), **routines with full parity**
> across every type, **QR routine sharing**, **smart workout planning**, and **save-a-quick-session as a
> repeatable routine**. This is the **planning** deliverable — research, design direction, logical flows,
> wireframes, and a phased PDD plan — to review **before any implementation** (CLAUDE.md / the
> [[wireframe-before-implementation]] rule).
>
> | File | What it is |
> |------|------------|
> | **README.md** (this) | The design direction + the keystone architecture + the phased implementation plan. |
> | **[wireframes.html](./wireframes.html)** | **Open in a browser** — real-looking iPhone surfaces for all 8 redesign areas, real `SnappetColor` tokens, the iPhone scaffold matching the existing wireframes. The visual deliverable. |
> | **[wireframes/](./wireframes/)** | Rendered PNGs (real tokens, 2×). |
> | **[research-appendix.md](./research-appendix.md)** | The best-in-class design research (Whoop, Hevy, Fitbod, Strava, Apple Fitness+, Gentler Streak, JEFIT, Kaya, Spotify/Cash QR…) with citations, mapped onto Pulse. |
>
> *Derived from a **14-agent deep-research workflow** (8 file:line code maps + 6 design sweeps) plus an
> independent read of the spine files. Every `file:line` below was checked against source. Paths are under
> `ios/App/Snappet/Features/WorkoutTracker/` unless noted.*

---

## TL;DR

**The problem.** The freeform **Quick Session already solved the hard problem** — it has a rich
`WorkoutDiscipline` axis (climb / strength / run / dance / timed / other) + orthogonal measurement axes,
expandable entity cards, last-time prefill, type-adaptive stats and summaries (shipped by the Quick-Session
redesign + Workout-Type-Parity, PRs #174–#178). **Every *other* surface of the Gym Tracker is blind to it:**

- **Dashboard** (`WorkoutDashboardSection.swift`) — volume + PRs are **reps×weight-only**
  (`WorkoutProgress.swift:106-107`, `WorkoutDashboardSection.swift:297`); a climbing/running/timed session
  contributes **0 volume** and the weekly chart is hidden entirely for it (`:47`). There is **no
  recent-sessions surface at all** — a finished session is invisible on the dashboard unless it has a video
  (`StudioEntry.swift:33`). The resume banner hard-codes strength language ("sets logged", `:74-78`).
- **Session detail** (`SessionDetailView.swift`, 899 lines) — a flat `List` of `LabeledContent` rows
  (`:60-70`), **identical for every discipline**, and **strictly poorer** than the type-adaptive
  `FreeformDoneSummaryView` recap that immediately precedes it. Two drifting `kind` switches drive set
  rendering (`:776-803`).
- **"Exercises" tab** (`ExerciseBrowserView.swift`) — a **flat, strength-only** catalog of 873
  Free-Exercise-DB rows; climbing, timed/hangboard, running, dance have **no home here**. Three disconnected
  "libraries" exist (strength catalog, `TimedExerciseCatalog`, ad-hoc climbs) with zero cross-linking.
- **Routines** (`RoutineExercise`, `WorkoutModels.swift:216-226`) — **hard-locked to reps×weight**:
  `RoutineExercise` has **no discipline/kind/measurement field at all** (verified). The guided player
  (`WorkoutPlayerView.swift`, 826 lines) only accepts reps + weight; starters fake holds as reps strings
  (`"30s"`, `StarterRoutines.swift:27`). A "climbing" routine is just a pull-up list with an amber icon.

**The fix — one move above all others: propagate the discipline model the freeform side already proved to
every surface.** The single keystone is adding `disciplineRaw` + per-axis target metadata to
**`RoutineExercise`** (an additive-`Optional` change to a Codable composite ⇒ migration-free, the exact
pattern `SetLog`/`SessionExercise` already use, `WorkoutModels.swift:220-225`). That one change unblocks
routine parity, **save-as-routine**, **QR sharing**, and **smart planning** — all of which are routine-shaped.

On top of the data unification we apply **"Pulse Pro"**: a creative-but-non-rebrand visual layer
(score-first hero numerals, a two-axis color contract, a type-adaptive recap scaffold, glass-on-chrome,
dark-mode-first, earned PR celebrations) that *elevates* the existing `SnappetColor` "Pulse" tokens.

**Everything is on-device.** No new network. The smart planner is a pure heuristic with an *optional*
on-device Apple-Intelligence sharpener (see §1). The pure cores stay device-free + unit-tested per CLAUDE.md.

---

## 1. Decisions locked with the user (2026-06-19)

| Question | Decision |
|----------|----------|
| **How ambitious is the visual redesign?** | **"Pulse Pro" evolution** — elevate the existing tokens (score-first heroes, a new performance ramp alongside discipline accents, type-adaptive recap scaffold, glass-on-chrome, dark-mode-first, earned PR celebrations). **No rebrand.** |
| **First build wave?** | **Foundation → Dashboard + Session detail.** Ship E0 (design system + keystone model groundwork), then the two visible "how it looks" wins (E1 dashboard, E2 session detail — no risky model change), then the routine-parity spine (E3→E4) and share/plan/save on top. |
| **How smart is the planner (E7)?** | **Heuristic core + Apple-Intelligence sharpener.** A pure, deterministic, always-available recommender (per-muscle recovery/volume/recency + strategy presets, modeled on `KilterRecommender`) **plus** an optional on-device **Foundation Models** pass for natural-language tweaks ("15 min, no barbell"), gated to capable devices and **degrading to the heuristic**. (Builds on the [[receipt-ocr-apple-intelligence-followup]] note.) |
| **Where do routines mix types?** | **Per-exercise / per-block discipline** (one routine can mix a strength block + a timed circuit + a run), matching the freeform mixed-session model — not a single routine-level type. |
| **QR payload?** | **Reference-not-payload where possible**, but a user routine is not in any shared catalog → carry the **whole routine** as a compact `SharedRoutine` (deflate + base64url, exerciseId references only) with a **"share as link/file" fallback** when it exceeds a scannable QR. Never silent-import. |

---

## 2. The unifying insight — propagate the discipline axis (the keystone)

The two-axis model already exists and is proven on the **session** side, and is **absent** on the
**routine** side. The asymmetry is the whole story:

```
            TODAY                                           AFTER

  SessionExercise (freeform)  ── rich ──┐         RoutineExercise gains disciplineRaw + per-axis targets
    disciplineRaw, kindRaw,             │           (additive Optionals → migration-free, :220-225)
    climb*/timed*/distance, rpe         │                         │
    → EntityCard, type-adaptive         │         makeSession(from:) PROPAGATES discipline (:403-417)
      stats, summaries (WORKS)          │                         │
                                        │         guided WorkoutPlayerView becomes discipline-aware
  RoutineExercise (routine)  ── flat ───┘         (inputs/completeSet switch on discipline)
    sets:Int + reps:String + weight                              │
    NO discipline (:216-226)                      ┌──────────────┼───────────────┬───────────────┐
    → reps×weight-only player, builder,       Library feeds   Save-as-routine  QR share       Smart plan
      starters fake holds as "30s"            the builder     (actuals→presc.)  (SharedRoutine) (emits a routine)
```

- `WorkoutDiscipline` (`WorkoutDiscipline.swift:17-76`) + `MeasurementAxis` (`:81-83`) are pure, ready, and
  reusable verbatim.
- `SetLog` (`:234-256`) is already an all-`Optional` union of every axis (reps · weight · duration ·
  distance · rpe · climb), so "8 × 60 kg · 0:42" is just *two axes present*.
- `makeSession(from:)` (`WorkoutTrackerModule.swift:403-417`) is the **single, small bridge** to make
  type-aware — it currently sets neither `kindRaw` nor `disciplineRaw`, so every routine session is
  strength-flavored.
- A genuinely **new `@Model`** must be registered in **both** `SnappetSchema.models`
  (`SnappetCore.swift:39-53`) **and** `SnappetBackup` (`:59`) with a `BackupRow` mirror — but adding
  *fields to the existing Codable composites* needs **none** of that. We add **zero** new `@Model`s in the
  keystone (deferred per-entity history `@Model` is the one place a new model would appear — out of v1, §9).

---

## 3. The Pulse Pro design direction

The three visual sweeps (Whoop, Gentler Streak, Strava, Apple Fitness, Hevy, Fitbod) converged on a single
opinionated, **non-rebrand** direction. The rules, applied on every surface:

1. **Score-first hero.** Each surface earns **one** oversized rounded numeral / ring — the *type-chosen*
   hero metric (climb = hardest send; run = distance·pace; strength = volume; timed = focus time). Everything
   else demotes to small secondary text. No grid of co-equal tiles.
2. **Two-axis color contract.** **Discipline accent = wayfinding** (ember/amber/azure/tomato/violet/teal —
   the existing module ramp). A **new performance ramp** (`leaf 0x3F9D55 → amber 0xB45309 → tomato 0xE5483D`)
   = **effort / zone / PR state** only. **Coral (`brand`) is reserved for the single primary CTA / brand
   moment** per screen. Never paint a whole card in an accent — accents are dots, edge-bars, badges, values.
   *(Document the two systems in `decisions.md` so they never bleed.)*
3. **Type-adaptive recap scaffold.** One layout engine — hero slot · secondary-viz slot · breakdown slot ·
   celebration slot — with different fillers per discipline. The *same* component powers the post-Finish
   recap **and** the session detail (today they are two divergent surfaces).
4. **Glass on chrome only.** `.ultraThinMaterial`/glass on floating chrome (tab/command bar, live ribbon,
   timer HUD); content cards stay flat on `surface` with hairlines. Solid fallback for pre-iOS-26 (~85%).
5. **Dark-mode-first** for hero/immersive moments (gym/outdoor); light for utilitarian browse.
6. **Earned PR celebration.** Reuse `CelebrationBurst.swift` + `Haptics.swift`, tinted by the discipline
   accent/coral, fired only on a genuine record, < 1.2 s, never a blocking popup.
7. **Identity = glyph + label, never color alone** (color-blind safe; the climbing shape-coding precedent).
8. **Calm, spatially-continuous motion** (matched-geometry hero growth tile→detail) for review; snappy
   instant steppers for entry. All via `SnappetMotion` tokens, reduce-motion-gated.

---

## 4. Per-surface design (see [wireframes.html](./wireframes.html))

### Dashboard — Flow 1 (E1)
Discipline-aware home. Top: a conditional **Resume** card (the one coral-fill moment) → **one hero stat**
(coral progress ring around "active days this week") → a calm 7-day consistency strip (today in coral,
*"You're on track"* — Gentler-Streak warmth, not guilt) → a persistent **type-aware Start** CTA → a short
**Recent sessions** feed (the single biggest gap): 3–4 mixed-type cards, each a discipline accent edge-bar +
glyph + 3 headline facts (`V5 · 8 sends · 1h02` / `5.2 km · 5:41/km · 142 bpm` / `Push · 4,250 kg · 22 sets`)
+ an optional coral PR pill, deep-linking to detail. Extract the inline streak/volume math into a pure,
tested `WorkoutDashboardStats` (unifies the 4th-coexisting streak definition). **Does not** duplicate the
suite-level Home feed — it is rich *within* the gym tracker. *Reuse: `WorkoutStatCard`, the 7-day chart
animation, `StudioEntry` recent-session pattern (drop the video-only filter at `:33`), `WorkoutDiscipline`.*

### Session detail — Flow 2 (E2)
**Unify the detail view with the type-adaptive recap** so "View detail" is *richer*, not poorer, than the
Finish screen. One scaffold, per-discipline skins: climbing = hardest-send hero + **grade pyramid** +
intensity band + expandable climb cards; strength = volume hero + per-exercise volume minibars +
time-in-zone + set rows with e1RM PR pills. Route **all** set rows through `SetMeasure` (kill the inline
reps×weight copy at `:789-801`). Make **Edit** all-axis (today it only appears for reps/weight,
`SessionSetEditing.swift:30-31`). Keep the SwiftData cover/sheet hosting on the stable `List` (the
documented `:298-303` workaround). *Reuse: `FreeformDoneSummaryView` cards, `FreeformSummary.dominant/.stats`,
`FreeformClimbStats→ClimbGradePyramid`, `StrengthStats` e1RM, `WorkoutHRStats`+`ZoneBar`, `SetMediaStrip`.*

### Workout Library — Flow 3 (E3)
Replace the flat "Exercises" tab with a **library organized by workout TYPE** (the top spine; class-based
apps like Apple Fitness+ do this, strength trackers can't). A polymorphic **`LibraryItem`** (id · title ·
subtitle · discipline · symbol · isCustom) that `ExerciseResolver` builds from the strength catalog +
`CustomExercise` + `TimedExerciseCatalog` (+ climb/run templates). Discipline chips → swap the **faceted
filter** (strength=muscle+equipment+"no equipment"; climb=grade+style; timed=protocol; run=distance/terrain).
A **"Recent across all types"** band (a climb beside a bench press) — the cross-discipline win. Discipline-
adaptive detail: demo media → how-to → muscle map (**strength only** — don't fake anatomy) → discipline-
adaptive *records* + a per-movement history chart. *Reuse: `ExerciseSearch`/`ExerciseFilters`/`FlowChips`,
`ExerciseRow`, `TimedExerciseCatalog` + seeds.* *Note: cross-session history needs the deferred per-entity
history `@Model` (§9); a saved-climb/template model is net-new schema — scope it explicitly.*

### Routines — Flows 4 & 5 (E4)
The keystone. `RoutineExercise` gains `disciplineRaw` + per-axis targets; the builder becomes **block-based**:
a routine is an ordered list of **type-tagged blocks** (`STRENGTH · 4 moves` ember, `CIRCUIT · 3 rounds`
coral, `RUN · 5 km easy` azure, `CLIMB · V4–V6` amber) — a colored modality rhythm in one routine. Adaptive
exercise cards whose **columns re-render from the measure** (strength `SET|KG|REPS|RPE`, timed `SET|TIME`,
run `DURATION|DISTANCE|PACE`). Supersets/circuits as a **group container** (a leading accent rail + A/B/C
badges), not a per-set flag. The guided `WorkoutPlayerView` switches its input block + `completeSet` on
`current.discipline`. Re-author the 4 climbing starters as real climb-discipline routines. *Reuse:
`EntityCard` primitives, `AddStrengthParams`/`AddClimbParams`, `SetMeasure` (the column chooser),
`StructuredTimedRunner`/`IntervalSchedule`, the `.onMove` lazy-List pattern (the #158 hard-won gotcha).*

### Save Quick Session → routine — Flow 7 (E5)
A **"Save as routine"** action on `FreeformDoneSummaryView.actionBar` (`:355`). A **pure converter**
(actuals → prescription, per discipline) pre-fills the routine editor for review (lossy by nature — trim
warm-ups, name it). Depends on E4 (so a climb/timed/run block survives the round-trip instead of degrading
to a strength slot). *Reuse: `RoutineEditorView.save()` shape, the inverse of `makeSession`, the summary's
per-discipline read patterns.*

### Share routine via QR — Flow 5 (E6)
Generalize Kilter's QR stack into a `SnappetShareable` protocol + a compact **`SharedRoutine`** codec
(deflate + base64url → `snappet://routine/v1/<blob>`, **exerciseId references only** since both devices ship
the same catalog). A **segmented "My Code / Scan"** sheet; QR modules stay pure black-on-white (coral mark
center-punched at ECC-H); **import-confirm preview** (new local UUID, never overwrite) with a graceful
*"these N exercises aren't in your library"* landing (the `KilterDeepLinkRouting.explainMissing` analog).
**Honest size handling:** routines too big for a scannable QR fall back to a `ShareLink` (link/file).
*Reuse: `qrImage` CoreImage helper, `QRScannerRepresentable`, `SnappetDeepLink` route table (+`case routine`),
`SuiteRouter` one-shot, the `snappet` scheme already registered in `Info.plist`.*

### Smart workout planning — Flow 6 (E7)
A pure **`WorkoutRecommender`** modeled 1:1 on `KilterRecommender` (Strategy/Options/allocation), fed by a
new pure **`WorkoutHistoryStats`** (weekly volume-per-muscle, last-trained-per-muscle recency, training
cadence, e1RM progression headroom — joining sessions to `Exercise.primaryMuscles` via `ExerciseResolver` at
the I/O edge). A **"Today"** card (one verb headline REST/EASY/TRAIN/PUSH on the performance ramp + a
plain-language *why* + a recovery body-map). The suggestion is an **editable draft** (strategy + constraint
chips that re-generate; per-row swap/+/–/remove), then "Start" or "Save as routine". The **Apple-Intelligence
sharpener** is an optional on-device Foundation Models pass for natural-language tweaks, *gated and
degrading* to the heuristic. *Reuse: `KilterRecommender`/`KilterPlanLogic` architecture, `WorkoutHRStats` +
`RecoveryReadiness`, `UserHRProfile`, a `TodayDigest.workoutPlan` sibling.*

### Pulse Pro foundation + IA + the model — Flow 0 (E0)
The system itself: the two-axis color contract, the hero-numeral + glass-on-chrome spec, the shared
`SessionRecap`/`DisciplineHero`/`StatRibbon` scaffold, the new 4-section IA
(**Dashboard / Library / Routines / History**), and the keystone-model dependency diagram.

---

## 5. The keystone model change (in detail)

**`RoutineExercise` (`WorkoutModels.swift:216-226`) — new additive `Optional` fields (migration-free):**
- `disciplineRaw: String?` — `nil` ⇒ derive `.strength` (mirror `SessionExercise.discipline`, `:318-320`).
- `targetDurationSec: Double?`, `targetDistanceMeters: Double?`, `targetRPE: Int?` — per-axis targets.
- `climbTypeRaw / climbGradeLabel / climbGradeScaleRaw` — graded-climb prescription.
- `timedSpecData: Data? / timedCategory: String?` — a structured timed block (reuse `TimedExerciseSpec`).

**`makeSession(from:)` (`WorkoutTrackerModule.swift:403-417`)** — set `se.disciplineRaw = re.disciplineRaw`
and `se.kindRaw = discipline.defaultSetKind.rawValue`, carry the climb/timed/distance metadata through.

**`WorkoutActivityMapping.swift`** — add a `WorkoutDiscipline → HKWorkoutActivityType` case (run→.running,
climb→.climbing, dance→.cardioDance) so the live watch type follows the new axis (the deferred note at
`WorkoutDiscipline.swift:6`); decide the **mixed-session** single-`HKWorkoutSession` behaviour.

**Backup + Android (not free):** `RoutineExercise` fields round-trip automatically inside
`RoutineRow.exercises` (`SnappetBackup.swift:434`), **but** any new top-level `Routine` `@Model` property
shifts golden bytes; and the **Android** parallel `WorkoutModels.kt`/Room store + `BackupRoundTripTest` must
mirror every field in lockstep (its own wave).

---

## 6. Phased plan — one PDD prompt = one PR

> Each phase ships a committed feature prompt (`pdd/prompts/features/workout-redesign/`), keeps
> `pdd/context/` true, records choices in `pdd/context/decisions.md` the same day, and updates
> `docs/knowledge-graph/data.js` (nodes + edges for every new/changed surface) **in the same change**.

| Phase | Issue | Scope | Depends on | Tested by |
|-------|-------|-------|------------|-----------|
| **E0** | Pulse Pro foundation | Performance-ramp tokens + two-axis contract; shared `SessionRecap`/`DisciplineHero`/`StatRibbon`/glass-chrome components; pure `WorkoutDashboardStats`/`WorkoutHistoryStats` seams; IA cleanup (Dashboard/**Library**/Routines/History). **No model change.** | — | unit: stats/streak; build; review |
| **E1** | Dashboard redesign | Hero stat + 7-day strip + type-aware Start + **recent-sessions feed** + per-discipline stats + discipline-aware resume. | E0 | unit: dashboard stats; UITest |
| **E2** | Session detail redesign | Unify with the type-adaptive recap (hero/pyramid/zone/rollups); route set rows through `SetMeasure`; all-axis Edit. | E0 | unit: SetMeasure consolidation, dominant; UITest |
| **E3** | Workout Library | Discipline-spined polymorphic `LibraryItem`; faceted filter swap; "Recent across all types"; adaptive detail. *(scope any new template `@Model` + backup wiring)* | E0 | unit: `LibraryItem`/filter; UITest |
| **E4** | Routine parity | **Keystone** `RoutineExercise` discipline + targets; discipline-aware `makeSession`; **discipline-aware builder (blocks) + guided player**; discipline→HK; backup + Android. | E3 | unit: round-trip/legacy decode/mapping; UITest per discipline |
| **E5** | Save as routine | "Save as routine" + pure actuals→prescription converter + pre-filled editor review. | E4 | unit: converter per discipline; UITest |
| **E6** | Share via QR | `SnappetShareable` + `SharedRoutine` compact codec + generalized scanner/route + import-confirm + size fallback. | E4 | unit: codec round-trip/size/explainMissing; UITest |
| **E7** | Smart planning | Pure `WorkoutRecommender` + `WorkoutHistoryStats` (per-muscle volume/recency/cadence/progression) + recovery; editable draft; **Apple-Intelligence sharpener** (gated, degrading). | E4 | unit: recommender determinism, history stats; UITest |
| **H** | Hardening + Android | Device burn-in (MrRobot); discipline-aware Live Activity/widget; the **Android wave** (model + Room migration + backup mirror). | E1–E7 | manual device pass; Android suites |

**Phasing realism.** E1 + E2 are visible polish over existing data — **no model change**, so they ship right
after E0 (the chosen first wave). E4 is the architectural heart and **serializes** before E5/E6/E7 (they all
consume the routine model). E3 feeds E4's builder. Android is its own multi-PR wave (the Workout-Type-Parity
§8 caveat).

---

## 7. Reusable hooks (what we lean on, not rebuild)

| Need | Reuse |
|------|-------|
| Discipline axis | `WorkoutDiscipline` + `MeasurementAxis` (`WorkoutDiscipline.swift:17-83`) — graft onto `RoutineExercise` |
| Type-adaptive recap | `FreeformDoneSummaryView` cards (`:127-329`) + `FreeformSummary.dominant/.stats` (`:50-107`) |
| Climb stats/pyramid | `FreeformClimbStats → KilterSessionStats` + shared `ClimbGradePyramid`/`ClimbTimelineList` |
| Strength / run rollups | `StrengthStats` (topSet + Epley e1RM) · `RunStats` (distance/pace) |
| One set-row grammar | `SetMeasure.summary/runSummary/formatDistance/formatPace` — route everything through it |
| HR / zones | `WorkoutHRStats` + `ZoneBar` + `HeartRateChart` + `RecoveryReadiness` — type-agnostic |
| Entity card / add sheets | `EntityCard`, `AddClimbParams`/`AddStrengthParams`, `PickTimedExerciseSheet` |
| Timed structure | `StructuredTimedRunner` + `IntervalSchedule` (`Shared/`, type-agnostic) |
| Recommender | `KilterRecommender` (Strategy/Options/allocation) + `KilterPlanLogic` (freeze-on-Start) |
| QR / deep link | `qrImage` (CoreImage) · `QRScannerRepresentable` · `SnappetDeepLink` route table · `SuiteRouter` one-shot · `KilterDeepLinkRouting` graceful landing |
| Library browse | `ExerciseSearch`/`ExerciseFilters`/`FlowChips`/`ExerciseRow` · `ExerciseResolver` merge point |
| Celebration / motion | `CelebrationBurst` · `Haptics` · `SnappetMotion` |

---

## 8. Testing strategy (pure-logic-first, per CLAUDE.md)

- **Unit (no simulator):** `WorkoutDashboardStats` + unified streak; `SetMeasure` consolidation +
  legacy-row regression (the inline-reps×weight path carries a kg conversion `SetMeasure.summary` doesn't —
  `:776-781`); `RoutineExercise` legacy-blob decode (migration); discipline-aware `makeSession` mapping;
  actuals→prescription converter per discipline; `SharedRoutine` codec round-trip + size + `explainMissing`;
  `WorkoutRecommender` determinism + `WorkoutHistoryStats` (per-muscle volume/recency/cadence).
- **UITests (simulator):** dashboard recent-feed deep-links; type-adaptive session detail (climb + strength);
  library discipline browse + adaptive detail; routine block builder + per-discipline guided player;
  save-as-routine; QR import-confirm; smart-plan accept/swap.
- **Migration / backup:** decode a pre-change `Routine` blob; update `SnappetBackupTests` golden bytes +
  Android `BackupRoundTripTest` in the same wave.
- **UI-suite policy:** E0 (logic/tokens) gates on unit + build-for-testing + review ([[ui-suite-policy-logic-only-prs]]);
  E1–E7 run XCUITest. The sim can wedge (`xcrun simctl shutdown all`, [[uitest-event-synthesize-flake]]).

---

## 9. What this does NOT change (scope guards)

- **No new `@Model` in the keystone.** Per-entity cross-session history (a real "this exercise over time"
  table) is **deferred** — v1 scans session blobs like the existing PRs do. The library's per-movement
  history chart is best-effort from blobs until that model lands.
- **Apple Intelligence is a *sharpener*, never required.** The heuristic is the always-available path; the
  Foundation Models pass is gated to capable devices and must degrade silently. **No server LLM** (the
  on-device-only constraint, `project.md:64-69`).
- **No social / coach / marketplace tier** for routines/programs (on-device, solo). Programs (multi-week
  schedules) are an optional later tier, reference-not-copy.
- **GPS / route** for running stays manual distance (the Workout-Type-Parity deferral).
- **Knowledge graph** nodes are added **per phase at build time**, not in this planning PR (no UX shipped yet
  — don't let the graph claim unbuilt surfaces).
- **Android** follows iOS per phase, as its own wave.

---

## 10. Open questions to resolve during implementation

1. **Mixed-session HK type** — one `HKWorkoutSession` holds one activity type; a mixed routine reopens the
   Workout-Type-Parity Q2. *Recommend:* start `.other`/`.mixedCardio`, optionally re-start on first
   discipline pick; never log a run as strength.
2. **`SportTag` vs `WorkoutDiscipline`** — 3 cases vs 6 (calisthenics has no discipline analog). Map, or
   demote `SportTag` to a back-compat HK hint while `WorkoutDiscipline` becomes the identity axis.
3. **Actuals→prescription rule** — per discipline (a 1-attempt project climb → a 1-set routine is odd). Make
   it user-reviewable in the pre-filled editor.
4. **QR cliff threshold** — measure a realistic 10–12 exercise routine's byte size to pick the
   self-contained-QR vs link/file boundary; version the format (`/v1/`) from day one.
5. **Library climb/run templates** — do they need a new saved `@Model` (schema + backup) or can they ride
   existing structures? Scope in E3.
6. **`ExerciseCategory` vs `WorkoutDiscipline`** — reconcile the two "type" vocabularies via a mapping layer
   (the `exercises.json` `category` field is hardwired to `ExerciseCategory`).

---

## 11. Obligations on implementation (CLAUDE.md)

- **PDD:** one feature prompt per phase under `pdd/prompts/features/workout-redesign/`, committed with the
  code; keep `pdd/context/` true; record decisions the same day.
- **Knowledge graph:** every new/changed surface (Pulse Pro components, the new dashboard, the unified
  session recap, the workout library, the block builder + discipline-aware player, QR share, the planner)
  gets a `nodes` entry + `links` edge in `docs/knowledge-graph/data.js` in the same change.
- **Platform purity:** the recommender + all stats stay pure value types (device-free tests); HealthKit /
  location / Foundation Models behind the service edge; `HighlightEngine` stays platform-free.
- **Android:** its own wave after each iOS phase (model + Room migration + backup round-trip mirror).

---

## 12. GitHub issues

This plan maps to an **epic** (tracking) issue + **8 child issues** (E0–E7) + a hardening follow-up. See the
parent PR for the live links.

---

*Built on the real code — 8 file:line code maps + 6 design sweeps from a 14-agent research workflow, plus an
independent read of `WorkoutModels.swift`, the dashboard, the routine builder, `KilterRecommender`, and the
QR/deep-link stack. Every cited `file:line` was checked against source.*
